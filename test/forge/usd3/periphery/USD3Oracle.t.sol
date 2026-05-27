// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "../../../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";

import {IOracle} from "../../../../src/interfaces/IOracle.sol";
import {USD3Oracle} from "../../../../src/usd3/periphery/USD3Oracle.sol";

contract USD3OracleTest is Test {
    USD3Oracle internal oracle;

    uint256 internal constant SAMPLE = 1e6;
    uint256 internal constant SCALE_FACTOR = 1e30;

    function setUp() public {
        oracle = new USD3Oracle();
    }

    function test_priceAtOneToOnePps() public {
        _mockUsd3Price(SAMPLE);

        assertEq(oracle.price(), 1e36);
    }

    function test_priceTracksHigherPps() public {
        uint256 assets = 1.25e6;
        _mockUsd3Price(assets);

        assertEq(oracle.price(), assets * SCALE_FACTOR);
    }

    function test_priceTracksLowerPps() public {
        uint256 assets = 0.8e6;
        _mockUsd3Price(assets);

        assertEq(oracle.price(), assets * SCALE_FACTOR);
    }

    function test_priceCanReturnZero() public {
        _mockUsd3Price(0);

        assertEq(oracle.price(), 0);
    }

    function test_implementsIOracle() public {
        _mockUsd3Price(SAMPLE);

        assertEq(IOracle(address(oracle)).price(), 1e36);
    }

    function test_usesMainnetUsd3Proxy() public view {
        assertEq(oracle.USD3(), 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc);
    }

    function _mockUsd3Price(uint256 assets) internal {
        vm.mockCall(oracle.USD3(), abi.encodeCall(IERC4626.convertToAssets, (SAMPLE)), abi.encode(assets));
    }
}
