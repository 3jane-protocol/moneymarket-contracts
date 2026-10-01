// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";

import {LCCVaultFactory} from "../../src/lcc/LCCVaultFactory.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";

/// @title GrantLCCFactoryRoleSafe
/// @notice Proposes a single LCCVaultFactory operational role grant from the factory-owning Safe.
/// @dev Covers LISTER_ROLE, BOUNCER_ROLE, and GUARDIAN_ROLE only. OWNER_ROLE moves solely through the factory's
///      two-step ownership transfer, and DEPOSIT_OPERATOR_ROLE is granted only through
///      AuthorizeLCCMarginDepositHelperSafe after a runtime code-hash review, because that role authenticates a payer
///      acting for other beneficiaries. Re-running after a successful grant is a verified no-op.
///
///      Usage:
///      FOUNDRY_PROFILE=script LCC_FACTORY=<address> LCC_ROLE=<LISTER|BOUNCER|GUARDIAN> LCC_ROLE_ACCOUNT=<address> \
///        WALLET_TYPE=local SAFE_PROPOSER_PRIVATE_KEY=<private-key> forge script \
///        script/operations/GrantLCCFactoryRoleSafe.s.sol --sig "run(bool)" false --rpc-url mainnet
contract GrantLCCFactoryRoleSafe is Script, SafeHelper {
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        (LCCVaultFactory factory, bytes32 role, string memory roleName, address account) = _context();

        require(factory.owner() == safe, "Safe is not factory owner");
        require(factory.getRoleMemberCount(factory.OWNER_ROLE()) == 1, "factory owner count mismatch");
        require(factory.getRoleAdmin(role) == factory.OWNER_ROLE(), "role admin is not OWNER_ROLE");

        console2.log("=== Grant LCC Factory Role via Safe ===");
        console2.log("Factory:", address(factory));
        console2.log("Role:", roleName);
        console2.log("Account:", account);
        console2.log("Current holders:", factory.getRoleMemberCount(role));
        console2.log("Send to Safe:", send);

        if (!factory.hasRole(role, account)) {
            addToBatch(address(factory), abi.encodeCall(factory.grantRole, (role, account)));
            require(factory.hasRole(role, account), "simulated role grant failed");
            require(getTotalBatches() == 1, "SafeHelper split role grant");
            (uint256 txCount,) = getBatchInfo(0);
            require(txCount == 1, "role grant must be one Safe call");
            executeBatch(send);
        } else {
            console2.log("Account already holds the role; nothing to propose");
        }

        require(factory.hasRole(role, account), "account does not hold the role");
        console2.log("Role granted:", roleName, account);
    }

    function run() external {
        this.run(false);
    }

    /// @notice Reports whether the configured account holds the configured role.
    function verify() external view {
        (LCCVaultFactory factory, bytes32 role, string memory roleName, address account) = _context();
        bool held = factory.hasRole(role, account);
        console2.log(held ? "PASS: role held" : "FAIL: role not held", roleName, account);
        require(held, "account does not hold the role");
    }

    function _context()
        internal
        view
        returns (LCCVaultFactory factory, bytes32 role, string memory roleName, address account)
    {
        factory = LCCVaultFactory(vm.envAddress("LCC_FACTORY"));
        require(address(factory).code.length > 0, "factory has no code");

        roleName = vm.envString("LCC_ROLE");
        bytes32 key = keccak256(bytes(roleName));
        if (key == keccak256("LISTER")) role = factory.LISTER_ROLE();
        else if (key == keccak256("BOUNCER")) role = factory.BOUNCER_ROLE();
        else if (key == keccak256("GUARDIAN")) role = factory.GUARDIAN_ROLE();
        else revert("LCC_ROLE must be LISTER, BOUNCER, or GUARDIAN");

        account = vm.envAddress("LCC_ROLE_ACCOUNT");
        require(account != address(0), "LCC_ROLE_ACCOUNT not set");
    }
}
