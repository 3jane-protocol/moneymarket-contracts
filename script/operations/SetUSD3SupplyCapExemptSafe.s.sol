// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {
    ITransparentUpgradeableProxy,
    ProxyAdmin
} from "../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";

interface IUSD3SupplyCapRegistry {
    function setSupplyCapExempt(address account, bool exempt) external;
    function supplyCapExempt(address account) external view returns (bool);
    function ringFencedLiquidity() external view returns (uint256);
    function management() external view returns (address);
}

/// @title SetUSD3SupplyCapExemptSafe
/// @notice Toggles the USD3 supply-cap exemption for a list of accounts through the 24-hour parameters timelock:
///         one Safe-proposed operation batches `setSupplyCapExempt(account, exempt)` for every address in the list.
/// @dev The list file is newline-separated addresses; blank lines and lines starting with `#` are ignored, and the
///      file must live under `data/` (the script profile's read permission). The timelock records an operation
///      without validating its calldata, so the toggle may be scheduled before the USD3 v1.2 upgrade executes; the
///      schedule simulation then applies the pending implementation named by `USD3_IMPL` in a discarded snapshot to
///      prove the writes succeed. Execution requires the upgrade to be live.
///
///      Usage:
///      1. --sig "schedule(string,bool,uint256,bool)" data/usd3-supply-cap-exempt.txt true 0 false   (then true)
///      2. After 24 hours, --sig "execute(string,bool,uint256,bool)" data/usd3-supply-cap-exempt.txt true 0 false
///      3. --sig "verify(string,bool)" data/usd3-supply-cap-exempt.txt true
///      Pass `false` in place of `true` to remove the exemption. Use FOUNDRY_PROFILE=script, WALLET_TYPE and the
///      Safe proposer credential, and USD3_IMPL when scheduling ahead of the upgrade.
contract SetUSD3SupplyCapExemptSafe is Script, SafeHelper, TimelockHelper {
    address internal constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address internal constant USD3_PROXY_ADMIN = 0x41C838664a9C64905537fF410333B9f5964cC596;
    address internal constant UPGRADE_TIMELOCK = 0x3D3C41419Ab401cd25055E8f9421D7D96d887885;
    address internal constant PARAMS_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    uint256 internal constant PARAMS_TIMELOCK_DELAY = 1 days;
    bytes32 internal constant SALT_DOMAIN = bytes32("3JANE_USD3_SUPPLY_CAP_EXEMPT_V1");

    function schedule(string memory listPath, bool exempt, uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        address[] memory accounts = _readList(listPath);
        _requireTopology(safe);

        console2.log("=== Schedule USD3 Supply-Cap Exemption Toggle ===");
        _logHeader(listPath, accounts, exempt, send);

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(accounts, exempt, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        console2.log("Attempt:", attempt);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Operation salt:", vm.toString(salt));

        ITimelockController.OperationState state = getOperationState(PARAMS_TIMELOCK, operationId);
        if (state == ITimelockController.OperationState.Waiting || state == ITimelockController.OperationState.Ready) {
            logOperationState(PARAMS_TIMELOCK, operationId);
            console2.log("Operation is already pending");
            return;
        }
        require(state != ITimelockController.OperationState.Done, "operation already executed; use a fresh attempt");

        _simulate(targets, values, datas, accounts, exempt);
        addToBatch(
            PARAMS_TIMELOCK, encodeScheduleBatch(targets, values, datas, bytes32(0), salt, PARAMS_TIMELOCK_DELAY)
        );
        _requireSingleCall();
        _send(send);
        console2.log("Next: after the 24-hour delay, run execute with the same list, direction, and attempt nonce");
    }

    function execute(string memory listPath, bool exempt, uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        address[] memory accounts = _readList(listPath);
        _requireTopology(safe);
        require(_registryLive(), "USD3 v1.2 registry is not live");

        console2.log("=== Execute USD3 Supply-Cap Exemption Toggle ===");
        _logHeader(listPath, accounts, exempt, send);

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(accounts, exempt, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        console2.log("Operation ID:", vm.toString(operationId));
        logOperationState(PARAMS_TIMELOCK, operationId);
        require(!isOperationDone(PARAMS_TIMELOCK, operationId), "operation already executed");
        requireOperationReady(PARAMS_TIMELOCK, operationId);

        addToBatch(PARAMS_TIMELOCK, encodeExecuteBatch(targets, values, datas, bytes32(0), salt));
        _requireFlags(accounts, exempt);
        _requireSingleCall();
        _send(send);
    }

    /// @notice Print each account's live exemption and require every one to match the expected direction.
    function verify(string memory listPath, bool exempt) external view {
        address[] memory accounts = _readList(listPath);
        require(_registryLive(), "USD3 v1.2 registry is not live");
        IUSD3SupplyCapRegistry usd3 = IUSD3SupplyCapRegistry(USD3_PROXY);
        uint256 mismatches;
        for (uint256 i; i < accounts.length; ++i) {
            bool live = usd3.supplyCapExempt(accounts[i]);
            console2.log(live == exempt ? "PASS" : "FAIL", accounts[i], live);
            if (live != exempt) ++mismatches;
        }
        require(mismatches == 0, "exemption mismatch");
        console2.log("PASS: all accounts match, exempt =", exempt);
    }

    function _readList(string memory listPath) internal view returns (address[] memory accounts) {
        string[] memory lines = vm.split(vm.readFile(listPath), "\n");
        address[] memory parsed = new address[](lines.length);
        uint256 count;
        for (uint256 i; i < lines.length; ++i) {
            string memory line = vm.trim(lines[i]);
            if (bytes(line).length == 0 || bytes(line)[0] == "#") continue;
            address account = vm.parseAddress(line);
            require(account != address(0), "zero address in list");
            for (uint256 j; j < count; ++j) {
                require(parsed[j] != account, "duplicate address in list");
            }
            parsed[count++] = account;
        }
        require(count != 0, "list is empty");
        accounts = new address[](count);
        for (uint256 i; i < count; ++i) {
            accounts[i] = parsed[i];
        }
    }

    function _requireTopology(address safe) internal view {
        require(PARAMS_TIMELOCK.code.length > 0, "parameters timelock has no code");
        require(getMinDelay(PARAMS_TIMELOCK) == PARAMS_TIMELOCK_DELAY, "parameters timelock delay is not 24 hours");
        require(
            IUSD3SupplyCapRegistry(USD3_PROXY).management() == PARAMS_TIMELOCK,
            "USD3 management is not the parameters timelock"
        );
        bytes32 proposerRole = ITimelockController(PARAMS_TIMELOCK).PROPOSER_ROLE();
        (bool ok, bytes memory data) =
            PARAMS_TIMELOCK.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", proposerRole, safe));
        require(ok && data.length == 32 && abi.decode(data, (bool)), "Safe is not a parameters timelock proposer");
    }

    function _operation(address[] memory accounts, bool exempt, uint256 attempt)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt)
    {
        targets = new address[](accounts.length);
        values = new uint256[](accounts.length);
        datas = new bytes[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            targets[i] = USD3_PROXY;
            datas[i] = abi.encodeCall(IUSD3SupplyCapRegistry.setSupplyCapExempt, (accounts[i], exempt));
        }
        salt = keccak256(abi.encode(SALT_DOMAIN, keccak256(abi.encode(accounts)), exempt, attempt));
    }

    /// @dev Proves every write succeeds at execution. Before the v1.2 upgrade executes, the live proxy lacks the
    ///      registry selectors, so the pending implementation is applied first; every effect is discarded.
    function _simulate(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory datas,
        address[] memory accounts,
        bool exempt
    ) internal {
        uint256 snapshot = vm.snapshotState();
        if (!_registryLive()) {
            address pendingImpl = vm.envAddress("USD3_IMPL");
            require(pendingImpl.code.length > 0, "USD3_IMPL has no code");
            console2.log("USD3 v1.2 registry not live; simulating against pending implementation", pendingImpl);
            vm.prank(UPGRADE_TIMELOCK);
            ProxyAdmin(USD3_PROXY_ADMIN).upgradeAndCall(ITransparentUpgradeableProxy(USD3_PROXY), pendingImpl, "");
            require(_registryLive(), "pending USD3 implementation lacks the v1.2 registry");
        }
        simulateExecution(PARAMS_TIMELOCK, targets, values, datas);
        _requireFlags(accounts, exempt);
        vm.revertToState(snapshot);
    }

    function _requireFlags(address[] memory accounts, bool exempt) internal view {
        IUSD3SupplyCapRegistry usd3 = IUSD3SupplyCapRegistry(USD3_PROXY);
        for (uint256 i; i < accounts.length; ++i) {
            require(usd3.supplyCapExempt(accounts[i]) == exempt, "simulated exemption mismatch");
        }
    }

    function _registryLive() internal view returns (bool) {
        (bool ok, bytes memory data) =
            USD3_PROXY.staticcall(abi.encodeCall(IUSD3SupplyCapRegistry.ringFencedLiquidity, ()));
        return ok && data.length == 32;
    }

    function _logHeader(string memory listPath, address[] memory accounts, bool exempt, bool send) internal view {
        console2.log("List file:", listPath);
        console2.log("Accounts:", accounts.length);
        console2.log("Exempt:", exempt);
        console2.log("USD3 proxy:", USD3_PROXY);
        console2.log("Parameters timelock / USD3 management:", PARAMS_TIMELOCK);
        console2.log("Send to Safe:", send);
        for (uint256 i; i < accounts.length; ++i) {
            console2.log("  ", accounts[i], accounts[i].code.length > 0 ? "(contract)" : "(EOA)");
        }
    }

    function _requireSingleCall() internal view {
        require(getTotalBatches() == 1, "SafeHelper split the batch");
        (uint256 txCount,) = getBatchInfo(0);
        require(txCount == 1, "operation must be one Safe call");
    }

    function _send(bool send) internal {
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }
}
