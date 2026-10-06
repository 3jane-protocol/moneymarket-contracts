// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {LCCMarginDepositHelper} from "../../src/lcc/LCCMarginDepositHelper.sol";
import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";

/// @title AuthorizeLCCMarginDepositHelperSafe
/// @notice Proposes the factory role grant needed by the self-service margin deposit helper.
/// @dev When `LCC_MARGIN_DEPOSIT_HELPER_PREVIOUS` names a replaced helper that still holds the role, the same Safe
/// transaction revokes it after the grant.
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
        require(helperAddress.code.length > 0, "helper has no code");
        if (previousHelper != address(0)) _verifyPreviousHelper(previousHelper, helperAddress, address(factory));

        LCCMarginDepositHelper reviewed = new LCCMarginDepositHelper(address(factory), WA_ETH_USDC, WA_ETH_USDT);
        bytes32 reviewedCodeHash = address(reviewed).codehash;
        require(helperAddress.codehash == reviewedCodeHash, "helper runtime code hash mismatch");
        require(factory.owner() == safe, "Safe is not factory owner");
        require(factory.getRoleMemberCount(factory.OWNER_ROLE()) == 1, "factory owner count mismatch");
        require(
            factory.getRoleAdmin(factory.DEPOSIT_OPERATOR_ROLE()) == factory.OWNER_ROLE(),
            "deposit operator admin mismatch"
        );

        LCCMarginDepositHelper helper = LCCMarginDepositHelper(helperAddress);
        require(helper.factory() == address(factory), "helper factory mismatch");
        require(helper.waEthUSDC() == WA_ETH_USDC, "helper waEthUSDC mismatch");
        require(helper.waEthUSDT() == WA_ETH_USDT, "helper waEthUSDT mismatch");
        require(helper.usdc() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "helper USDC mismatch");
        require(helper.aEthUSDC() == 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c, "helper aEthUSDC mismatch");
        require(helper.usdt() == 0xdAC17F958D2ee523a2206206994597C13D831ec7, "helper USDT mismatch");
        require(helper.aEthUSDT() == 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a, "helper aEthUSDT mismatch");

        uint256 calls;
        if (!factory.isDepositOperator(helperAddress)) {
            addToBatch(
                address(factory), abi.encodeCall(factory.grantRole, (factory.DEPOSIT_OPERATOR_ROLE(), helperAddress))
            );
            require(factory.isDepositOperator(helperAddress), "simulated role grant failed");
            ++calls;
        }
        if (previousHelper != address(0) && factory.isDepositOperator(previousHelper)) {
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
        if (previousHelper != address(0)) {
            require(!factory.isDepositOperator(previousHelper), "previous helper is still a deposit operator");
            console2.log("Previous LCC margin deposit helper deauthorized:", previousHelper);
        }
    }

    function run() external {
        this.run(false);
    }

    function _verifyPreviousHelper(address previousHelper, address helperAddress, address factory) private view {
        require(previousHelper != helperAddress, "previous helper is the new helper");
        require(previousHelper.code.length > 0, "previous helper has no code");
        LCCMarginDepositHelper previous = LCCMarginDepositHelper(previousHelper);
        require(previous.factory() == factory, "previous helper factory mismatch");
        require(previous.waEthUSDC() == WA_ETH_USDC, "previous helper waEthUSDC mismatch");
        require(previous.waEthUSDT() == WA_ETH_USDT, "previous helper waEthUSDT mismatch");
    }
}
