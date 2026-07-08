// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";

interface ITokenizedStrategyKeeper {
    function management() external view returns (address);
    function keeper() external view returns (address);
    function setKeeper(address keeper) external;
}

/// @title SetTokenKeepersToDeployerSafe
/// @notice Sets USD3 and sUSD3 keepers to the 3Jane deployer EOA via the protocol Safe.
contract SetTokenKeepersToDeployerSafe is Script, SafeHelper {
    address private constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address private constant SUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;
    address private constant THREE_JANE_DEPLOYER = 0x1226858E04b9d077258F153275613734421cD06B;

    struct TokenKeeperStatus {
        string label;
        address token;
        address management;
        address currentKeeper;
        bool needsUpdate;
    }

    function run() external {
        this.run(false);
    }

    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        TokenKeeperStatus[2] memory statuses = _loadStatuses(safe);
        uint256 updates = _countUpdates(statuses);
        require(updates > 0, "keepers already set");

        _logStatuses("Set USD3/sUSD3 Keepers To 3Jane Deployer", statuses);
        console2.log("Send to Safe:", send);
        console2.log("");

        _addSetKeeperIfNeeded(statuses[0]);
        _addSetKeeperIfNeeded(statuses[1]);

        if (send) {
            console2.log("");
            console2.log("Sending keeper update transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully.");
        } else {
            console2.log("");
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully.");
        }
    }

    function preview() external view {
        _logStatuses("Preview USD3/sUSD3 Keeper Updates", _loadStatuses(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)));
    }

    function verify() external view {
        require(ITokenizedStrategyKeeper(USD3).keeper() == THREE_JANE_DEPLOYER, "USD3 keeper mismatch");
        require(ITokenizedStrategyKeeper(SUSD3).keeper() == THREE_JANE_DEPLOYER, "sUSD3 keeper mismatch");

        console2.log("=== Verify USD3/sUSD3 Keepers ===");
        console2.log("USD3 keeper:", ITokenizedStrategyKeeper(USD3).keeper());
        console2.log("sUSD3 keeper:", ITokenizedStrategyKeeper(SUSD3).keeper());
        console2.log("Expected keeper:", THREE_JANE_DEPLOYER);
    }

    function _loadStatuses(address safe) private view returns (TokenKeeperStatus[2] memory statuses) {
        statuses[0] = _loadStatus("USD3", USD3, safe);
        statuses[1] = _loadStatus("sUSD3", SUSD3, safe);
    }

    function _loadStatus(string memory label, address token, address safe)
        private
        view
        returns (TokenKeeperStatus memory status)
    {
        ITokenizedStrategyKeeper strategy = ITokenizedStrategyKeeper(token);
        address management = strategy.management();
        require(management == safe, string.concat(label, " management is not protocol Safe"));

        address currentKeeper = strategy.keeper();
        status = TokenKeeperStatus({
            label: label,
            token: token,
            management: management,
            currentKeeper: currentKeeper,
            needsUpdate: currentKeeper != THREE_JANE_DEPLOYER
        });
    }

    function _addSetKeeperIfNeeded(TokenKeeperStatus memory status) private {
        if (!status.needsUpdate) {
            console2.log("%s keeper already set; skipping", status.label);
            return;
        }

        addToBatch(status.token, abi.encodeCall(ITokenizedStrategyKeeper.setKeeper, (THREE_JANE_DEPLOYER)));
        console2.log("Added %s setKeeper call", status.label);
    }

    function _countUpdates(TokenKeeperStatus[2] memory statuses) private pure returns (uint256 updates) {
        for (uint256 i = 0; i < statuses.length; i++) {
            if (statuses[i].needsUpdate) updates++;
        }
    }

    function _logStatuses(string memory label, TokenKeeperStatus[2] memory statuses) private view {
        console2.log("===", label, "===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        console2.log("Target keeper:", THREE_JANE_DEPLOYER);
        console2.log("");

        for (uint256 i = 0; i < statuses.length; i++) {
            console2.log(statuses[i].label);
            console2.log("  token:", statuses[i].token);
            console2.log("  management:", statuses[i].management);
            console2.log("  current keeper:", statuses[i].currentKeeper);
            console2.log("  needs update:", statuses[i].needsUpdate);
        }
    }

    function _baseFeeOkay() private view returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(50)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console2.log("Base fee too high: %d gwei > %d gwei limit", block.basefee / 1e9, basefeeLimit / 1e9);
            return false;
        }
        console2.log("Base fee OK: %d gwei", block.basefee / 1e9);
        return true;
    }
}
