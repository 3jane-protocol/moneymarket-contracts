// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "../../../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";

import {IOracle} from "../../../../src/interfaces/IOracle.sol";
import {sUSD3Oracle} from "../../../../src/usd3/periphery/sUSD3Oracle.sol";

contract sUSD3OracleTest is Test {
    sUSD3Oracle internal oracle;

    uint256 internal constant SAMPLE = 1e6;
    uint256 internal constant SCALE_FACTOR = 1e30;

    function setUp() public {
        oracle = new sUSD3Oracle();
    }

    function test_priceAtOneToOnePps() public {
        _mockSusd3Price(SAMPLE);
        _mockUsd3Price(SAMPLE, SAMPLE);

        assertEq(oracle.price(), 1e36);
    }

    function test_priceTracksSusd3Pps() public {
        uint256 usd3Assets = 1.25e6;
        _mockSusd3Price(usd3Assets);
        _mockUsd3Price(usd3Assets, usd3Assets);

        assertEq(oracle.price(), usd3Assets * SCALE_FACTOR);
    }

    function test_priceTracksUsd3Pps() public {
        uint256 usd3Assets = SAMPLE;
        uint256 usdcAssets = 1.15e6;
        _mockSusd3Price(usd3Assets);
        _mockUsd3Price(usd3Assets, usdcAssets);

        assertEq(oracle.price(), usdcAssets * SCALE_FACTOR);
    }

    function test_priceChainsBothPpsValues() public {
        uint256 usd3Assets = 1.2e6;
        uint256 usdcAssets = 1.32e6;
        _mockSusd3Price(usd3Assets);
        _mockUsd3Price(usd3Assets, usdcAssets);

        assertEq(oracle.price(), usdcAssets * SCALE_FACTOR);
    }

    function test_priceCanReturnZero() public {
        _mockSusd3Price(SAMPLE);
        _mockUsd3Price(SAMPLE, 0);

        assertEq(oracle.price(), 0);
    }

    function test_priceCanReturnZeroWhenSusd3ConvertsToZero() public {
        _mockSusd3Price(0);
        _mockUsd3Price(0, 0);

        assertEq(oracle.price(), 0);
    }

    function test_implementsIOracle() public {
        _mockSusd3Price(SAMPLE);
        _mockUsd3Price(SAMPLE, SAMPLE);

        assertEq(IOracle(address(oracle)).price(), 1e36);
    }

    function test_usesMainnetProxyConstants() public view {
        assertEq(oracle.USD3(), 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc);
        assertEq(oracle.SUSD3(), 0xf689555121e529Ff0463e191F9Bd9d1E496164a7);
    }

    function _mockSusd3Price(uint256 usd3Assets) internal {
        vm.mockCall(oracle.SUSD3(), abi.encodeCall(IERC4626.convertToAssets, (SAMPLE)), abi.encode(usd3Assets));
    }

    function _mockUsd3Price(uint256 usd3Assets, uint256 usdcAssets) internal {
        vm.mockCall(oracle.USD3(), abi.encodeCall(IERC4626.convertToAssets, (usd3Assets)), abi.encode(usdcAssets));
    }
}
