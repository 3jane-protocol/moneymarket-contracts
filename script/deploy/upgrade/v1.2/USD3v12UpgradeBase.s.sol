// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {
    ITransparentUpgradeableProxy,
    ProxyAdmin
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockHelper} from "../../../utils/TimelockHelper.sol";

interface IProtocolConfigUSD3UpgradePreflight {
    function getUsd3CommitmentTime() external view returns (uint256);
}

/// @notice Shared topology validation and calldata construction for the USD3 v1.2 upgrade scripts.
abstract contract USD3v12UpgradeBase is TimelockHelper {
    address internal constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address internal constant PROXY_ADMIN = 0x41C838664a9C64905537fF410333B9f5964cC596;
    address internal constant SUSD3_PROXY = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;
    address internal constant SUSD3_PROXY_ADMIN = 0xecda55c32966B00592Ed3922E386063e1Bc752c2;
    address internal constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address internal constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant SEVEN_DAY_DELAY = 7 days;

    function _sevenDayTimelock() internal view returns (address sevenDayTimelock) {
        sevenDayTimelock = vm.envAddress("SEVEN_DAY_TIMELOCK");
        require(sevenDayTimelock != address(0), "SEVEN_DAY_TIMELOCK not set");
        require(sevenDayTimelock.code.length > 0, "SEVEN_DAY_TIMELOCK has no code");
        require(getMinDelay(sevenDayTimelock) == SEVEN_DAY_DELAY, "Timelock delay is not 7 days");
        require(ProxyAdmin(PROXY_ADMIN).owner() == sevenDayTimelock, "ProxyAdmin owner is not 7-day timelock");
        require(
            ProxyAdmin(SUSD3_PROXY_ADMIN).owner() == sevenDayTimelock, "sUSD3 ProxyAdmin owner is not 7-day timelock"
        );
    }

    function _usd3Impl() internal view returns (address newImpl) {
        newImpl = vm.envAddress("USD3_IMPL");
        require(newImpl != address(0), "USD3_IMPL not set");
        require(newImpl.code.length > 0, "USD3_IMPL has no code");
    }

    function _susd3Impl() internal view returns (address newImpl) {
        newImpl = vm.envAddress("SUSD3_IMPL");
        require(newImpl != address(0), "SUSD3_IMPL not set");
        require(newImpl.code.length > 0, "SUSD3_IMPL has no code");
    }

    /// @dev v1.2 removes enforcement of the deprecated USD3 deposit lock. The sanctioned scripts recheck this value
    /// while preparing and simulating the Safe batch, which catches a config write that has already landed during the
    /// 7-day delay, but the check is not atomic with timelock execution: a write landing after preflight and before
    /// Safe execution bypasses it, and a direct `EXECUTOR_ROLE` call bypasses both the script and its recheck.
    function _requireCommitmentTimeDisabled() internal view {
        require(PROTOCOL_CONFIG.code.length > 0, "ProtocolConfig has no code");
        require(
            IProtocolConfigUSD3UpgradePreflight(PROTOCOL_CONFIG).getUsd3CommitmentTime() == 0,
            "USD3_COMMITMENT_TIME must be zero before upgrade"
        );
    }

    /// @dev USD3 and sUSD3 upgrade atomically in one timelock operation: v1.2 USD3 burns sUSD3 shares against
    /// pending losses, and the v1.2 sUSD3 deposit guard closes the stale-share-price entry window that behavior
    /// opens. Neither leg requires a reinitializer.
    function _buildOperation(address newImpl, address newSusd3Impl)
        internal
        pure
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory datas,
            bytes32 salt,
            bytes32 predecessor
        )
    {
        targets = new address[](2);
        values = new uint256[](2);
        datas = new bytes[](2);

        targets[0] = PROXY_ADMIN;
        datas[0] =
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(USD3_PROXY), newImpl, bytes("")));
        targets[1] = SUSD3_PROXY_ADMIN;
        datas[1] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(SUSD3_PROXY), newSusd3Impl, bytes(""))
        );

        salt = generateSalt("USD3 v1.2 Upgrade");
        predecessor = bytes32(0);
    }
}
