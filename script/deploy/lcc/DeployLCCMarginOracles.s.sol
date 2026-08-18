// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

interface IMorphoChainlinkOracleV2 {
    function BASE_VAULT() external view returns (address);
    function BASE_VAULT_CONVERSION_SAMPLE() external view returns (uint256);
    function BASE_FEED_1() external view returns (address);
    function BASE_FEED_2() external view returns (address);
    function QUOTE_VAULT() external view returns (address);
    function QUOTE_VAULT_CONVERSION_SAMPLE() external view returns (uint256);
    function QUOTE_FEED_1() external view returns (address);
    function QUOTE_FEED_2() external view returns (address);
    function SCALE_FACTOR() external view returns (uint256);
    function price() external view returns (uint256);
}

interface IMorphoChainlinkOracleV2Factory {
    function createMorphoChainlinkOracleV2(
        address baseVault,
        uint256 baseVaultConversionSample,
        address baseFeed1,
        address baseFeed2,
        uint256 baseTokenDecimals,
        address quoteVault,
        uint256 quoteVaultConversionSample,
        address quoteFeed1,
        address quoteFeed2,
        uint256 quoteTokenDecimals,
        bytes32 salt
    ) external returns (address oracle);

    function isMorphoChainlinkOracleV2(address oracle) external view returns (bool);
}

/// @notice Single source of truth for the reviewed factory argument table and its pinned verification values.
abstract contract LCCMarginOracleConfigs {
    struct OracleConfig {
        string name;
        address baseVault;
        uint256 baseVaultConversionSample;
        address baseFeed1;
        address baseFeed2;
        uint256 baseTokenDecimals;
        address quoteVault;
        uint256 quoteVaultConversionSample;
        address quoteFeed1;
        address quoteFeed2;
        uint256 quoteTokenDecimals;
        bytes32 salt;
        address predicted;
        uint256 scaleFactor;
        uint256 minPrice;
        uint256 maxPrice;
        uint256 pinnedAssets;
        uint256 pinnedPrice;
    }

    function oracleConfigs() public pure returns (OracleConfig[4] memory configs) {
        configs[0] = OracleConfig({
            name: "waEthUSDC/USDC",
            baseVault: 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E,
            baseVaultConversionSample: 1e12,
            baseFeed1: address(0),
            baseFeed2: address(0),
            baseTokenDecimals: 6,
            quoteVault: address(0),
            quoteVaultConversionSample: 1,
            quoteFeed1: address(0),
            quoteFeed2: address(0),
            quoteTokenDecimals: 6,
            salt: keccak256("3JANE_LCC_WAETHUSDC_USDC_ORACLE_V1"),
            predicted: 0xb6F6BAF2532859e8482A89FF75563426417f70fa,
            scaleFactor: 1e24,
            minPrice: 1e36,
            maxPrice: 2e36,
            pinnedAssets: 1_182_344_825_560,
            pinnedPrice: 1_182_344_825_560e24
        });
        configs[1] = OracleConfig({
            name: "waEthUSDT/USDC",
            baseVault: 0x7Bc3485026Ac48b6cf9BaF0A377477Fff5703Af8,
            baseVaultConversionSample: 1e12,
            baseFeed1: address(0),
            baseFeed2: address(0),
            baseTokenDecimals: 6,
            quoteVault: address(0),
            quoteVaultConversionSample: 1,
            quoteFeed1: address(0),
            quoteFeed2: address(0),
            quoteTokenDecimals: 6,
            salt: keccak256("3JANE_LCC_WAETHUSDT_USDC_ORACLE_V1"),
            predicted: 0x6e93B9C9a09aD1Fc1Dd5316b525BFFE1ec3a8b91,
            scaleFactor: 1e24,
            minPrice: 1e36,
            maxPrice: 2e36,
            pinnedAssets: 1_172_275_378_612,
            pinnedPrice: 1_172_275_378_612e24
        });
        configs[2] = OracleConfig({
            name: "sUSDS/USDC",
            baseVault: 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD,
            baseVaultConversionSample: 1e18,
            baseFeed1: address(0),
            baseFeed2: address(0),
            baseTokenDecimals: 18,
            quoteVault: address(0),
            quoteVaultConversionSample: 1,
            quoteFeed1: address(0),
            quoteFeed2: address(0),
            quoteTokenDecimals: 6,
            salt: keccak256("3JANE_LCC_SUSDS_USDC_ORACLE_V1"),
            predicted: 0x0B3Bf61B5BCfcc939870Bfc91E915470eA0a6be3,
            scaleFactor: 1e6,
            minPrice: 1e24,
            maxPrice: 2e24,
            pinnedAssets: 1_106_607_702_132_187_197,
            pinnedPrice: 1_106_607_702_132_187_197e6
        });
        configs[3] = OracleConfig({
            name: "sGHO/USDC",
            baseVault: 0xE1753F2e00940cC31213dd92013cF019DFE4ca1d,
            baseVaultConversionSample: 1e18,
            baseFeed1: address(0),
            baseFeed2: address(0),
            baseTokenDecimals: 18,
            quoteVault: address(0),
            quoteVaultConversionSample: 1,
            quoteFeed1: address(0),
            quoteFeed2: address(0),
            quoteTokenDecimals: 6,
            salt: keccak256("3JANE_LCC_SGHO_USDC_ORACLE_V1"),
            predicted: 0x1B36b2c17b4092f8CBBef06fEEb2031f6Ed3F7F8,
            scaleFactor: 1e6,
            minPrice: 9e23,
            maxPrice: 2e24,
            pinnedAssets: 1_010_930_595_783_047_216,
            pinnedPrice: 1_010_930_595_783_047_216e6
        });
    }
}

