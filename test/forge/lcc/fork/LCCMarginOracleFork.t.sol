// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILCCForkERC4626, ILCCForkOracle, ILCCForkOracleFactory, LCCMainnetForkBase} from "./LCCMainnetForkBase.sol";

contract LCCMarginOracleForkTest is LCCMainnetForkBase {
    address internal constant SUSDE_USDC_ORACLE = 0x873CD44b860DEDFe139f93e12A4AcCa0926Ffb87;
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address internal constant USD3_USDC_ORACLE = 0x68b4c2B2b2e245AB54a3bD55DfD5A9d84f029C06;
    address internal constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    function testCreatesAllFourFeedlessOraclesAtPinnedAddresses() public requiresFork {
        OracleConfig[4] memory configs = oracleConfigs();
        ILCCForkOracleFactory factory = ILCCForkOracleFactory(ORACLE_FACTORY);
        for (uint256 i; i < configs.length; ++i) {
            OracleConfig memory config = configs[i];
            assertEq(config.predicted.code.length, 0);
            assertFalse(factory.isMorphoChainlinkOracleV2(config.predicted));
            ILCCForkOracle oracle = _createOracle(config);
            assertTrue(factory.isMorphoChainlinkOracleV2(address(oracle)));
            _assertConfig(oracle, config);
            assertEq(
                ILCCForkERC4626(config.baseVault).convertToAssets(config.baseVaultConversionSample), config.pinnedAssets
            );
            assertEq(oracle.price(), config.pinnedPrice);
        }
    }

    function testPriceTracksOnlyShareConversionRateAfterWarp() public requiresFork {
        OracleConfig[4] memory configs = oracleConfigs();
        ILCCForkOracle[4] memory oracles;
        uint256[4] memory beforeAssets;
        for (uint256 i; i < configs.length; ++i) {
            oracles[i] = _createOracle(configs[i]);
            beforeAssets[i] =
                ILCCForkERC4626(configs[i].baseVault).convertToAssets(configs[i].baseVaultConversionSample);
        }

        vm.warp(block.timestamp + 7 days);
        bool anyRateMoved;
        for (uint256 i; i < configs.length; ++i) {
            uint256 converted =
                ILCCForkERC4626(configs[i].baseVault).convertToAssets(configs[i].baseVaultConversionSample);
            assertEq(oracles[i].price(), configs[i].scaleFactor * converted);
            if (converted != beforeAssets[i]) anyRateMoved = true;
        }
        assertTrue(anyRateMoved, "share-rate movement required");
    }

    function testDeployedFeedlessReferencesUseSameArithmetic() public requiresFork {
        _assertFeedlessReference(SUSDE_USDC_ORACLE, SUSDE, 1e18, 1e6);
        _assertFeedlessReference(USD3_USDC_ORACLE, USD3, 1e6, 1e30);
    }

    function _assertFeedlessReference(address oracleAddress, address baseVault, uint256 sample, uint256 scaleFactor)
        private
        view
    {
        assertTrue(ILCCForkOracleFactory(ORACLE_FACTORY).isMorphoChainlinkOracleV2(oracleAddress));
        ILCCForkOracle referenceOracle = ILCCForkOracle(oracleAddress);
        assertEq(referenceOracle.BASE_VAULT(), baseVault);
        assertEq(referenceOracle.BASE_VAULT_CONVERSION_SAMPLE(), sample);
        assertEq(referenceOracle.BASE_FEED_1(), address(0));
        assertEq(referenceOracle.BASE_FEED_2(), address(0));
        assertEq(referenceOracle.QUOTE_VAULT(), address(0));
        assertEq(referenceOracle.QUOTE_VAULT_CONVERSION_SAMPLE(), 1);
        assertEq(referenceOracle.QUOTE_FEED_1(), address(0));
        assertEq(referenceOracle.QUOTE_FEED_2(), address(0));
        assertEq(referenceOracle.SCALE_FACTOR(), scaleFactor);
        uint256 converted = ILCCForkERC4626(referenceOracle.BASE_VAULT())
            .convertToAssets(referenceOracle.BASE_VAULT_CONVERSION_SAMPLE());
        assertEq(referenceOracle.price(), referenceOracle.SCALE_FACTOR() * converted);
    }

    function _assertConfig(ILCCForkOracle oracle, OracleConfig memory config) private view {
        assertEq(oracle.BASE_VAULT(), config.baseVault);
        assertEq(oracle.BASE_VAULT_CONVERSION_SAMPLE(), config.baseVaultConversionSample);
        assertEq(oracle.BASE_FEED_1(), config.baseFeed1);
        assertEq(oracle.BASE_FEED_2(), config.baseFeed2);
        assertEq(oracle.QUOTE_VAULT(), config.quoteVault);
        assertEq(oracle.QUOTE_VAULT_CONVERSION_SAMPLE(), config.quoteVaultConversionSample);
        assertEq(oracle.QUOTE_FEED_1(), config.quoteFeed1);
        assertEq(oracle.QUOTE_FEED_2(), config.quoteFeed2);
        assertEq(oracle.SCALE_FACTOR(), config.scaleFactor);
    }
}
