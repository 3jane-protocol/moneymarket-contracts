// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {LCCMarginDepositHelper} from "../../src/lcc/LCCMarginDepositHelper.sol";
import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";

/// @title AuthorizeLCCMarginDepositHelperSafe
/// @notice Proposes the factory role grant needed by the self-service margin deposit helper.
/// @dev When `LCC_MARGIN_DEPOSIT_HELPER_PREVIOUS` names a replaced helper that still holds the role, the same Safe
/// transaction revokes it after any grant. Leaving it unset keeps a replaced helper authorized; run again with it
/// set to propose the revoke alone. The resulting deposit-operator set is logged on every run.
contract AuthorizeLCCMarginDepositHelperSafe is Script, SafeHelper {
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address internal constant WA_ETH_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address internal constant WA_ETH_USDT = 0x7Bc3485026Ac48b6cf9BaF0A377477Fff5703Af8;

    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        LCCVaultFactory factory = LCCVaultFactory(vm.envAddress("LCC_FACTORY"));
        address helperAddress = vm.envAddress("LCC_MARGIN_DEPOSIT_HELPER");
        address previousHelper = vm.envOr("LCC_MARGIN_DEPOSIT_HELPER_PREVIOUS", address(0));
        require(address(factory).code.length > 0, "factory has no code");

        LCCMarginDepositHelper reviewed = new LCCMarginDepositHelper(address(factory), WA_ETH_USDC, WA_ETH_USDT);
        bytes32 reviewedCodeHash = address(reviewed).codehash;
        _verifyWiring("helper", helperAddress, address(factory));
        require(helperAddress.codehash == reviewedCodeHash, "helper runtime code hash mismatch");
        require(factory.owner() == safe, "Safe is not factory owner");
        require(factory.getRoleMemberCount(factory.OWNER_ROLE()) == 1, "factory owner count mismatch");
        require(
            factory.getRoleAdmin(factory.DEPOSIT_OPERATOR_ROLE()) == factory.OWNER_ROLE(),
            "deposit operator admin mismatch"
        );

        bool revoke;
        if (previousHelper != address(0)) {
            require(previousHelper != helperAddress, "previous helper is the new helper");
            _verifyWiring("previous helper", previousHelper, address(factory));
            revoke = factory.isDepositOperator(previousHelper);
            require(revoke || factory.isDepositOperator(helperAddress), "previous helper holds no role");
        }

        uint256 calls;
        if (!factory.isDepositOperator(helperAddress)) {
            addToBatch(
                address(factory), abi.encodeCall(factory.grantRole, (factory.DEPOSIT_OPERATOR_ROLE(), helperAddress))
            );
            require(factory.isDepositOperator(helperAddress), "simulated role grant failed");
            ++calls;
        }
        if (revoke) {
            addToBatch(
                address(factory), abi.encodeCall(factory.revokeRole, (factory.DEPOSIT_OPERATOR_ROLE(), previousHelper))
            );
            require(!factory.isDepositOperator(previousHelper), "simulated role revoke failed");
            ++calls;
        }
        if (calls != 0) {
            require(getTotalBatches() == 1, "SafeHelper split role batch");
            (uint256 txCount,) = getBatchInfo(0);
            require(txCount == calls, "role batch call count mismatch");
            executeBatch(send);
        }

        require(factory.isDepositOperator(helperAddress), "helper is not a deposit operator");
        console2.log("Reviewed helper runtime code hash:", vm.toString(reviewedCodeHash));
        console2.log("LCC margin deposit helper authorized:", helperAddress);
        if (revoke) console2.log("Previous LCC margin deposit helper revoked:", previousHelper);
        _logDepositOperators(factory);
    }

    function run() external {
        this.run(false);
    }

    function _verifyWiring(string memory label, address helperAddress, address factory) private view {
        require(helperAddress.code.length > 0, string.concat(label, " has no code"));
        LCCMarginDepositHelper helper = LCCMarginDepositHelper(helperAddress);
        require(helper.factory() == factory, string.concat(label, " factory mismatch"));
        require(helper.waEthUSDC() == WA_ETH_USDC, string.concat(label, " waEthUSDC mismatch"));
        require(helper.waEthUSDT() == WA_ETH_USDT, string.concat(label, " waEthUSDT mismatch"));
        require(helper.usdc() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, string.concat(label, " USDC mismatch"));
        require(
            helper.aEthUSDC() == 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c, string.concat(label, " aEthUSDC mismatch")
        );
        require(helper.usdt() == 0xdAC17F958D2ee523a2206206994597C13D831ec7, string.concat(label, " USDT mismatch"));
        require(
            helper.aEthUSDT() == 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a, string.concat(label, " aEthUSDT mismatch")
        );
    }

    function _logDepositOperators(LCCVaultFactory factory) private view {
        bytes32 role = factory.DEPOSIT_OPERATOR_ROLE();
        uint256 count = factory.getRoleMemberCount(role);
        console2.log("Deposit operators after this proposal:", count);
        for (uint256 i; i < count; ++i) {
            console2.log("  deposit operator:", factory.getRoleMember(role, i));
        }
    }
}
