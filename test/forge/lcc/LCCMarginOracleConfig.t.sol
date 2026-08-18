// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {LCCMarginOracleConfigs} from "../../../script/deploy/lcc/DeployLCCMarginOracles.s.sol";

contract LCCMarginOracleConfigTest is Test, LCCMarginOracleConfigs {
    struct ReferenceConfig {
        address oracle;
        address baseVault;
        uint256 baseVaultConversionSample;
        address baseFeed1;
        address baseFeed2;
        address quoteVault;
        uint256 quoteVaultConversionSample;
        address quoteFeed1;
        address quoteFeed2;
        uint256 scaleFactor;
    }

    function testFourFeedlessFactoryConfigurationsArePinned() public pure {
        OracleConfig[4] memory configs = oracleConfigs();
        for (uint256 i; i < configs.length; ++i) {
            OracleConfig memory config = configs[i];
            assertEq(config.baseFeed1, address(0));
            assertEq(config.baseFeed2, address(0));
            assertEq(config.quoteVault, address(0));
            assertEq(config.quoteVaultConversionSample, 1);
            assertEq(config.quoteFeed1, address(0));
            assertEq(config.quoteFeed2, address(0));
            assertEq(config.quoteTokenDecimals, 6);
            assertEq(config.scaleFactor * config.pinnedAssets, config.pinnedPrice);
        }

        assertEq(configs[0].baseVaultConversionSample, 1e12);
        assertEq(configs[1].baseVaultConversionSample, 1e12);
        assertEq(configs[2].baseVaultConversionSample, 1e18);
        assertEq(configs[3].baseVaultConversionSample, 1e18);
        assertEq(configs[0].baseVault, 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E);
        assertEq(configs[1].baseVault, 0x7Bc3485026Ac48b6cf9BaF0A377477Fff5703Af8);
        assertEq(configs[2].baseVault, 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
        assertEq(configs[3].baseVault, 0xE1753F2e00940cC31213dd92013cF019DFE4ca1d);
        assertEq(configs[0].baseTokenDecimals, 6);
        assertEq(configs[1].baseTokenDecimals, 6);
        assertEq(configs[2].baseTokenDecimals, 18);
        assertEq(configs[3].baseTokenDecimals, 18);
    }

    function testSaltsAndPredictedAddressesArePinnedAsOneUnit() public pure {
        OracleConfig[4] memory configs = oracleConfigs();
        assertEq(configs[0].salt, 0x8a0bf2b085ec004054d02f11dee0d41fdd015ea784bc98dd877e2720dee655d3);
        assertEq(configs[1].salt, 0x064a8aed54215d38e035e6e163a999c1e46e6aadb206304e939847341013a231);
        assertEq(configs[2].salt, 0x45ab250c237346bcc4ea79ddd7ae43631399a570e9d958b91bd2818a77dfa05c);
        assertEq(configs[3].salt, 0xbf1c68eb58e3c83b93a71da4c430b9e1b88c0a1be2761cfc0f19f0aec93591e5);
        assertEq(configs[0].salt, keccak256("3JANE_LCC_WAETHUSDC_USDC_ORACLE_V1"));
        assertEq(configs[1].salt, keccak256("3JANE_LCC_WAETHUSDT_USDC_ORACLE_V1"));
        assertEq(configs[2].salt, keccak256("3JANE_LCC_SUSDS_USDC_ORACLE_V1"));
        assertEq(configs[3].salt, keccak256("3JANE_LCC_SGHO_USDC_ORACLE_V1"));
        assertEq(configs[0].predicted, 0xb6F6BAF2532859e8482A89FF75563426417f70fa);
        assertEq(configs[1].predicted, 0x6e93B9C9a09aD1Fc1Dd5316b525BFFE1ec3a8b91);
        assertEq(configs[2].predicted, 0x0B3Bf61B5BCfcc939870Bfc91E915470eA0a6be3);
        assertEq(configs[3].predicted, 0x1B36b2c17b4092f8CBBef06fEEb2031f6Ed3F7F8);
    }

    function testPinnedArithmeticMatchesFeedlessReferenceModel() public pure {
        OracleConfig[4] memory configs = oracleConfigs();
        assertEq(configs[0].pinnedPrice, 1_182_344_825_560e24);
        assertEq(configs[1].pinnedPrice, 1_172_275_378_612e24);
        assertEq(configs[2].pinnedPrice, 1_106_607_702_132_187_197e6);
        assertEq(configs[3].pinnedPrice, 1_010_930_595_783_047_216e6);
    }

    function testReferenceOracleConfigurationsAndArithmeticArePinned() public pure {
        ReferenceConfig[3] memory references = _referenceConfigs();

        ReferenceConfig memory susde = references[0];
        assertEq(susde.oracle, 0x873CD44b860DEDFe139f93e12A4AcCa0926Ffb87);
        assertEq(susde.baseVault, 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
        assertEq(susde.baseVaultConversionSample, 1e18);
        assertEq(susde.baseFeed1, address(0));
        assertEq(susde.baseFeed2, address(0));
        assertEq(susde.quoteVault, address(0));
        assertEq(susde.quoteVaultConversionSample, 1);
        assertEq(susde.quoteFeed1, address(0));
        assertEq(susde.quoteFeed2, address(0));
        assertEq(susde.scaleFactor, 1e6);
        assertEq(_feedlessPrice(susde.scaleFactor, 1_243_880_000_000_000_000), 1_243_880_000_000_000_000e6);

        ReferenceConfig memory susdsUsdt = references[1];
        assertEq(susdsUsdt.oracle, 0x0C426d174FC88B7A25d59945Ab2F7274Bf7B4C79);
        assertEq(susdsUsdt.baseVault, 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
        assertEq(susdsUsdt.baseVaultConversionSample, 1e18);
        assertEq(susdsUsdt.baseFeed1, 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9);
        assertEq(susdsUsdt.baseFeed2, address(0));
        assertEq(susdsUsdt.quoteVault, address(0));
        assertEq(susdsUsdt.quoteVaultConversionSample, 1);
        assertEq(susdsUsdt.quoteFeed1, 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D);
        assertEq(susdsUsdt.quoteFeed2, address(0));
        assertEq(susdsUsdt.scaleFactor, 1e6);
        assertEq(
            _singleFeedRatioPrice(susdsUsdt.scaleFactor, 1_106_607_702_132_187_197, 1e8, 1e8),
            1_106_607_702_132_187_197e6
        );

        ReferenceConfig memory usd3 = references[2];
        assertEq(usd3.oracle, 0x68b4c2B2b2e245AB54a3bD55DfD5A9d84f029C06);
        assertEq(usd3.baseVault, 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc);
        assertEq(usd3.baseVaultConversionSample, 1e6);
        assertEq(usd3.baseFeed1, address(0));
        assertEq(usd3.baseFeed2, address(0));
        assertEq(usd3.quoteVault, address(0));
        assertEq(usd3.quoteVaultConversionSample, 1);
        assertEq(usd3.quoteFeed1, address(0));
        assertEq(usd3.quoteFeed2, address(0));
        assertEq(usd3.scaleFactor, 1e30);
        assertEq(_feedlessPrice(usd3.scaleFactor, 1_171_000), 1_171_000e30);
    }

    function _feedlessPrice(uint256 scaleFactor, uint256 convertedAssets) private pure returns (uint256) {
        return scaleFactor * convertedAssets;
    }

    function _singleFeedRatioPrice(
        uint256 scaleFactor,
        uint256 convertedAssets,
        uint256 baseFeedAnswer,
        uint256 quoteFeedAnswer
    ) private pure returns (uint256) {
        return (scaleFactor * convertedAssets * baseFeedAnswer) / quoteFeedAnswer;
    }

    function _referenceConfigs() private pure returns (ReferenceConfig[3] memory references) {
        references[0] = ReferenceConfig({
            oracle: 0x873CD44b860DEDFe139f93e12A4AcCa0926Ffb87,
            baseVault: 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497,
            baseVaultConversionSample: 1e18,
            baseFeed1: address(0),
            baseFeed2: address(0),
            quoteVault: address(0),
            quoteVaultConversionSample: 1,
            quoteFeed1: address(0),
            quoteFeed2: address(0),
            scaleFactor: 1e6
        });
        references[1] = ReferenceConfig({
            oracle: 0x0C426d174FC88B7A25d59945Ab2F7274Bf7B4C79,
            baseVault: 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD,
            baseVaultConversionSample: 1e18,
            baseFeed1: 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9,
            baseFeed2: address(0),
            quoteVault: address(0),
            quoteVaultConversionSample: 1,
            quoteFeed1: 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D,
            quoteFeed2: address(0),
            scaleFactor: 1e6
        });
        references[2] = ReferenceConfig({
            oracle: 0x68b4c2B2b2e245AB54a3bD55DfD5A9d84f029C06,
            baseVault: 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc,
            baseVaultConversionSample: 1e6,
            baseFeed1: address(0),
            baseFeed2: address(0),
            quoteVault: address(0),
            quoteVaultConversionSample: 1,
            quoteFeed1: address(0),
            quoteFeed2: address(0),
            scaleFactor: 1e30
        });
    }
}
