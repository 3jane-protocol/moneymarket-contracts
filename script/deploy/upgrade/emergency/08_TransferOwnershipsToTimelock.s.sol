// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {IMorphoBase} from "../../../../src/interfaces/IMorpho.sol";

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @title TransferOwnershipsToTimelock
/// @notice Transfer MorphoCredit and CreditLine ownership to the Timelock
/// @dev This script creates an atomic batch transaction to:
///      1. MorphoCredit.setOwner(timelock)
///      2. CreditLine.transferOwnership(timelock)
contract TransferOwnershipsToTimelock is Script, SafeHelper {
    // Mainnet addresses
    address constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    function run(bool send) external isBatch(SAFE_ADDRESS) {
        console2.log("=== Transfer Ownerships to Timelock ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("MorphoCredit:", MORPHO_CREDIT);
        console2.log("CreditLine:", CREDIT_LINE);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Check current state
        address morphoCreditOwner = IMorphoBase(MORPHO_CREDIT).owner();
        address creditLineOwner = IOwnable(CREDIT_LINE).owner();

        console2.log("Current state:");
        console2.log("  MorphoCredit.owner():", morphoCreditOwner);
        console2.log("  CreditLine.owner():", creditLineOwner);
        console2.log("");

        if (morphoCreditOwner == TIMELOCK && creditLineOwner == TIMELOCK) {
            console2.log("Both contracts already owned by Timelock!");
            return;
        }

        // Encode the ownership transfer calls
        // MorphoCredit uses setOwner(address)
        bytes memory setOwnerCall = abi.encodeCall(IMorphoBase.setOwner, (TIMELOCK));

        // CreditLine uses OpenZeppelin's transferOwnership(address)
        bytes memory transferOwnershipCall = abi.encodeCall(IOwnable.transferOwnership, (TIMELOCK));

        console2.log("Batch operations:");
        console2.log("  1. MorphoCredit.setOwner(%s)", TIMELOCK);
        console2.log("  2. CreditLine.transferOwnership(%s)", TIMELOCK);
        console2.log("");

        // Add calls to batch
        if (morphoCreditOwner != TIMELOCK) {
            addToBatch(MORPHO_CREDIT, setOwnerCall);
        } else {
            console2.log("Skipping MorphoCredit - already owned by Timelock");
        }

        if (creditLineOwner != TIMELOCK) {
            addToBatch(CREDIT_LINE, transferOwnershipCall);
        } else {
            console2.log("Skipping CreditLine - already owned by Timelock");
        }

        // Execute via Safe
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Once executed:");
            console2.log("  - MorphoCredit.owner() will return Timelock address");
            console2.log("  - CreditLine.owner() will return Timelock address");
            console2.log("  - All owner-only functions will require timelock proposals");
            console2.log("");
            console2.log("=== Governance Hardening Complete! ===");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Verify the ownership configuration
    function verify() external view {
        console2.log("=== Verifying Ownership Configuration ===");
        console2.log("Expected owner: Timelock (%s)", TIMELOCK);
        console2.log("");

        address morphoCreditOwner = IMorphoBase(MORPHO_CREDIT).owner();
        address creditLineOwner = IOwnable(CREDIT_LINE).owner();

        console2.log("MorphoCredit.owner():", morphoCreditOwner);
        if (morphoCreditOwner == TIMELOCK) {
            console2.log("  [OK] Matches Timelock");
        } else {
            console2.log("  [FAIL] Does not match Timelock");
        }

        console2.log("");
        console2.log("CreditLine.owner():", creditLineOwner);
        if (creditLineOwner == TIMELOCK) {
            console2.log("  [OK] Matches Timelock");
        } else {
            console2.log("  [FAIL] Does not match Timelock");
        }

        console2.log("");
        if (morphoCreditOwner == TIMELOCK && creditLineOwner == TIMELOCK) {
            console2.log("=== All checks passed! ===");
        } else {
            console2.log("=== Some checks failed! ===");
        }
    }

    function run() external {
        this.run(false);
    }
}
