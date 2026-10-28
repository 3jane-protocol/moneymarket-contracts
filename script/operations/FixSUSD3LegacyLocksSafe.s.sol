// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {ProtocolConfigLib} from "../../src/libraries/ProtocolConfigLib.sol";

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC4626Minimal {
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

interface ISUSD3LegacyLockFix is IERC4626Minimal {
    function availableDepositLimit(address owner) external view returns (uint256);
    function depositorWhitelist(address depositor) external view returns (bool);
    function lockDuration() external view returns (uint256);
    function lockedUntil(address user) external view returns (uint256);
    function management() external view returns (address);
    function setDepositorWhitelist(address depositor, bool allowed) external;
}

/// @title FixSUSD3LegacyLocksSafe
/// @notice Builds a Safe batch that refreshes stale legacy sUSD3 locks using tiny on-behalf deposits.
contract FixSUSD3LegacyLocksSafe is Script, SafeHelper, TimelockHelper {
    address private constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address private constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address private constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address private constant sUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;

    uint256 private constant USDC_REFERENCE_AMOUNT = 10_000; // 0.01 USDC, 6 decimals.

    bytes32 private constant LOCK_TO_ONE_SALT = 0xaefc9c847a73074a7b2a93f05f13520d20253df3ce07dc3513b9e7c712a6161d;
    bytes32 private constant LOCK_TO_ZERO_SALT = 0xce4a00cec288099dfd8e8b5d2cfc2bc9db4351df8f7dad61a93488a03592bf6e;

    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        deployMode = DeployMode.PRODUCTION;

        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        address[] memory users = _affectedUsers();

        console2.log("=== sUSD3 Legacy Lock Fix via Safe ===");
        console2.log("Safe address:", safe);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("ProtocolConfig address:", PROTOCOL_CONFIG);
        console2.log("USD3 address:", USD3);
        console2.log("sUSD3 address:", sUSD3);
        console2.log("Affected users:", users.length);
        console2.log("Send to Safe:", send);
        console2.log("");

        bytes memory lockToOneData =
            abi.encodeCall(IProtocolConfig.setConfig, (ProtocolConfigLib.SUSD3_LOCK_DURATION, uint256(1)));
        bytes memory lockToZeroData =
            abi.encodeCall(IProtocolConfig.setConfig, (ProtocolConfigLib.SUSD3_LOCK_DURATION, uint256(0)));

        (address[] memory lockToOneTargets, uint256[] memory lockToOneValues, bytes[] memory lockToOneDatas) =
            _singleConfigOperation(lockToOneData);

        bytes32 lockToOneId =
            calculateBatchOperationId(lockToOneTargets, lockToOneValues, lockToOneDatas, bytes32(0), LOCK_TO_ONE_SALT);
        bytes32 lockToZeroPredecessor = lockToOneId;
        bytes32 lockToZeroId =
            calculateOperationId(PROTOCOL_CONFIG, 0, lockToZeroData, lockToZeroPredecessor, LOCK_TO_ZERO_SALT);

        require(lockToOneId == 0xdc03759c5c543410c721442bcd88d55c2d2f6dfefaeea9428e194ed442b0b48e, "op1 id");
        require(lockToZeroId == 0xebd0e1df56a472291a4c7f88d59f94455501f947102682bed20cf7894e4574be, "op2 id");

        console2.log("Lock-to-1 operation:", vm.toString(lockToOneId));
        logOperationState(TIMELOCK, lockToOneId);
        console2.log("");
        console2.log("Lock-to-0 operation:", vm.toString(lockToZeroId));
        logOperationState(TIMELOCK, lockToZeroId);
        console2.log("");

        _warpToReadyTime(lockToOneId, lockToZeroId);

        requireOperationReady(TIMELOCK, lockToOneId);
        requireOperationReady(TIMELOCK, lockToZeroId);

        uint256 usd3AssetsPerUser = IERC4626Minimal(USD3).previewDeposit(USDC_REFERENCE_AMOUNT);
        uint256 susd3SharesPerUser = IERC4626Minimal(sUSD3).previewDeposit(usd3AssetsPerUser);
        uint256 totalUsd3Assets = usd3AssetsPerUser * users.length;

        require(usd3AssetsPerUser > 0, "zero USD3 assets");
        require(susd3SharesPerUser > 0, "zero sUSD3 shares");
        require(ISUSD3LegacyLockFix(sUSD3).management() == safe, "safe not management");
        require(IERC20Minimal(USD3).balanceOf(safe) >= totalUsd3Assets, "insufficient safe USD3");
        require(
            ISUSD3LegacyLockFix(sUSD3).availableDepositLimit(safe) >= totalUsd3Assets, "insufficient sUSD3 headroom"
        );

        console2.log("USD3 assets per user:", usd3AssetsPerUser);
        console2.log("sUSD3 shares per user:", susd3SharesPerUser);
        console2.log("Total USD3 assets:", totalUsd3Assets);
        console2.log("Safe USD3 balance:", IERC20Minimal(USD3).balanceOf(safe));
        console2.log("sUSD3 deposit headroom:", ISUSD3LegacyLockFix(sUSD3).availableDepositLimit(safe));
        console2.log("");

        _logAffectedUsers(users);

        addToBatch(
            TIMELOCK,
            encodeExecuteBatch(lockToOneTargets, lockToOneValues, lockToOneDatas, bytes32(0), LOCK_TO_ONE_SALT)
        );
        addToBatch(sUSD3, abi.encodeCall(ISUSD3LegacyLockFix.setDepositorWhitelist, (safe, true)));
        addToBatch(USD3, abi.encodeCall(IERC20Minimal.approve, (sUSD3, totalUsd3Assets)));

        for (uint256 i = 0; i < users.length; i++) {
            addToBatch(sUSD3, abi.encodeCall(IERC4626Minimal.deposit, (usd3AssetsPerUser, users[i])));
        }

        addToBatch(USD3, abi.encodeCall(IERC20Minimal.approve, (sUSD3, 0)));
        addToBatch(sUSD3, abi.encodeCall(ISUSD3LegacyLockFix.setDepositorWhitelist, (safe, false)));
        addToBatch(
            TIMELOCK, encodeExecute(PROTOCOL_CONFIG, 0, lockToZeroData, lockToZeroPredecessor, LOCK_TO_ZERO_SALT)
        );

        console2.log("");
        console2.log("Prepared Safe batch with legacy lock fix operations");

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    function run() external {
        this.run(false);
    }

    function _singleConfigOperation(bytes memory data)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        datas = new bytes[](1);

        targets[0] = PROTOCOL_CONFIG;
        values[0] = 0;
        datas[0] = data;
    }

    function _affectedUsers() private pure returns (address[] memory users) {
        users = new address[](19);
        users[0] = 0x0129d3E6778130006523f43e60738c950d698382;
        users[1] = 0x0D1d6Ff7eAa43a3225aeef38f8eB2d245095af5d;
        users[2] = 0x0D96C02b9839aF4616CDb3bAA3F9a30c799A73D9;
        users[3] = 0x1FFb31FA1f2d5Ee2EB3e7B56468ccf53A2B72838;
        users[4] = 0x1ffb9A7de3D52c45F97C2ed9943a7676Bbc21C71;
        users[5] = 0x30A26c2837e9Ad41Ea5955949F00402DbF86f124;
        users[6] = 0x48f09213691e789eC00641C09F9890c0D00a8b2e;
        users[7] = 0x4cA9cDaB80b6f2BcF067D9030dBA32452b845a67;
        users[8] = 0x7a5Ea5597e083228F57c94f3F2a24998a57c4252;
        users[9] = 0x7b666af4F977342446F43f02268B48DD081181E0;
        users[10] = 0x81686B29dCed6e195337466471b30c10C6ad1692;
        users[11] = 0x9624D9B9B628635e486A6C967531145d02fA3874;
        users[12] = 0xA96f244dA2206B34F90acA69ca6b7296DaAd1Bb2;
        users[13] = 0xae0D56Da41765c64d29a3dac984ED1D98964dE9C;
        users[14] = 0xBCB76036c703eA46710bC7995A71ED00334f98b0;
        users[15] = 0xCdb62D36ca08902E96bc5900fEB934b75Ec9A8B4;
        users[16] = 0xD01D3969aCd4307e63837D0153fea0213A0322A7;
        users[17] = 0xe25C0E141b98A5a449fbd70CFDA45F6088486C74;
        users[18] = 0xf73484a987ed44B6926996C1C6cDd460807246BF;
    }

    function _logAffectedUsers(address[] memory users) private view {
        console2.log("Affected user locks before batch:");
        for (uint256 i = 0; i < users.length; i++) {
            console2.log("  user:", users[i]);
            console2.log("    lockedUntil:", ISUSD3LegacyLockFix(sUSD3).lockedUntil(users[i]));
        }
        console2.log("Expected refreshed lock after execution: batch timestamp + 1 second");
        console2.log("");
    }

    function _warpToReadyTime(bytes32 lockToOneId, bytes32 lockToZeroId) private {
        uint256 lockToOneReadyAt = getOperationTimestamp(TIMELOCK, lockToOneId);
        uint256 lockToZeroReadyAt = getOperationTimestamp(TIMELOCK, lockToZeroId);
        uint256 readyAt = lockToOneReadyAt > lockToZeroReadyAt ? lockToOneReadyAt : lockToZeroReadyAt;

        if (readyAt > block.timestamp) {
            console2.log("Warping local simulation to timelock ready time:", readyAt);
            console2.log("  Previous timestamp:", block.timestamp);
            vm.warp(readyAt);
            console2.log("  New timestamp:", block.timestamp);
            console2.log("");
        }
    }

    function _baseFeeOkay() private view returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(50)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console2.log("Base fee too high: %d gwei > %d gwei limit", block.basefee / 1e9, basefeeLimit / 1e9);
            return false;
        }
        console2.log("Base fee OK: %d gwei", block.basefee / 1e9);
        return true;
    }
}