/// @title DeployLCCMarginOracles
/// @notice Idempotently creates four feedless share-rate oracles quoting LCC margin assets in USDC.
contract DeployLCCMarginOracles is Script, LCCMarginOracleConfigs {
    address internal constant ORACLE_FACTORY = 0x3A7bB36Ee3f3eE32A60e9f2b33c1e5f2E83ad766;

    function run() external returns (address[4] memory oracles) {
        require(block.chainid == 1, "mainnet only");
        require(ORACLE_FACTORY.code.length > 0, "oracle factory has no code");

        OracleConfig[4] memory configs = oracleConfigs();
        IMorphoChainlinkOracleV2Factory factory = IMorphoChainlinkOracleV2Factory(ORACLE_FACTORY);

        vm.startBroadcast();
        for (uint256 i; i < configs.length; ++i) {
            OracleConfig memory config = configs[i];
            address oracle = config.predicted;
            if (oracle.code.length == 0) {
                oracle = factory.createMorphoChainlinkOracleV2(
                    config.baseVault,
                    config.baseVaultConversionSample,
                    config.baseFeed1,
                    config.baseFeed2,
                    config.baseTokenDecimals,
                    config.quoteVault,
                    config.quoteVaultConversionSample,
                    config.quoteFeed1,
                    config.quoteFeed2,
                    config.quoteTokenDecimals,
                    config.salt
                );
                require(oracle == config.predicted, "created oracle address mismatch");
            }
            oracles[i] = oracle;
        }
        vm.stopBroadcast();

        for (uint256 i; i < configs.length; ++i) {
            _verify(factory, configs[i]);
            console2.log(configs[i].name, configs[i].predicted);
            console2.log("  price:", IMorphoChainlinkOracleV2(configs[i].predicted).price());
        }
    }

    function verify() external view {
        require(block.chainid == 1, "mainnet only");
        require(ORACLE_FACTORY.code.length > 0, "oracle factory has no code");
        OracleConfig[4] memory configs = oracleConfigs();
        IMorphoChainlinkOracleV2Factory factory = IMorphoChainlinkOracleV2Factory(ORACLE_FACTORY);
        for (uint256 i; i < configs.length; ++i) {
            _verify(factory, configs[i]);
        }
    }

    function _verify(IMorphoChainlinkOracleV2Factory factory, OracleConfig memory config) private view {
        require(config.predicted.code.length > 0, "oracle has no code");
        require(factory.isMorphoChainlinkOracleV2(config.predicted), "oracle is not factory registered");
        IMorphoChainlinkOracleV2 oracle = IMorphoChainlinkOracleV2(config.predicted);
        require(oracle.BASE_VAULT() == config.baseVault, "base vault mismatch");
        require(
            oracle.BASE_VAULT_CONVERSION_SAMPLE() == config.baseVaultConversionSample, "base conversion sample mismatch"
        );
        require(config.baseFeed1 == address(0) && oracle.BASE_FEED_1() == config.baseFeed1, "base feed 1 must be zero");
        require(config.baseFeed2 == address(0) && oracle.BASE_FEED_2() == config.baseFeed2, "base feed 2 must be zero");
        require(
            config.quoteVault == address(0) && oracle.QUOTE_VAULT() == config.quoteVault, "quote vault must be zero"
        );
        require(
            oracle.QUOTE_VAULT_CONVERSION_SAMPLE() == config.quoteVaultConversionSample,
            "quote conversion sample mismatch"
        );
        require(
            config.quoteFeed1 == address(0) && oracle.QUOTE_FEED_1() == config.quoteFeed1, "quote feed 1 must be zero"
        );
        require(
            config.quoteFeed2 == address(0) && oracle.QUOTE_FEED_2() == config.quoteFeed2, "quote feed 2 must be zero"
        );
        // Token decimals are constructor-only inputs in MorphoChainlinkOracleV2. SCALE_FACTOR verifies their
        // resulting arithmetic together with the two conversion samples.
        require(oracle.SCALE_FACTOR() == config.scaleFactor, "scale factor mismatch");
        uint256 livePrice = oracle.price();
        require(livePrice >= config.minPrice && livePrice <= config.maxPrice, "oracle price outside sane band");
    }
}
