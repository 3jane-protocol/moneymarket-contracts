// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IMorpho, MarketParams, Id} from "../../interfaces/IMorpho.sol";

interface IUSD3 is IStrategy {
    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event SUSD3StrategyUpdated(address oldStrategy, address newStrategy);
    event SupplyCapExemptUpdated(address indexed account, bool exempt);
    event MinDepositUpdated(uint256 newMinDeposit);
    event TrancheShareSynced(uint256 trancheShare);

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // Core protocol integration
    function morphoCredit() external view returns (IMorpho);
    function marketId() external view returns (Id);
    function marketParams() external view returns (MarketParams memory);
    function nav() external view returns (uint256);
    function symbol() external pure returns (string memory);

    // Configuration parameters
    function maxOnCredit() external view returns (uint256);
    function sUSD3() external view returns (address);
    function supplyCapExempt(address account) external view returns (bool);
    function minDeposit() external view returns (uint256);
    function maxSubordinationRatio() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                    MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setSUSD3(address _sUSD3) external;
    function setSupplyCapExempt(address _account, bool _exempt) external;
    function setMinDeposit(uint256 _minDeposit) external;

    /*//////////////////////////////////////////////////////////////
                        KEEPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function syncTrancheShare() external;
}
