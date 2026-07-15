// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {KeeperRelayer} from "../../../../src/usd3/KeeperRelayer.sol";

interface ITokenizedStrategyKeeper {
    function management() external view returns (address);
    function keeper() external view returns (address);
    function performanceFeeRecipient() external view returns (address);
    function performanceFee() external view returns (uint16);
    function setKeeper(address keeper) external;
    function setPerformanceFeeRecipient(address performanceFeeRecipient) external;
    function setPerformanceFee(uint16 performanceFee) external;
}

/// @title SetRelayerKeeperSafe
/// @notice Configures the KeeperRelayer and report wiring for USD3 and sUSD3 via the protocol Safe.
contract SetRelayerKeeperSafe is Script, SafeHelper {
    address private constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address private constant SUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;

    struct TokenKeeperStatus {
        string label;
        address token;
        address management;
        address currentKeeper;
        bool needsUpdate;
    }

    struct WiringStatus {
        address currentPerformanceFeeRecipient;
        uint16 currentSusd3PerformanceFee;
        bool performanceFeeRecipientNeedsUpdate;
        bool susd3PerformanceFeeNeedsUpdate;
    }

    function run() external {
        this.run(false);
    }

    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        address relayer = vm.envAddress("KEEPER_RELAYER");
        _validateRelayer(relayer);

        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        TokenKeeperStatus[2] memory statuses = _loadStatuses(safe, relayer);
        WiringStatus memory wiring = _loadWiringStatus();
        uint256 updates = _countUpdates(statuses, wiring);
        require(updates > 0, "configuration already set");

        _logStatuses("Set USD3/sUSD3 KeeperRelayer Configuration", statuses, wiring, relayer);
        console2.log("Send to Safe:", send);
        console2.log("");

        _addSetKeeperIfNeeded(statuses[0], relayer);
        _addSetKeeperIfNeeded(statuses[1], relayer);
        _addPerformanceFeeRecipientIfNeeded(wiring);
        _addSusd3PerformanceFeeIfNeeded(wiring);

        if (send) {
            console2.log("");
            console2.log("Sending KeeperRelayer configuration transaction to Safe API...");
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
        address relayer = vm.envAddress("KEEPER_RELAYER");
        _validateRelayer(relayer);

        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        _logStatuses(
            "Preview USD3/sUSD3 KeeperRelayer Configuration", _loadStatuses(safe, relayer), _loadWiringStatus(), relayer
        );
    }

    function verify() external view {
        address relayer = vm.envAddress("KEEPER_RELAYER");
        _validateRelayer(relayer);

        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        TokenKeeperStatus[2] memory statuses = _loadStatuses(safe, relayer);
        WiringStatus memory wiring = _loadWiringStatus();

        require(statuses[0].currentKeeper == relayer, "USD3 keeper mismatch");
        require(statuses[1].currentKeeper == relayer, "sUSD3 keeper mismatch");
        require(wiring.currentPerformanceFeeRecipient == SUSD3, "USD3 performance fee recipient mismatch");
        require(wiring.currentSusd3PerformanceFee == 0, "sUSD3 performance fee mismatch");

        console2.log("=== Verify USD3/sUSD3 KeeperRelayer Configuration ===");
        console2.log("Safe address:", safe);
        console2.log("USD3 management:", statuses[0].management);
        console2.log("sUSD3 management:", statuses[1].management);
        console2.log("USD3 keeper:", statuses[0].currentKeeper);
        console2.log("sUSD3 keeper:", statuses[1].currentKeeper);
        console2.log("Expected keeper:", relayer);
        console2.log("USD3 performance fee recipient:", wiring.currentPerformanceFeeRecipient);
        console2.log("Expected performance fee recipient:", SUSD3);
        console2.log("sUSD3 performance fee:", wiring.currentSusd3PerformanceFee);
        console2.log("Expected sUSD3 performance fee:", uint256(0));
    }

    function _validateRelayer(address relayer) private view {
        require(relayer.code.length > 0, "KEEPER_RELAYER has no code");
        require(
            KeeperRelayer(relayer).usd3() == USD3 && KeeperRelayer(relayer).susd3() == SUSD3,
            "KEEPER_RELAYER strategy pair mismatch"
        );
    }

    function _loadStatuses(address safe, address relayer) private view returns (TokenKeeperStatus[2] memory statuses) {
        statuses[0] = _loadStatus("USD3", USD3, safe, relayer);
        statuses[1] = _loadStatus("sUSD3", SUSD3, safe, relayer);
    }

    function _loadStatus(string memory label, address token, address safe, address relayer)
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
            needsUpdate: currentKeeper != relayer
        });
    }

    function _loadWiringStatus() private view returns (WiringStatus memory wiring) {
        address currentPerformanceFeeRecipient = ITokenizedStrategyKeeper(USD3).performanceFeeRecipient();
        uint16 currentSusd3PerformanceFee = ITokenizedStrategyKeeper(SUSD3).performanceFee();

        wiring = WiringStatus({
            currentPerformanceFeeRecipient: currentPerformanceFeeRecipient,
            currentSusd3PerformanceFee: currentSusd3PerformanceFee,
            performanceFeeRecipientNeedsUpdate: currentPerformanceFeeRecipient != SUSD3,
            susd3PerformanceFeeNeedsUpdate: currentSusd3PerformanceFee != 0
        });
    }

    function _addSetKeeperIfNeeded(TokenKeeperStatus memory status, address relayer) private {
        if (!status.needsUpdate) {
            console2.log("%s keeper already set; skipping", status.label);
            return;
        }

        addToBatch(status.token, abi.encodeCall(ITokenizedStrategyKeeper.setKeeper, (relayer)));
        console2.log("Added %s setKeeper call", status.label);
    }

    function _addPerformanceFeeRecipientIfNeeded(WiringStatus memory wiring) private {
        if (!wiring.performanceFeeRecipientNeedsUpdate) {
            console2.log("USD3 performance fee recipient already set; skipping");
            return;
        }

        addToBatch(USD3, abi.encodeCall(ITokenizedStrategyKeeper.setPerformanceFeeRecipient, (SUSD3)));
        console2.log("Added USD3 setPerformanceFeeRecipient call");
    }

    function _addSusd3PerformanceFeeIfNeeded(WiringStatus memory wiring) private {
        if (!wiring.susd3PerformanceFeeNeedsUpdate) {
            console2.log("sUSD3 performance fee already zero; skipping");
            return;
        }

        addToBatch(SUSD3, abi.encodeCall(ITokenizedStrategyKeeper.setPerformanceFee, (0)));
        console2.log("Added sUSD3 setPerformanceFee call");
    }

    function _countUpdates(TokenKeeperStatus[2] memory statuses, WiringStatus memory wiring)
        private
        pure
        returns (uint256 updates)
    {
        for (uint256 i = 0; i < statuses.length; i++) {
            if (statuses[i].needsUpdate) updates++;
        }
        if (wiring.performanceFeeRecipientNeedsUpdate) updates++;
        if (wiring.susd3PerformanceFeeNeedsUpdate) updates++;
    }

    function _logStatuses(
        string memory label,
        TokenKeeperStatus[2] memory statuses,
        WiringStatus memory wiring,
        address relayer
    ) private view {
        console2.log("===", label, "===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        console2.log("Target keeper:", relayer);
        console2.log("");

        for (uint256 i = 0; i < statuses.length; i++) {
            console2.log(statuses[i].label);
            console2.log("  token:", statuses[i].token);
            console2.log("  management:", statuses[i].management);
            console2.log("  current keeper:", statuses[i].currentKeeper);
            console2.log("  target keeper:", relayer);
            console2.log("  needs update:", statuses[i].needsUpdate);
        }

        console2.log("USD3 report wiring");
        console2.log("  current performance fee recipient:", wiring.currentPerformanceFeeRecipient);
        console2.log("  target performance fee recipient:", SUSD3);
        console2.log("  needs update:", wiring.performanceFeeRecipientNeedsUpdate);
        console2.log("sUSD3 report wiring");
        console2.log("  current performance fee:", wiring.currentSusd3PerformanceFee);
        console2.log("  target performance fee:", uint256(0));
        console2.log("  needs update:", wiring.susd3PerformanceFeeNeedsUpdate);
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
