// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IIrm} from "../../../src/interfaces/IIrm.sol";
import {MarketParams, Market} from "../../../src/interfaces/IMorpho.sol";
import {MathLib, WAD} from "../../../src/libraries/MathLib.sol";

contract ConfigurableIrmMock is IIrm {
    using MathLib for uint256;

    uint256 public apr;

    function setApr(uint256 _apr) external {
        apr = _apr;
    }

    function borrowRateView(MarketParams memory, Market memory) public view returns (uint256) {
        // Convert APR to per-second rate
        return apr / 365 days;
    }

    function borrowRate(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        return borrowRateView(marketParams, market);
    }
}
