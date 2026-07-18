// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {
    ITransparentUpgradeableProxy,
    ProxyAdmin
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockHelper} from "../../../utils/TimelockHelper.sol";

/// @notice Shared topology validation and calldata construction for the USD3 v1.2 upgrade scripts.
abstract contract USD3v12UpgradeBase is TimelockHelper {
    address internal constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address internal constant PROXY_ADMIN = 0x41C838664a9C64905537fF410333B9f5964cC596;
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
    }

    function _usd3Impl() internal view returns (address newImpl) {
        newImpl = vm.envAddress("USD3_IMPL");
        require(newImpl != address(0), "USD3_IMPL not set");
        require(newImpl.code.length > 0, "USD3_IMPL has no code");
    }

    function _buildOperation(address newImpl)
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
        targets = new address[](1);
        values = new uint256[](1);
        datas = new bytes[](1);

        targets[0] = PROXY_ADMIN;
        values[0] = 0;
        datas[0] =
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(USD3_PROXY), newImpl, bytes("")));

        salt = generateSalt("USD3 v1.2 Upgrade");
        predecessor = bytes32(0);
    }
}
