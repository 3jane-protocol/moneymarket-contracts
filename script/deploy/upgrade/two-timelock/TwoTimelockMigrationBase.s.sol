// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {console2} from "forge-std/Script.sol";
import {TimelockHelper} from "../../../utils/TimelockHelper.sol";
import {ITimelockController} from "../../../../src/interfaces/ITimelockController.sol";

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IProtocolConfigEmergencyAdmin {
    function emergencyAdmin() external view returns (address);
}

interface ICreditLineOzd {
    function ozd() external view returns (address);
}

/// @notice Shared constants, discovery, validation, and calldata construction for the two-timelock migration.
abstract contract TwoTimelockMigrationBase is TimelockHelper {
    address constant EXISTING_24H_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant MAIN_MULTISIG = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address constant DEPLOYER_EOA = 0x1226858E04b9d077258F153275613734421cD06B;
    address constant CURRENT_EMERGENCY_CONTROLLER = 0x84B31B84917485E221305EDf590B8E3660d2E051;

    address constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address constant IRM = 0x1d434D2899f81F3C3fdf52C814A6E23318f9C7Df;
    address constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address constant SUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;

    address constant EXPECTED_PROTOCOL_CONFIG_PROXY_ADMIN = 0x2C4A7eb2e31BaaF4A98a38dC590321FdB9eFDbA8;
    address constant EXPECTED_MORPHO_CREDIT_PROXY_ADMIN = 0x0b0dA0C2D0e21C43C399c09f830e46E3341fe1D4;
    address constant EXPECTED_IRM_PROXY_ADMIN = 0x5B7961DaFce9e412d26d6B92d06A9e0db3E3c7CF;
    address constant EXPECTED_USD3_PROXY_ADMIN = 0x41C838664a9C64905537fF410333B9f5964cC596;
    address constant EXPECTED_SUSD3_PROXY_ADMIN = 0xecda55c32966B00592Ed3922E386063e1Bc752c2;

    uint256 constant SEVEN_DAY_DELAY = 7 days;

    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function _buildOperation(address sevenDayTimelock)
        internal
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory datas,
            bytes32 salt,
            bytes32 predecessor
        )
    {
        address[] memory proxyAdmins = _discoverProxyAdmins();
        ITimelockController existingTimelock = ITimelockController(EXISTING_24H_TIMELOCK);

        targets = new address[](6);
        values = new uint256[](6);
        datas = new bytes[](6);

        for (uint256 i = 0; i < proxyAdmins.length; i++) {
            targets[i] = proxyAdmins[i];
            values[i] = 0;
            datas[i] = abi.encodeCall(IOwnable.transferOwnership, (sevenDayTimelock));
        }

        targets[5] = EXISTING_24H_TIMELOCK;
        values[5] = 0;
        datas[5] =
            abi.encodeCall(ITimelockController.revokeRole, (existingTimelock.DEFAULT_ADMIN_ROLE(), MAIN_MULTISIG));

        salt = generateSalt("Two Timelock Migration");
        predecessor = bytes32(0);
    }

    function _validatePreconditions(address sevenDayTimelock) internal view {
        _validateSevenDayTimelock(sevenDayTimelock);
        _validateExistingTimelockAdminState();
        _validateNoPointerChange();
        _validateProxyAdminsOwnedBy(EXISTING_24H_TIMELOCK);
    }

    function _validateFinalState(address sevenDayTimelock) internal view {
        _validateSevenDayTimelock(sevenDayTimelock);
        _validateNoPointerChange();
        _validateProxyAdminsOwnedBy(sevenDayTimelock);
        _validateProxyAdminsNotOwnedBy(EXISTING_24H_TIMELOCK);

        ITimelockController existingTimelock = ITimelockController(EXISTING_24H_TIMELOCK);
        require(
            !existingTimelock.hasRole(existingTimelock.DEFAULT_ADMIN_ROLE(), MAIN_MULTISIG),
            "main multisig still 24h timelock admin"
        );
    }

    function _validateSevenDayTimelock(address sevenDayTimelock) internal view {
        require(sevenDayTimelock != address(0), "SEVEN_DAY_TIMELOCK not set");
        require(sevenDayTimelock.code.length > 0, "SEVEN_DAY_TIMELOCK has no code");

        ITimelockController newTimelock = ITimelockController(sevenDayTimelock);
        bytes32 defaultAdminRole = newTimelock.DEFAULT_ADMIN_ROLE();
        require(defaultAdminRole == bytes32(0), "7d timelock DEFAULT_ADMIN_ROLE mismatch");
        require(newTimelock.getMinDelay() == SEVEN_DAY_DELAY, "7d timelock delay mismatch");
        require(newTimelock.hasRole(defaultAdminRole, sevenDayTimelock), "7d timelock missing self admin");
        require(!newTimelock.hasRole(defaultAdminRole, MAIN_MULTISIG), "main multisig is 7d timelock admin");
        require(!newTimelock.hasRole(defaultAdminRole, EXISTING_24H_TIMELOCK), "24h timelock is 7d timelock admin");
        require(newTimelock.hasRole(newTimelock.PROPOSER_ROLE(), MAIN_MULTISIG), "main multisig missing 7d proposer");
        require(newTimelock.hasRole(newTimelock.CANCELLER_ROLE(), MAIN_MULTISIG), "main multisig missing 7d canceller");
        require(newTimelock.hasRole(newTimelock.EXECUTOR_ROLE(), MAIN_MULTISIG), "main multisig missing 7d executor");
        require(newTimelock.hasRole(newTimelock.EXECUTOR_ROLE(), DEPLOYER_EOA), "deployer eoa missing 7d executor");
    }

    function _validateExistingTimelockAdminState() internal view {
        ITimelockController existingTimelock = ITimelockController(EXISTING_24H_TIMELOCK);
        bytes32 defaultAdminRole = existingTimelock.DEFAULT_ADMIN_ROLE();
        require(defaultAdminRole == bytes32(0), "24h timelock DEFAULT_ADMIN_ROLE mismatch");
        require(existingTimelock.hasRole(defaultAdminRole, EXISTING_24H_TIMELOCK), "24h timelock missing self admin");
        require(existingTimelock.hasRole(defaultAdminRole, MAIN_MULTISIG), "main multisig missing 24h timelock admin");
    }

    function _validateNoPointerChange() internal view {
        address emergencyAdmin = IProtocolConfigEmergencyAdmin(PROTOCOL_CONFIG).emergencyAdmin();
        address ozd = ICreditLineOzd(CREDIT_LINE).ozd();

        require(emergencyAdmin == CURRENT_EMERGENCY_CONTROLLER, "ProtocolConfig.emergencyAdmin mismatch");
        require(ozd == CURRENT_EMERGENCY_CONTROLLER, "CreditLine.ozd mismatch");
    }

    function _validateProxyAdminsOwnedBy(address expectedOwner) internal view {
        address[] memory proxyAdmins = _discoverProxyAdmins();
        string[] memory names = _proxyNames();

        for (uint256 i = 0; i < proxyAdmins.length; i++) {
            require(proxyAdmins[i].code.length > 0, string.concat(names[i], " ProxyAdmin has no code"));
            require(
                IOwnable(proxyAdmins[i]).owner() == expectedOwner, string.concat(names[i], " ProxyAdmin owner mismatch")
            );
        }
    }

    function _validateProxyAdminsNotOwnedBy(address disallowedOwner) internal view {
        address[] memory proxyAdmins = _discoverProxyAdmins();
        string[] memory names = _proxyNames();

        for (uint256 i = 0; i < proxyAdmins.length; i++) {
            require(
                IOwnable(proxyAdmins[i]).owner() != disallowedOwner,
                string.concat(names[i], " ProxyAdmin still owned by 24h timelock")
            );
        }
    }

    function _discoverProxyAdmins() internal view returns (address[] memory proxyAdmins) {
        address[] memory proxies = _proxies();
        address[] memory expectedAdmins = _expectedProxyAdmins();
        string[] memory names = _proxyNames();

        proxyAdmins = new address[](proxies.length);
        for (uint256 i = 0; i < proxies.length; i++) {
            proxyAdmins[i] = _getProxyAdmin(proxies[i]);
            require(proxyAdmins[i] == expectedAdmins[i], string.concat(names[i], " ProxyAdmin discovery mismatch"));
        }
    }

    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 adminSlot = vm.load(proxy, ADMIN_SLOT);
        return address(uint160(uint256(adminSlot)));
    }

    function _proxies() internal pure returns (address[] memory proxies) {
        proxies = new address[](5);
        proxies[0] = PROTOCOL_CONFIG;
        proxies[1] = MORPHO_CREDIT;
        proxies[2] = IRM;
        proxies[3] = USD3;
        proxies[4] = SUSD3;
    }

    function _expectedProxyAdmins() internal pure returns (address[] memory proxyAdmins) {
        proxyAdmins = new address[](5);
        proxyAdmins[0] = EXPECTED_PROTOCOL_CONFIG_PROXY_ADMIN;
        proxyAdmins[1] = EXPECTED_MORPHO_CREDIT_PROXY_ADMIN;
        proxyAdmins[2] = EXPECTED_IRM_PROXY_ADMIN;
        proxyAdmins[3] = EXPECTED_USD3_PROXY_ADMIN;
        proxyAdmins[4] = EXPECTED_SUSD3_PROXY_ADMIN;
    }

    function _proxyNames() internal pure returns (string[] memory names) {
        names = new string[](5);
        names[0] = "ProtocolConfig";
        names[1] = "MorphoCredit";
        names[2] = "AdaptiveCurveIrm";
        names[3] = "USD3";
        names[4] = "sUSD3";
    }

    function _logDiscoveredProxyAdmins() internal view {
        address[] memory proxyAdmins = _discoverProxyAdmins();
        string[] memory names = _proxyNames();

        console2.log("Discovered ProxyAdmins:");
        for (uint256 i = 0; i < proxyAdmins.length; i++) {
            console2.log("  %s:", names[i], proxyAdmins[i]);
        }
        console2.log("");
    }
}
