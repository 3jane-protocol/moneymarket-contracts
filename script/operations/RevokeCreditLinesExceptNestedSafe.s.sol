// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {SafeHelper} from "../utils/SafeHelper.sol";
import {ICreditLine} from "../../src/interfaces/ICreditLine.sol";
import {IMorpho, IMorphoCredit, Id, Position} from "../../src/interfaces/IMorpho.sol";

interface IEmergencyCreditLineController {
    function EMERGENCY_AUTHORIZED_ROLE() external view returns (bytes32);
    function creditLine() external view returns (address);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function emergencyRevokeCreditLine(Id id, address borrower) external;
}

interface IProtocolConfigValues {
    function config(bytes32 key) external view returns (uint256);
}

/// @title RevokeCreditLinesExceptNestedSafe
/// @notice Revokes every active credit line except 3Jane's nested borrower via the operational controller.
contract RevokeCreditLinesExceptNestedSafe is Script, SafeHelper {
    address private constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant CONTROLLER = 0x84B31B84917485E221305EDf590B8E3660d2E051;
    address private constant NESTED_BORROWER = 0x3Ff3ff33D20a086834A095ed6ed562c9e189291b;

    ICreditLine private constant CREDIT_LINE = ICreditLine(0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9);
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);
    uint256 private constant FROM_BLOCK = 23241534;
    bytes32 private constant MIN_CREDIT_LINE = keccak256("MIN_CREDIT_LINE");

    struct RevokePlan {
        address[] borrowers;
        uint256[] currentCredits;
        uint256 nestedCredit;
        uint256 discoveredBorrowers;
        uint256 skippedNoCredit;
        bool nestedDiscovered;
    }

    function run() external {
        this.run(false);
    }

    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        _validateControllerWiring(safe);

        RevokePlan memory plan = _buildPlan();
        require(plan.borrowers.length > 0, "no active non-nested credit lines");

        _logPlan("Revoke Non-Nested Credit Lines", plan);
        console2.log("Send to Safe:", send);
        console2.log("");

        for (uint256 i = 0; i < plan.borrowers.length; i++) {
            bytes memory callData = abi.encodeCall(
                IEmergencyCreditLineController.emergencyRevokeCreditLine, (MARKET_ID, plan.borrowers[i])
            );
            addToBatch(CONTROLLER, callData);
            console2.log("Added revoke call:", plan.borrowers[i]);
        }

        if (send) {
            console2.log("");
            console2.log("Sending revoke transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully.");
        } else {
            console2.log("");
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully.");
        }
    }

    function preview() external {
        _validateControllerWiring(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        _logPlan("Preview Non-Nested Credit Line Revocations", _buildPlan());
    }

    function verify() external {
        RevokePlan memory plan = _buildPlan();
        IMorpho morpho = IMorpho(CREDIT_LINE.MORPHO());

        uint256 nonNestedActive = 0;
        for (uint256 i = 0; i < plan.borrowers.length; i++) {
            uint256 currentCredit = uint256(morpho.position(MARKET_ID, plan.borrowers[i]).collateral);
            if (currentCredit != 0) {
                nonNestedActive++;
                console2.log("Still active:", plan.borrowers[i]);
                console2.log("  Credit:", currentCredit);
            }
        }

        uint256 nestedCredit = uint256(morpho.position(MARKET_ID, NESTED_BORROWER).collateral);

        console2.log("=== Verify Non-Nested Credit Line Revocations ===");
        console2.log("Active non-nested credit lines:", nonNestedActive);
        console2.log("Nested borrower:", NESTED_BORROWER);
        console2.log("Nested credit:", nestedCredit);

        require(nonNestedActive == 0, "non-nested credit line remains active");
        require(nestedCredit > 0, "nested borrower credit not active");
    }

    function _buildPlan() private returns (RevokePlan memory plan) {
        require(block.number >= FROM_BLOCK, "fork before borrower scan block");

        IMorpho morpho = IMorpho(CREDIT_LINE.MORPHO());
        address[] memory discovered = _collectCreditLineBorrowers(address(morpho));

        address[] memory tempBorrowers = new address[](discovered.length);
        uint256[] memory tempCredits = new uint256[](discovered.length);
        uint256 revokeCount = 0;
        uint256 skippedNoCredit = 0;
        uint256 nestedCredit = 0;
        bool nestedDiscovered = false;

        for (uint256 i = 0; i < discovered.length; i++) {
            address borrower = discovered[i];
            Position memory position = morpho.position(MARKET_ID, borrower);
            uint256 currentCredit = uint256(position.collateral);

            if (borrower == NESTED_BORROWER) {
                nestedDiscovered = true;
                nestedCredit = currentCredit;
                continue;
            }

            if (currentCredit == 0) {
                skippedNoCredit++;
                continue;
            }

            tempBorrowers[revokeCount] = borrower;
            tempCredits[revokeCount] = currentCredit;
            revokeCount++;
        }

        address[] memory borrowers = new address[](revokeCount);
        uint256[] memory currentCredits = new uint256[](revokeCount);
        for (uint256 i = 0; i < revokeCount; i++) {
            borrowers[i] = tempBorrowers[i];
            currentCredits[i] = tempCredits[i];
        }

        plan = RevokePlan({
            borrowers: borrowers,
            currentCredits: currentCredits,
            nestedCredit: nestedCredit,
            discoveredBorrowers: discovered.length,
            skippedNoCredit: skippedNoCredit,
            nestedDiscovered: nestedDiscovered
        });
    }

    function _validateControllerWiring(address safe) private view {
        IEmergencyCreditLineController controller = IEmergencyCreditLineController(CONTROLLER);
        address morpho = CREDIT_LINE.MORPHO();
        address protocolConfig = IMorphoCredit(morpho).protocolConfig();
        uint256 minCreditLine = IProtocolConfigValues(protocolConfig).config(MIN_CREDIT_LINE);

        require(CREDIT_LINE.ozd() == CONTROLLER, "CreditLine OZD is not controller");
        require(controller.creditLine() == address(CREDIT_LINE), "controller CreditLine mismatch");
        require(controller.hasRole(controller.EMERGENCY_AUTHORIZED_ROLE(), safe), "Safe lacks emergency role");
        require(minCreditLine == 0, "MIN_CREDIT_LINE must be zero for emergency revoke");
    }

    function _collectCreditLineBorrowers(address morphoCreditAddress) private returns (address[] memory borrowers) {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = keccak256("SetCreditLine(bytes32,address,uint256)");
        topics[1] = bytes32(Id.unwrap(MARKET_ID));

        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(FROM_BLOCK, block.number, morphoCreditAddress, topics);
        address[] memory temp = new address[](logs.length);
        uint256 count = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length < 3) continue;
            address borrower = address(uint160(uint256(logs[i].topics[2])));
            if (_contains(temp, count, borrower)) continue;

            temp[count] = borrower;
            count++;
        }

        borrowers = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            borrowers[i] = temp[i];
        }
    }

    function _logPlan(string memory label, RevokePlan memory plan) private view {
        console2.log("===", label, "===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        console2.log("Controller:", CONTROLLER);
        console2.log("CreditLine:", address(CREDIT_LINE));
        console2.log("MorphoCredit:", CREDIT_LINE.MORPHO());
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("From block:", FROM_BLOCK);
        console2.log("");

        console2.log("Discovered borrowers:", plan.discoveredBorrowers);
        console2.log("Skipped no current credit:", plan.skippedNoCredit);
        console2.log("Nested borrower:", NESTED_BORROWER);
        console2.log("Nested discovered:", plan.nestedDiscovered);
        console2.log("Nested current credit:", plan.nestedCredit);
        console2.log("Borrowers to revoke:", plan.borrowers.length);
        console2.log("");

        for (uint256 i = 0; i < plan.borrowers.length; i++) {
            console2.log("Borrower:", plan.borrowers[i]);
            console2.log("  Current credit:", plan.currentCredits[i]);
        }
    }

    function _contains(address[] memory values, uint256 count, address value) private pure returns (bool) {
        for (uint256 i = 0; i < count; i++) {
            if (values[i] == value) return true;
        }
        return false;
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
