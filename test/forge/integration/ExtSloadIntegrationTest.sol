// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";

contract ExtSloadIntegrationTest is BaseTest {
    // ERC1967 proxy storage slots that should be excluded
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function testExtSloads(uint256 slot, bytes32 value0) public {
        // Exclude proxy-related storage slots
        vm.assume(bytes32(slot) != IMPLEMENTATION_SLOT);
        vm.assume(bytes32(slot) != ADMIN_SLOT);
        vm.assume(bytes32(slot / 2) != IMPLEMENTATION_SLOT);
        vm.assume(bytes32(slot / 2) != ADMIN_SLOT);

        bytes32[] memory slots = new bytes32[](2);
        slots[0] = bytes32(slot);
        slots[1] = bytes32(slot / 2);

        bytes32 value1 = keccak256(abi.encode(value0));
        vm.store(address(morpho), slots[0], value0);
        vm.store(address(morpho), slots[1], value1);

        bytes32[] memory values = morpho.extSloads(slots);

        assertEq(values.length, 2, "values.length");
        assertEq(values[0], slot > 0 ? value0 : value1, "value0");
        assertEq(values[1], value1, "value1");
    }
}
