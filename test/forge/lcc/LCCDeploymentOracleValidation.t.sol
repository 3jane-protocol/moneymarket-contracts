// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";

import {LCCMarginOracleValidation} from "../../../script/utils/LCCMarginOracleValidation.sol";

contract LCCDeploymentOracleValidationHarness is LCCMarginOracleValidation {
    function requireMarginOracle(address marginAsset, address marginOracle, uint256 minPrice, uint256 maxPrice)
        external
        view
    {
        _requireMarginOracle(marginAsset, marginOracle, minPrice, maxPrice);
    }
}

contract LCCDeploymentOracleMock {
    address public immutable BASE_VAULT;
    uint256 internal immutable oraclePrice;

    constructor(address baseVault, uint256 price_) {
        BASE_VAULT = baseVault;
        oraclePrice = price_;
    }

    function price() external view returns (uint256) {
        return oraclePrice;
    }
}

contract LCCDeploymentGetterlessOracleMock {
    function price() external pure returns (uint256) {
        return 15e35;
    }
}

contract LCCDeploymentOracleValidationTest is Test {
    uint256 internal constant MIN_PRICE = 1e36;
    uint256 internal constant MAX_PRICE = 2e36;
    uint256 internal constant IN_BAND_PRICE = 15e35;

    LCCDeploymentOracleValidationHarness internal harness = new LCCDeploymentOracleValidationHarness();
    address internal marginAsset = makeAddr("marginAsset");

    function test_ConsistentOraclePricedInBandIsAccepted() public {
        LCCDeploymentOracleMock oracle = new LCCDeploymentOracleMock(marginAsset, IN_BAND_PRICE);

        harness.requireMarginOracle(marginAsset, address(oracle), MIN_PRICE, MAX_PRICE);
    }

    function test_MismatchedBaseVaultIsRejected() public {
        LCCDeploymentOracleMock oracle = new LCCDeploymentOracleMock(makeAddr("otherMarginAsset"), IN_BAND_PRICE);

        vm.expectRevert(bytes("Margin oracle base vault mismatch"));
        harness.requireMarginOracle(marginAsset, address(oracle), MIN_PRICE, MAX_PRICE);
    }

    function test_PriceBelowBandIsRejected() public {
        LCCDeploymentOracleMock oracle = new LCCDeploymentOracleMock(marginAsset, MIN_PRICE - 1);

        vm.expectRevert(bytes("Margin oracle price below minimum"));
        harness.requireMarginOracle(marginAsset, address(oracle), MIN_PRICE, MAX_PRICE);
    }

    function test_PriceAboveBandIsRejected() public {
        LCCDeploymentOracleMock oracle = new LCCDeploymentOracleMock(marginAsset, MAX_PRICE + 1);

        vm.expectRevert(bytes("Margin oracle price above maximum"));
        harness.requireMarginOracle(marginAsset, address(oracle), MIN_PRICE, MAX_PRICE);
    }

    function test_OracleWithoutBaseVaultGetterIsRejected() public {
        LCCDeploymentGetterlessOracleMock oracle = new LCCDeploymentGetterlessOracleMock();

        vm.expectRevert();
        harness.requireMarginOracle(marginAsset, address(oracle), MIN_PRICE, MAX_PRICE);
    }

    function test_InvalidConfiguredRangeIsRejected() public {
        LCCDeploymentOracleMock oracle = new LCCDeploymentOracleMock(marginAsset, IN_BAND_PRICE);

        vm.expectRevert(bytes("Invalid margin oracle price range"));
        harness.requireMarginOracle(marginAsset, address(oracle), MAX_PRICE, MIN_PRICE);
    }
}
