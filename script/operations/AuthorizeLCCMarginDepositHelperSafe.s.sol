// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {LCCMarginDepositHelper} from "../../src/lcc/LCCMarginDepositHelper.sol";
import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";

/// @title AuthorizeLCCMarginDepositHelperSafe
/// @notice Proposes the single factory role grant needed by the self-service margin deposit helper, and separately
/// the single role revoke that retires a replaced deposit operator.
/// @dev `--sig "run(bool)" <send>` proposes the grant for `LCC_MARGIN_DEPOSIT_HELPER`. `--sig "revoke(bool)" <send>`
/// proposes the revoke for `LCC_DEPOSIT_OPERATOR_TO_REVOKE`, which may be any current deposit operator except the
/// address in `LCC_MARGIN_DEPOSIT_HELPER`. `run` only grants and `revoke` only revokes, so each Safe proposal is one
/// factory call and a replaced helper stays authorized until `revoke` is run for it. Both log the deposit-operator
/// set of the simulated state, which reflects a proposal only once the Safe executes it.
contract AuthorizeLCCMarginDepositHelperSafe is Script, SafeHelper {
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address internal constant WA_ETH_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address internal constant WA_ETH_USDT = 0x7Bc3485026Ac48b6cf9BaF0A377477Fff5703Af8;

    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        LCCVaultFactory factory = LCCVaultFactory(vm.envAddress("LCC_FACTORY"));
        address helperAddress = vm.envAddress("LCC_MARGIN_DEPOSIT_HELPER");
        require(address(factory).code.length > 0, "factory has no code");
        require(helperAddress.code.length > 0, "helper has no code");

        LCCMarginDepositHelper reviewed = new LCCMarginDepositHelper(address(factory), WA_ETH_USDC, WA_ETH_USDT);
        bytes32 reviewedCodeHash = address(reviewed).codehash;
        require(helperAddress.codehash == reviewedCodeHash, "helper runtime code hash mismatch");
        _verifyRoleAuthority(factory, safe);

        LCCMarginDepositHelper helper = LCCMarginDepositHelper(helperAddress);
        require(helper.factory() == address(factory), "helper factory mismatch");
        require(helper.waEthUSDC() == WA_ETH_USDC, "helper waEthUSDC mismatch");
        require(helper.waEthUSDT() == WA_ETH_USDT, "helper waEthUSDT mismatch");
        require(helper.usdc() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "helper USDC mismatch");
        require(helper.aEthUSDC() == 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c, "helper aEthUSDC mismatch");
        require(helper.usdt() == 0xdAC17F958D2ee523a2206206994597C13D831ec7, "helper USDT mismatch");
        require(helper.aEthUSDT() == 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a, "helper aEthUSDT mismatch");

        if (!factory.isDepositOperator(helperAddress)) {
            addToBatch(
                address(factory), abi.encodeCall(factory.grantRole, (factory.DEPOSIT_OPERATOR_ROLE(), helperAddress))
            );
            require(factory.isDepositOperator(helperAddress), "simulated role grant failed");
            require(getTotalBatches() == 1, "SafeHelper split role grant");
            (uint256 txCount,) = getBatchInfo(0);
            require(txCount == 1, "role grant must be one Safe call");
            executeBatch(send);
        }

        require(factory.isDepositOperator(helperAddress), "helper is not a deposit operator");
        console2.log("Reviewed helper runtime code hash:", vm.toString(reviewedCodeHash));
        console2.log("LCC margin deposit helper authorized:", helperAddress);
        _logDepositOperators(factory);
    }

    function run() external {
        this.run(false);
    }

    function revoke(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        LCCVaultFactory factory = LCCVaultFactory(vm.envAddress("LCC_FACTORY"));
        address operator = vm.envAddress("LCC_DEPOSIT_OPERATOR_TO_REVOKE");
        require(address(factory).code.length > 0, "factory has no code");
        _verifyRoleAuthority(factory, safe);
        require(operator != vm.envOr("LCC_MARGIN_DEPOSIT_HELPER", address(0)), "operator is LCC_MARGIN_DEPOSIT_HELPER");
        require(factory.isDepositOperator(operator), "address is not a deposit operator");

        addToBatch(address(factory), abi.encodeCall(factory.revokeRole, (factory.DEPOSIT_OPERATOR_ROLE(), operator)));
        require(!factory.isDepositOperator(operator), "simulated role revoke failed");
        require(getTotalBatches() == 1, "SafeHelper split role revoke");
        (uint256 txCount,) = getBatchInfo(0);
        require(txCount == 1, "role revoke must be one Safe call");
        executeBatch(send);

        console2.log("LCC deposit operator revoked:", operator);
        _logDepositOperators(factory);
    }

    function _verifyRoleAuthority(LCCVaultFactory factory, address safe) private view {
        require(factory.owner() == safe, "Safe is not factory owner");
        require(factory.getRoleMemberCount(factory.OWNER_ROLE()) == 1, "factory owner count mismatch");
        require(
            factory.getRoleAdmin(factory.DEPOSIT_OPERATOR_ROLE()) == factory.OWNER_ROLE(),
            "deposit operator admin mismatch"
        );
    }

    function _logDepositOperators(LCCVaultFactory factory) private view {
        bytes32 role = factory.DEPOSIT_OPERATOR_ROLE();
        uint256 count = factory.getRoleMemberCount(role);
        console2.log("Deposit operators in simulated state:", count);
        for (uint256 i; i < count; ++i) {
            console2.log("  deposit operator:", factory.getRoleMember(role, i));
        }
    }
}
