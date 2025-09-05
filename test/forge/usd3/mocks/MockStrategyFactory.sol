// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/**
 * @title MockStrategyFactory
 * @notice Mock factory for TokenizedStrategy testing
 */
contract MockStrategyFactory {
    address public governance;
    uint16 public protocolFeeBps;
    address public protocolFeeRecipient;

    constructor() {
        governance = msg.sender;
        protocolFeeRecipient = msg.sender;
        protocolFeeBps = 0; // No fees for testing
    }

    function protocol_fee_config() external view returns (uint16, address) {
        return (protocolFeeBps, protocolFeeRecipient);
    }

    function set_protocol_fee_bps(uint16 _bps) external {
        require(msg.sender == governance, "!governance");
        protocolFeeBps = _bps;
    }

    function set_protocol_fee_recipient(address _recipient) external {
        require(msg.sender == governance, "!governance");
        protocolFeeRecipient = _recipient;
    }

    function setGovernance(address _governance) external {
        require(msg.sender == governance, "!governance");
        governance = _governance;
    }
}
