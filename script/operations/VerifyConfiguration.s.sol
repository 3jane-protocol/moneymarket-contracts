// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {ICreditLine} from "../../src/interfaces/ICreditLine.sol";

/// @title VerifyConfiguration
/// @notice Verifies all admin/owner/keeper/management addresses across deployed 3Jane contracts
/// @dev Run with: forge script script/operations/VerifyConfiguration.s.sol --rpc-url $ETH_RPC_URL
contract VerifyConfiguration is Script {
    // ═══════════════════════════════════════════════════════════════════════════
    // EXPECTED ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    address private constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address private constant TEAM_MULTISIG = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONTRACT ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    // Core Protocol
    address private constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address private constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;

    // ProxyAdmins
    address private constant PROTOCOL_CONFIG_PROXY_ADMIN = 0x2C4A7eb2e31BaaF4A98a38dC590321FdB9eFDbA8;
    address private constant MORPHO_CREDIT_PROXY_ADMIN = 0x0b0dA0C2D0e21C43C399c09f830e46E3341fe1D4;
    address private constant IRM_PROXY_ADMIN = 0x5B7961DaFce9e412d26d6B92d06A9e0db3E3c7CF;
    address private constant USD3_PROXY_ADMIN = 0x41C838664a9C64905537fF410333B9f5964cC596;
    address private constant SUSD3_PROXY_ADMIN = 0xecda55c32966B00592Ed3922E386063e1Bc752c2;

    // Credit Infrastructure
    address private constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address private constant INSURANCE_FUND = 0x4507B5B23340D248457d955a211C8B0634D29935;
    address private constant MARKDOWN_CONTROLLER = 0xF0eaE71092F3c9411A9EAb8F81E7d91D29726214;
    address private constant EMERGENCY_CONTROLLER = 0x792A1450a3D2023e2De6Bb29208031dEa52eA12c;

    // Tokens & Strategies
    address private constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address private constant SUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;
    address private constant JANE = 0x333333330522F64EE8d0b3039c460b41670e3404;
    address private constant REWARDS_DISTRIBUTOR = 0xaC6985D4dBcd89CCAD71DB9bf0309eaF57F064e8;

    // Periphery
    address private constant HELPER = 0x2A66F992bF227D2e50eF19EDD21503C3c4F3f682;

    // JANE Token Roles
    bytes32 private constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 private passCount;
    uint256 private failCount;
    uint256 private warnCount;

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRYPOINTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Report-only mode - logs all results, never reverts
    function run() external {
        _verify(false);
    }

    /// @notice Strict mode - reverts if any critical check fails (for CI)
    function runStrict() external {
        _verify(true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION LOGIC
    // ═══════════════════════════════════════════════════════════════════════════

    function _verify(bool strict) internal {
        console2.log("");
        console2.log("===============================================");
        console2.log("       3Jane Configuration Audit");
        console2.log("===============================================");
        console2.log("");

        _verifyProxyAdminOwnership();
        _verifyCoreProtocolOwnership();
        _verifyCreditInfrastructure();
        _verifyMorphoCreditConfig();
        _verifyControllers();
        _verifyJaneToken();
        _verifyStrategies();
        _verifyRewardsDistributor();

        _printSummary();

        if (strict && failCount > 0) {
            revert("Configuration audit failed");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION SECTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function _verifyProxyAdminOwnership() internal {
        console2.log("[ProxyAdmin Ownership] (all should be Timelock)");

        _checkOwner("ProtocolConfig ProxyAdmin", PROTOCOL_CONFIG_PROXY_ADMIN, TIMELOCK);
        _checkOwner("MorphoCredit ProxyAdmin", MORPHO_CREDIT_PROXY_ADMIN, TIMELOCK);
        _checkOwner("IRM ProxyAdmin", IRM_PROXY_ADMIN, TIMELOCK);
        _checkOwner("USD3 ProxyAdmin", USD3_PROXY_ADMIN, TIMELOCK);
        _checkOwner("sUSD3 ProxyAdmin", SUSD3_PROXY_ADMIN, TIMELOCK);

        console2.log("");
    }

    function _verifyCoreProtocolOwnership() internal {
        console2.log("[Core Protocol Ownership]");

        _checkOwner("MorphoCredit", MORPHO_CREDIT, TIMELOCK);
        _checkOwner("ProtocolConfig", PROTOCOL_CONFIG, TIMELOCK);

        address emergencyAdmin = _getEmergencyAdmin(PROTOCOL_CONFIG);
        _checkAddress("ProtocolConfig.emergencyAdmin", emergencyAdmin, EMERGENCY_CONTROLLER);

        console2.log("");
    }

    function _verifyCreditInfrastructure() internal {
        console2.log("[Credit Infrastructure]");

        _checkOwner("CreditLine", CREDIT_LINE, TIMELOCK);

        address ozd = ICreditLine(CREDIT_LINE).ozd();
        _checkAddress("CreditLine.ozd", ozd, EMERGENCY_CONTROLLER);

        address mm = ICreditLine(CREDIT_LINE).mm();
        _checkAddress("CreditLine.mm", mm, MARKDOWN_CONTROLLER);

        address insuranceFund = _getInsuranceFund(CREDIT_LINE);
        _checkAddress("CreditLine.insuranceFund", insuranceFund, INSURANCE_FUND);

        address prover = ICreditLine(CREDIT_LINE).prover();
        if (prover == address(0)) {
            _warn("CreditLine.prover", "disabled (address(0))");
        } else {
            _info("CreditLine.prover", prover);
        }

        console2.log("");
    }

    function _verifyMorphoCreditConfig() internal {
        console2.log("[MorphoCredit Configuration]");

        address helper = _getHelper(MORPHO_CREDIT);
        _checkAddress("MorphoCredit.helper", helper, HELPER);

        address usd3 = _getUsd3(MORPHO_CREDIT);
        _checkAddress("MorphoCredit.usd3", usd3, USD3);

        address feeRecipient = _getFeeRecipient(MORPHO_CREDIT);
        if (feeRecipient == address(0)) {
            _warn("MorphoCredit.feeRecipient", "not set (no fees collected)");
        } else {
            _info("MorphoCredit.feeRecipient", feeRecipient);
        }

        console2.log("");
    }

    function _verifyControllers() internal {
        console2.log("[Controllers]");

        // EmergencyController
        _checkOwner("EmergencyController", EMERGENCY_CONTROLLER, TEAM_MULTISIG);

        address ecProtocolConfig = _getProtocolConfig(EMERGENCY_CONTROLLER);
        _checkAddress("EmergencyController.protocolConfig", ecProtocolConfig, PROTOCOL_CONFIG);

        address ecCreditLine = _getCreditLine(EMERGENCY_CONTROLLER);
        _checkAddress("EmergencyController.creditLine", ecCreditLine, CREDIT_LINE);

        // MarkdownController
        address mcMorphoCredit = _getMorphoCredit(MARKDOWN_CONTROLLER);
        _checkAddress("MarkdownController.morphoCredit", mcMorphoCredit, MORPHO_CREDIT);

        address mcJane = _getJane(MARKDOWN_CONTROLLER);
        _checkAddress("MarkdownController.jane", mcJane, JANE);

        address mcProtocolConfig = _getMcProtocolConfig(MARKDOWN_CONTROLLER);
        _checkAddress("MarkdownController.protocolConfig", mcProtocolConfig, PROTOCOL_CONFIG);

        console2.log("");
    }

    function _verifyJaneToken() internal {
        console2.log("[JANE Token]");

        // Check OWNER_ROLE
        uint256 ownerCount = _getRoleMemberCount(JANE, OWNER_ROLE);
        if (ownerCount != 1) {
            _fail("JANE OWNER_ROLE count", _toString(ownerCount), "1");
        } else {
            address owner = _getRoleMember(JANE, OWNER_ROLE, 0);
            _checkAddress("JANE OWNER_ROLE[0]", owner, TIMELOCK);
        }

        // Check MINTER_ROLE
        uint256 minterCount = _getRoleMemberCount(JANE, MINTER_ROLE);
        if (minterCount != 1) {
            _fail("JANE MINTER_ROLE count", _toString(minterCount), "1");
        } else {
            address minter = _getRoleMember(JANE, MINTER_ROLE, 0);
            _checkAddress("JANE MINTER_ROLE[0]", minter, REWARDS_DISTRIBUTOR);
        }

        // Check markdownController
        address markdownController = _getMarkdownController(JANE);
        _checkAddress("JANE.markdownController", markdownController, MARKDOWN_CONTROLLER);

        // Check transferable (informational)
        bool transferable = _getTransferable(JANE);
        _info("JANE.transferable", transferable ? "true" : "false");

        console2.log("");
    }

    function _verifyStrategies() internal {
        console2.log("[USD3/sUSD3 Strategies]");

        // USD3
        address usd3Management = _getManagement(USD3);
        _checkAddress("USD3.management", usd3Management, TEAM_MULTISIG);

        address usd3Keeper = _getKeeper(USD3);
        _checkAddress("USD3.keeper", usd3Keeper, TEAM_MULTISIG);

        address usd3Susd3 = _getSUSD3(USD3);
        _checkAddress("USD3.sUSD3", usd3Susd3, SUSD3);

        address usd3PendingMgmt = _getPendingManagement(USD3);
        if (usd3PendingMgmt != address(0)) {
            _warn("USD3.pendingManagement", _toHexString(usd3PendingMgmt));
        }

        // sUSD3
        address susd3Management = _getManagement(SUSD3);
        _checkAddress("sUSD3.management", susd3Management, TEAM_MULTISIG);

        address susd3Keeper = _getKeeper(SUSD3);
        _checkAddress("sUSD3.keeper", susd3Keeper, TEAM_MULTISIG);

        address susd3PendingMgmt = _getPendingManagement(SUSD3);
        if (susd3PendingMgmt != address(0)) {
            _warn("sUSD3.pendingManagement", _toHexString(susd3PendingMgmt));
        }

        console2.log("");
    }

    function _verifyRewardsDistributor() internal {
        console2.log("[RewardsDistributor]");

        _checkOwner("RewardsDistributor", REWARDS_DISTRIBUTOR, TIMELOCK);

        address jane = _getRewardsJane(REWARDS_DISTRIBUTOR);
        _checkAddress("RewardsDistributor.jane", jane, JANE);

        console2.log("");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS - CHECKS
    // ═══════════════════════════════════════════════════════════════════════════

    function _checkOwner(string memory name, address target, address expected) internal {
        address actual = _getOwner(target);
        _checkAddress(string.concat(name, ".owner"), actual, expected);
    }

    function _checkAddress(string memory name, address actual, address expected) internal {
        if (actual == expected) {
            _pass(name, _formatAddress(actual, expected));
        } else {
            _fail(name, _toHexString(actual), _toHexString(expected));
        }
    }

    function _pass(string memory name, string memory value) internal {
        console2.log(unicode"  ✅", name, value);
        passCount++;
    }

    function _fail(string memory name, string memory actual, string memory expected) internal {
        console2.log(unicode"  ❌", name);
        console2.log("      actual:  ", actual);
        console2.log("      expected:", expected);
        failCount++;
    }

    function _warn(string memory name, string memory value) internal {
        console2.log(unicode"  ⚠️ ", name, value);
        warnCount++;
    }

    function _info(string memory name, string memory value) internal pure {
        console2.log(unicode"  ℹ️ ", name, value);
    }

    function _info(string memory name, address value) internal pure {
        console2.log(unicode"  ℹ️ ", name, _toHexString(value));
    }

    function _printSummary() internal view {
        console2.log("===============================================");
        console2.log("                  SUMMARY");
        console2.log("===============================================");
        console2.log("  Passed: ", passCount);
        console2.log("  Failed: ", failCount);
        console2.log("  Warnings:", warnCount);
        console2.log("===============================================");

        if (failCount == 0) {
            console2.log(unicode"  ✅ All critical checks passed");
        } else {
            console2.log(unicode"  ❌ CONFIGURATION ISSUES DETECTED");
        }
        console2.log("");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS - CALLS
    // ═══════════════════════════════════════════════════════════════════════════

    function _getOwner(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("owner()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getEmergencyAdmin(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("emergencyAdmin()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getInsuranceFund(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("insuranceFund()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getHelper(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("helper()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getUsd3(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("usd3()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getFeeRecipient(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("feeRecipient()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getProtocolConfig(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("protocolConfig()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getCreditLine(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("creditLine()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getMorphoCredit(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("morphoCredit()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getJane(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("jane()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getMcProtocolConfig(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("protocolConfig()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getMarkdownController(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("markdownController()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getTransferable(address target) internal view returns (bool) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("transferable()"));
        if (!success || data.length < 32) return false;
        return abi.decode(data, (bool));
    }

    function _getRoleMemberCount(address target, bytes32 role) internal view returns (uint256) {
        (bool success, bytes memory data) =
            target.staticcall(abi.encodeWithSignature("getRoleMemberCount(bytes32)", role));
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _getRoleMember(address target, bytes32 role, uint256 index) internal view returns (address) {
        (bool success, bytes memory data) =
            target.staticcall(abi.encodeWithSignature("getRoleMember(bytes32,uint256)", role, index));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getManagement(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("management()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getKeeper(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("keeper()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getPendingManagement(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("pendingManagement()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getSUSD3(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("sUSD3()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _getRewardsJane(address target) internal view returns (address) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("jane()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS - FORMATTING
    // ═══════════════════════════════════════════════════════════════════════════

    function _formatAddress(address actual, address expected) internal pure returns (string memory) {
        if (expected == TIMELOCK) {
            return "Timelock";
        } else if (expected == TEAM_MULTISIG) {
            return "Team Multisig";
        } else {
            return _toHexString(actual);
        }
    }

    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory buffer = new bytes(42);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(uint160(addr) >> (8 * (19 - i)));
            buffer[2 + i * 2] = _toHexChar(b >> 4);
            buffer[3 + i * 2] = _toHexChar(b & 0x0f);
        }
        return string(buffer);
    }

    function _toHexChar(uint8 value) internal pure returns (bytes1) {
        if (value < 10) {
            return bytes1(uint8(0x30) + value);
        } else {
            return bytes1(uint8(0x61) + value - 10);
        }
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
