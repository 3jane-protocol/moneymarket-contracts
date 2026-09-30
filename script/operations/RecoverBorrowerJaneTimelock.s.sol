// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarkdownController} from "../../src/MarkdownController.sol";
import {Id, IMorpho, Position} from "../../src/interfaces/IMorpho.sol";
import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {Jane} from "../../src/jane/Jane.sol";
import {RewardsDistributor} from "../../src/jane/RewardsDistributor.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";

/// @title RecoverBorrowerJaneTimelock
/// @notice Recovers a settled borrower's JANE through the 24-hour parameters timelock. One timelock batch temporarily
///         makes the timelock the markdown controller, redistributes the requested JANE to RewardsDistributor,
///         restores the production controller, sweeps the JANE, forwards it to the recipient when needed, and removes
///         the timelock's temporary transfer role.
/// @dev The operation never enables general transfers. Before scheduling, make live an allocation-freezing root that
///      fixes the borrower's cumulative allocation at their claimed amount, and keep that allocation frozen in every
///      later root. With markdown disabled for the borrower and RewardsDistributor checked as JANE's sole minter,
///      reward claims are the only way the borrower's balance can change during the 24-hour delay; the live root
///      removes that path and keeps the scheduled full-balance amount equal to the borrower's balance at execution.
///      The script checks only that the borrower has no debt and no credit line on the market. That state also holds
///      for accounts that were never settled, so before scheduling the operator must confirm the borrower's
///      AccountSettled event from MorphoCredit, emitted via CreditLine.settle. The borrower address is the one input
///      the script cannot validate.
///
///      While this operation is pending, no other timelock operation that changes JANE's markdown controller or moves
///      JANE into RewardsDistributor may execute. This batch restores the hard-coded controller and sweeps the
///      distributor's full JANE balance.
///
///      Usage:
///      1. Make the allocation-freezing root live, then run
///         --sig "schedule(address,uint256,address,uint256,bool)" <borrower> 0 <recipient> 0 false
///         to schedule the borrower's full live balance. A nonzero amount schedules that explicit amount instead.
///         Repeat with `true` to propose the Safe transaction. The amount printed by the `send=true` run is
///         authoritative for execute because the zero sentinel is resolved from the live balance on every run.
///      2. After 24 hours, confirm the borrower balance is unchanged and run
///         --sig "execute(address,uint256,address,uint256,bool)" <borrower> <printedAmount> <recipient> 0 false
///         (then repeat with `true` to propose the Safe transaction). Execute never accepts the zero sentinel.
///      3. Record the recipient balance immediately before the Safe executes the proposal. After Safe execution, run
///         --sig "verify(address,uint256,address,uint256,uint256)" <borrower> <printedAmount> <recipient> 0
///         <recipientBalanceBefore>.
///      Use FOUNDRY_PROFILE=script, WALLET_TYPE and the Safe proposer credential, and a mainnet RPC. SAFE_ADDRESS may
///      override the default proposer Safe. Use a fresh attempt nonce to intentionally schedule the same recovery
///      parameters again.
contract RecoverBorrowerJaneTimelock is Script, SafeHelper, TimelockHelper {
    address internal constant JANE = 0x333333330522F64EE8d0b3039c460b41670e3404;
    address internal constant REWARDS_DISTRIBUTOR = 0xaC6985D4dBcd89CCAD71DB9bf0309eaF57F064e8;
    address internal constant ORIGINAL_CONTROLLER = 0xF0eaE71092F3c9411A9EAb8F81E7d91D29726214;
    address internal constant PARAMS_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address internal constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address internal constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;

    uint256 internal constant PARAMS_TIMELOCK_DELAY = 1 days;
    bytes32 internal constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");
    bytes32 internal constant SALT_DOMAIN = bytes32("3JANE_JANE_BORROWER_RECOVERY_V1");
    Id internal constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    function schedule(address borrower, uint256 amount, address recipient, uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        bool fullBalanceSentinel = amount == 0;
        amount = _resolveScheduleAmount(borrower, amount);
        (uint256 borrowerBalanceBefore, uint256 recipientBalanceBefore) =
            _requirePreconditions(borrower, amount, recipient, safe);

        console2.log("=== Schedule Settled-Borrower JANE Recovery ===");
        _logScheduledAmount(borrower, amount, recipient, attempt, fullBalanceSentinel);
        _logHeader(borrower, amount, recipient, borrowerBalanceBefore, recipientBalanceBefore, attempt, send);

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(borrower, amount, recipient, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Operation salt:", vm.toString(salt));

        ITimelockController.OperationState state = getOperationState(PARAMS_TIMELOCK, operationId);
        if (state == ITimelockController.OperationState.Waiting || state == ITimelockController.OperationState.Ready) {
            logOperationState(PARAMS_TIMELOCK, operationId);
            console2.log("Operation is already pending");
            return;
        }
        require(state != ITimelockController.OperationState.Done, "operation already executed; use a fresh attempt");

        _simulateCalls(
            targets, values, datas, borrower, amount, recipient, borrowerBalanceBefore, recipientBalanceBefore
        );
        addToBatch(
            PARAMS_TIMELOCK, encodeScheduleBatch(targets, values, datas, bytes32(0), salt, PARAMS_TIMELOCK_DELAY)
        );
        _requireSingleCall();
        _send(send);
        console2.log("Next: after 24 hours, execute with the exact printed amount and the same other parameters");
    }

    function execute(address borrower, uint256 amount, address recipient, uint256 attempt, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(PARAMS_TIMELOCK)
    {
        require(
            amount != 0,
            "execute requires the explicit amount printed by schedule; the amount is part of the operation ID"
        );
        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        (uint256 borrowerBalanceBefore, uint256 recipientBalanceBefore) =
            _requirePreconditions(borrower, amount, recipient, safe);

        console2.log("=== Execute Settled-Borrower JANE Recovery ===");
        _logHeader(borrower, amount, recipient, borrowerBalanceBefore, recipientBalanceBefore, attempt, send);

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(borrower, amount, recipient, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Operation salt:", vm.toString(salt));
        logOperationState(PARAMS_TIMELOCK, operationId);
        require(!isOperationDone(PARAMS_TIMELOCK, operationId), "operation already executed");
        requireOperationReady(PARAMS_TIMELOCK, operationId);

        bytes memory executeCalldata = encodeExecuteBatch(targets, values, datas, bytes32(0), salt);
        addToBatch(PARAMS_TIMELOCK, executeCalldata);
        _requirePostState(borrower, amount, recipient, borrowerBalanceBefore, recipientBalanceBefore);
        _requireSingleCall();
        _send(send);
    }

    /// @notice Checks the executed operation, exact recipient balance change, and durable recovery invariants.
    /// @param borrower The borrower whose JANE was recovered.
    /// @param amount The explicit amount printed by the authoritative `send=true` schedule run.
    /// @param recipient The recipient selected in the executed operation.
    /// @param attempt The attempt nonce used to schedule and execute the operation.
    /// @param recipientBalanceBefore The recipient's JANE balance recorded immediately before Safe execution.
    function verify(
        address borrower,
        uint256 amount,
        address recipient,
        uint256 attempt,
        uint256 recipientBalanceBefore
    ) external view {
        require(borrower != address(0), "borrower is zero");
        require(recipient != address(0), "recipient is zero");
        require(borrower != recipient, "recipient cannot be borrower");
        require(recipient != REWARDS_DISTRIBUTOR, "recipient cannot be distributor");
        require(amount != 0, "amount is zero");
        _requireCoreTopology();

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _operation(borrower, amount, recipient, attempt);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, bytes32(0), salt);
        require(
            getOperationState(PARAMS_TIMELOCK, operationId) == ITimelockController.OperationState.Done,
            "batch operation is not done"
        );

        Jane jane = Jane(JANE);
        uint256 borrowerBalance = jane.balanceOf(borrower);
        uint256 recipientBalance = jane.balanceOf(recipient);
        require(recipientBalance == recipientBalanceBefore + amount, "recipient balance increase mismatch");
        _requireDurableState(jane);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Operation salt:", vm.toString(salt));
        console2.log("Borrower:", borrower);
        console2.log("Borrower live JANE balance:", borrowerBalance);
        console2.log("Recipient:", recipient);
        console2.log("Recipient balance before:", recipientBalanceBefore);
        console2.log("Recipient balance after:", recipientBalance);
        console2.log("Recipient balance increase:", recipientBalance - recipientBalanceBefore);
        console2.log("PASS: controller restored, distributor empty, and TRANSFER_ROLE empty");
    }

    function _requirePreconditions(address borrower, uint256 amount, address recipient, address safe)
        internal
        view
        returns (uint256 borrowerBalance, uint256 recipientBalance)
    {
        require(borrower != address(0), "borrower is zero");
        require(recipient != address(0), "recipient is zero");
        require(borrower != recipient, "recipient cannot be borrower");
        require(recipient != REWARDS_DISTRIBUTOR, "recipient cannot be distributor");
        require(amount > 0, "amount is zero");
        _requireTopology(safe);

        Jane jane = Jane(JANE);
        require(!jane.transferable(), "JANE transfers are enabled");
        require(jane.markdownController() == ORIGINAL_CONTROLLER, "unexpected markdown controller");
        require(!MarkdownController(ORIGINAL_CONTROLLER).markdownEnabled(borrower), "borrower markdown is enabled");
        bytes32 minterRole = jane.MINTER_ROLE();
        require(
            jane.getRoleMemberCount(minterRole) == 1 && jane.getRoleMember(minterRole, 0) == REWARDS_DISTRIBUTOR,
            "RewardsDistributor is not the sole JANE minter"
        );
        require(jane.getRoleMemberCount(TRANSFER_ROLE) == 0, "TRANSFER_ROLE is not empty");
        require(jane.balanceOf(REWARDS_DISTRIBUTOR) == 0, "distributor JANE balance is not zero");

        Position memory position = IMorpho(MORPHO_CREDIT).position(MARKET_ID, borrower);
        require(
            position.borrowShares == 0 && position.collateral == 0, "borrower has outstanding debt or a credit line"
        );

        borrowerBalance = jane.balanceOf(borrower);
        recipientBalance = jane.balanceOf(recipient);
        require(amount <= borrowerBalance, "amount exceeds borrower JANE balance");

        console2.log("Live borrower JANE balance:", borrowerBalance);
        if (amount < borrowerBalance) {
            console2.log("!!! WARNING: PARTIAL JANE RECOVERY !!!");
            console2.log("Borrower JANE remaining after recovery:", borrowerBalance - amount);
            console2.log("!!! THE REMAINDER STAYS WITH THE BORROWER !!!");
        }
    }

    function _resolveScheduleAmount(address borrower, uint256 amount) internal view returns (uint256) {
        if (amount != 0) return amount;
        require(borrower != address(0), "borrower is zero");
        uint256 liveBalance = Jane(JANE).balanceOf(borrower);
        require(liveBalance != 0, "zero sentinel resolved to an empty borrower JANE balance");
        return liveBalance;
    }

    function _logScheduledAmount(
        address borrower,
        uint256 amount,
        address recipient,
        uint256 attempt,
        bool fullBalanceSentinel
    ) internal view {
        if (fullBalanceSentinel) console2.log("ZERO SENTINEL RESOLVED TO THE FULL LIVE JANE BALANCE");
        console2.log("============================================================");
        console2.log("EXECUTE MUST USE THIS EXACT AMOUNT:", amount);
        console2.log("The amount is part of the operation ID; execute cannot use zero.");
        console2.log("Ready-to-copy execute command arguments:");
        console2.log(
            string.concat(
                '--sig "execute(address,uint256,address,uint256,bool)" ',
                vm.toString(borrower),
                " ",
                vm.toString(amount),
                " ",
                vm.toString(recipient),
                " ",
                vm.toString(attempt),
                " false"
            )
        );
        console2.log("============================================================");
    }

    function _requireTopology(address safe) internal view {
        _requireCoreTopology();
        bytes32 proposerRole = ITimelockController(PARAMS_TIMELOCK).PROPOSER_ROLE();
        (bool ok, bytes memory data) =
            PARAMS_TIMELOCK.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", proposerRole, safe));
        require(ok && data.length == 32 && abi.decode(data, (bool)), "Safe is not a parameters timelock proposer");
    }

    function _requireCoreTopology() internal view {
        require(PARAMS_TIMELOCK.code.length > 0, "parameters timelock has no code");
        require(getMinDelay(PARAMS_TIMELOCK) == PARAMS_TIMELOCK_DELAY, "parameters timelock delay is not 24 hours");

        Jane jane = Jane(JANE);
        RewardsDistributor rewards = RewardsDistributor(REWARDS_DISTRIBUTOR);
        require(jane.owner() == PARAMS_TIMELOCK, "JANE owner is not the parameters timelock");
        require(rewards.owner() == PARAMS_TIMELOCK, "distributor owner is not the parameters timelock");
        require(jane.distributor() == REWARDS_DISTRIBUTOR, "unexpected JANE distributor");
        require(address(rewards.jane()) == JANE, "distributor has unexpected JANE token");
        require(rewards.useMint(), "distributor is not in mint mode");
        require(jane.TRANSFER_ROLE() == TRANSFER_ROLE, "unexpected JANE TRANSFER_ROLE");
    }

    function _operation(address borrower, uint256 amount, address recipient, uint256 attempt)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt)
    {
        bool forward = recipient != PARAMS_TIMELOCK;
        uint256 length = forward ? 7 : 6;
        Jane jane = Jane(JANE);
        targets = new address[](length);
        values = new uint256[](length);
        datas = new bytes[](length);

        uint256 i;
        targets[i] = JANE;
        datas[i++] = abi.encodeCall(Jane.setMarkdownController, (PARAMS_TIMELOCK));
        targets[i] = JANE;
        datas[i++] = abi.encodeCall(Jane.redistributeFromBorrower, (borrower, amount));
        targets[i] = JANE;
        datas[i++] = abi.encodeCall(Jane.setMarkdownController, (ORIGINAL_CONTROLLER));
        targets[i] = JANE;
        datas[i++] = abi.encodeCall(jane.grantRole, (TRANSFER_ROLE, PARAMS_TIMELOCK));
        targets[i] = REWARDS_DISTRIBUTOR;
        datas[i++] = abi.encodeCall(RewardsDistributor.sweep, (IERC20(JANE)));
        if (forward) {
            targets[i] = JANE;
            datas[i++] = abi.encodeCall(Jane.transfer, (recipient, amount));
        }
        targets[i] = JANE;
        datas[i] = abi.encodeCall(jane.revokeRole, (TRANSFER_ROLE, PARAMS_TIMELOCK));

        salt = keccak256(abi.encode(SALT_DOMAIN, borrower, amount, recipient, attempt));
    }

    function _simulateCalls(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory datas,
        address borrower,
        uint256 amount,
        address recipient,
        uint256 borrowerBalanceBefore,
        uint256 recipientBalanceBefore
    ) internal {
        uint256 snapshot = vm.snapshotState();
        simulateExecution(PARAMS_TIMELOCK, targets, values, datas);
        _requirePostState(borrower, amount, recipient, borrowerBalanceBefore, recipientBalanceBefore);
        vm.revertToState(snapshot);
    }

    function _requirePostState(
        address borrower,
        uint256 amount,
        address recipient,
        uint256 borrowerBalanceBefore,
        uint256 recipientBalanceBefore
    ) internal view {
        Jane jane = Jane(JANE);
        require(jane.balanceOf(borrower) == borrowerBalanceBefore - amount, "borrower balance decrease mismatch");
        require(jane.balanceOf(recipient) == recipientBalanceBefore + amount, "recipient balance increase mismatch");
        _requireDurableState(jane);
    }

    function _requireDurableState(Jane jane) internal view {
        require(!jane.transferable(), "JANE transfers were enabled");
        require(jane.markdownController() == ORIGINAL_CONTROLLER, "markdown controller was not restored");
        require(jane.balanceOf(REWARDS_DISTRIBUTOR) == 0, "distributor retains JANE");
        require(jane.getRoleMemberCount(TRANSFER_ROLE) == 0, "TRANSFER_ROLE is not empty");
        require(!jane.hasRole(TRANSFER_ROLE, PARAMS_TIMELOCK), "timelock retains TRANSFER_ROLE");
    }

    function _logHeader(
        address borrower,
        uint256 amount,
        address recipient,
        uint256 borrowerBalance,
        uint256 recipientBalance,
        uint256 attempt,
        bool send
    ) internal view {
        console2.log("JANE:", JANE);
        console2.log("RewardsDistributor:", REWARDS_DISTRIBUTOR);
        console2.log("Parameters timelock:", PARAMS_TIMELOCK);
        console2.log("Original markdown controller:", ORIGINAL_CONTROLLER);
        console2.log("Borrower:", borrower);
        console2.log("Borrower JANE balance:", borrowerBalance);
        console2.log("Recovery amount:", amount);
        console2.log("Recipient:", recipient);
        console2.log("Recipient JANE balance:", recipientBalance);
        console2.log("Attempt:", attempt);
        console2.log("Batch calls:", recipient == PARAMS_TIMELOCK ? 6 : 7);
        console2.log("Send to Safe:", send);
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
