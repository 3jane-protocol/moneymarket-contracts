// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {TimelockHelper} from "../../../utils/TimelockHelper.sol";

interface IProtocolConfigSetEmergencyAdmin {
    function setEmergencyAdmin(address _emergencyAdmin) external;
}

interface ICreditLineSetOzd {
    function setOzd(address newOzd) external;
}

/// @notice Shared constants and calldata construction for OperationalController upgrade scripts.
abstract contract OperationalControllerUpgradeBase is TimelockHelper {
    address constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    function _buildOperation(address newController)
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

        targets[0] = PROTOCOL_CONFIG;
        values[0] = 0;
        datas[0] = abi.encodeCall(IProtocolConfigSetEmergencyAdmin.setEmergencyAdmin, (newController));

        targets[1] = CREDIT_LINE;
        values[1] = 0;
        datas[1] = abi.encodeCall(ICreditLineSetOzd.setOzd, (newController));

        salt = generateSalt("OperationalController Upgrade");
        predecessor = bytes32(0);
    }
}
