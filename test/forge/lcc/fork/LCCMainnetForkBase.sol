// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {LCCMarginOracleConfigs} from "../../../../script/deploy/lcc/DeployLCCMarginOracles.s.sol";

interface ILCCForkOracleFactory {
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

interface ILCCForkOracle {
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

interface ILCCForkERC4626 {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

abstract contract LCCMainnetForkBase is Test, LCCMarginOracleConfigs {
    uint256 internal constant FORK_BLOCK = 25_779_100;
    address internal constant ORACLE_FACTORY = 0x3A7bB36Ee3f3eE32A60e9f2b33c1e5f2E83ad766;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant A_USDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;
    address internal constant WA_ETH_USDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address internal constant WA_ETH_USDT = 0x7Bc3485026Ac48b6cf9BaF0A377477Fff5703Af8;

    bool internal forkEnabled;

    modifier requiresFork() {
        if (!forkEnabled) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public virtual {
        if (keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) != keccak256("fork")) return;
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        require(bytes(rpcUrl).length != 0, "fork profile is active but neither MAINNET_RPC_URL nor ETH_RPC_URL is set");
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        forkEnabled = true;
    }

    function _createOracle(OracleConfig memory config) internal returns (ILCCForkOracle oracle) {
        address created = ILCCForkOracleFactory(ORACLE_FACTORY)
            .createMorphoChainlinkOracleV2(
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
        assertEq(created, config.predicted);
        return ILCCForkOracle(created);
    }
}
