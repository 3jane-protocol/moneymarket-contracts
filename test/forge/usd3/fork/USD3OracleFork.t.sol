// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

import {MainnetForkBase} from "./MainnetForkBase.t.sol";
import {USD3Oracle} from "../../../../src/usd3/periphery/USD3Oracle.sol";
import {sUSD3Oracle} from "../../../../src/usd3/periphery/sUSD3Oracle.sol";

/**
 * @title USD3OracleForkTest
 * @notice Fork smoke tests for USD3 and sUSD3 Morpho oracle constants.
 */
contract USD3OracleForkTest is MainnetForkBase {
    uint256 internal constant SAMPLE = 1e6;
    uint256 internal constant SCALE_FACTOR = 1e30;

    function test_usd3OracleMatchesMainnetProxy() public requiresFork {
        USD3Oracle oracle = new USD3Oracle();

        assertEq(oracle.USD3(), USD3_PROXY);
        assertGt(USD3_PROXY.code.length, 0, "USD3 proxy has no code");

        uint256 expected = ITokenizedStrategy(USD3_PROXY).convertToAssets(SAMPLE) * SCALE_FACTOR;

        assertEq(oracle.price(), expected);
        assertGt(oracle.price(), 0, "USD3 oracle price should be nonzero");
    }

    function test_susd3OracleMatchesMainnetProxies() public requiresFork {
        sUSD3Oracle oracle = new sUSD3Oracle();

        assertEq(oracle.USD3(), USD3_PROXY);
        assertEq(oracle.SUSD3(), SUSD3_PROXY);
        assertGt(USD3_PROXY.code.length, 0, "USD3 proxy has no code");
        assertGt(SUSD3_PROXY.code.length, 0, "sUSD3 proxy has no code");

        uint256 usd3Assets = ITokenizedStrategy(SUSD3_PROXY).convertToAssets(SAMPLE);
        uint256 usdcAssets = ITokenizedStrategy(USD3_PROXY).convertToAssets(usd3Assets);

        assertEq(oracle.price(), usdcAssets * SCALE_FACTOR);
        assertGt(oracle.price(), 0, "sUSD3 oracle price should be nonzero");
    }
}
