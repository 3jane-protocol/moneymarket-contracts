// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IMorpho, MarketParams, Id} from "@3jane-morpho-blue/interfaces/IMorpho.sol";

interface IUSD3 is IStrategy {
    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event SUSD3StrategyUpdated(address oldStrategy, address newStrategy);
    event WhitelistUpdated(address indexed user, bool allowed);
    event MinDepositUpdated(uint256 newMinDeposit);
    event TrancheShareSynced(uint256 trancheShare);

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // Core protocol integration
    function morphoCredit() external view returns (IMorpho);
    function marketId() external view returns (Id);
    function marketParams() external view returns (MarketParams memory);
    function symbol() external pure returns (string memory);

    // Configuration parameters
    function maxOnCredit() external view returns (uint256);
    function susd3Strategy() external view returns (address);
    function whitelistEnabled() external view returns (bool);
    function whitelist(address user) external view returns (bool);
    function minDeposit() external view returns (uint256);
    function minCommitmentTime() external view returns (uint256);
    function depositTimestamp(address user) external view returns (uint256);
    function maxSubordinationRatio() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                    MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setSusd3Strategy(address _susd3Strategy) external;
    function setWhitelistEnabled(bool _enabled) external;
    function setWhitelist(address _user, bool _allowed) external;
    function setMinDeposit(uint256 _minDeposit) external;
    function setMinCommitmentTime(uint256 _minCommitmentTime) external;

    /*//////////////////////////////////////////////////////////////
                        KEEPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function syncTrancheShare() external;
}
