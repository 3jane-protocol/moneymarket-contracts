// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Ownable} from "../lib/openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "../lib/openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IHelper} from "./interfaces/IHelper.sol";
import {Id, IMorpho, IMorphoCredit, Market, MarketParams, Position} from "./interfaces/IMorpho.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";

/// @title RevolvingCreditFacilityHolding
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Non-upgradeable borrower reserve that parks committed capital in an external ERC4626 yield vault.
/// @dev The reserve borrows USDC through Helper from a single Morpho market, deposits the USDC into the configured
/// ERC4626 vault, and releases funds only through admin action or a proposer-scheduled fallback repayment. The
/// proposer is the only fallback initiator and may schedule only after 180 days without admin activity; the admin may
/// veto during a 7-day window, and execution after that window is permissionless. After a veto, the proposer may
/// reschedule while the 180-day idle gate remains open; the admin can keep vetoing or rotate the proposer.
/// `emergencyRepay` bypasses Helper for repayment if the bound Helper is unavailable or unsafe.
contract RevolvingCreditFacilityHolding is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    /// @notice Pending proposer-initiated protocol repayment awaiting the veto window to elapse.
    /// @dev `eta == 0` indicates no scheduled repayment is pending.
    struct ScheduledRepayment {
        uint256 amount;
        uint256 eta;
    }

    /// @notice Veto window between scheduling and executing a proposer-initiated fallback repayment.
    uint256 public constant PROPOSER_DELAY = 7 days;

    /// @notice Idle window after which the proposer may schedule a fallback protocol repayment.
    uint256 public constant FALLBACK_DELAY = 180 days;

    /// @notice Helper contract used to borrow from and repay the Morpho credit market.
    IHelper public immutable helper;

    /// @notice Morpho protocol contract that holds this reserve's borrow position.
    IMorpho public immutable morpho;

    /// @notice USDC token used for borrowing, vault deposits, and off-ramp transfers.
    IERC20 public immutable usdc;

    /// @notice ERC4626 loan token wrapper used by the bound Morpho credit market.
    IERC4626 public immutable loanTokenVault;

    /// @notice ERC4626 yield vault that holds drawn USDC between draws and repayments.
    IERC4626 public immutable vault;

    /// @notice Identifier of the Morpho market that this reserve borrows from.
    Id public immutable marketId;

    MarketParams internal _marketParams;

    /// @notice Address authorized to schedule fallback protocol repayments after the idle window.
    address public proposer;

    /// @notice Fixed recipient of off-ramp releases; only the admin can change this address.
    address public offRampRecipient;

    /// @notice Timestamp of the last admin-gated call; used as the heartbeat for proposer fallback scheduling.
    uint256 public lastAdminTouch;

    /// @notice Currently pending proposer-scheduled fallback repayment, if any.
    ScheduledRepayment public scheduledRepayment;

    /// @notice Emitted when the admin draws from the credit line and deposits the proceeds into the vault.
    event DrawnAndInvested(uint256 requestedAmount, uint256 usdcReceived, uint256 vaultShares);

    /// @notice Emitted when idle USDC already held by the contract is invested into the vault.
    event IdleInvested(uint256 assets, uint256 vaultShares);

    /// @notice Emitted whenever protocol debt is repaid, regardless of which path triggered it.
    event ProtocolRepayment(uint256 assets, uint256 sharesRepaid, address indexed executor);

    /// @notice Emitted when vault liquidity is released to the fixed off-ramp recipient.
    event OffRampRelease(address indexed recipient, uint256 assets, uint256 vaultShares);

    /// @notice Emitted when the proposer schedules (or overwrites) a pending fallback repayment.
    event ProtocolRepaymentScheduled(uint256 amount, uint256 eta);

    /// @notice Emitted when the admin vetoes the pending scheduled fallback repayment.
    event ProtocolRepaymentVetoed();

    /// @notice Emitted when a scheduled fallback repayment is executed after its veto window elapses.
    event ScheduledProtocolRepaymentExecuted(uint256 amount, address indexed executor);

    /// @notice Emitted when the proposer address is rotated by the admin.
    event ProposerUpdated(address indexed oldProposer, address indexed newProposer);

    /// @notice Emitted when the off-ramp recipient is rotated by the admin.
    event OffRampRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Emitted when the admin explicitly refreshes the heartbeat via `adminPing`.
    event AdminPing(uint256 timestamp);

    /// @notice Emitted when unrelated ERC20s are recovered via `rescueToken`.
    event RescueToken(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Thrown when the proposer schedules before the 180-day idle window has elapsed.
    error FallbackNotReady();

    /// @notice Thrown when veto/execute is called and no repayment is currently scheduled.
    error InvalidOperation();

    /// @notice Thrown when `executeScheduledRepayment` is called before the veto window elapses.
    error OperationNotReady();

    /// @notice Thrown when a partial repayment amount exceeds the current outstanding debt.
    error RepayAmountExceedsDebt();

    /// @notice Thrown when `rescueToken` is called with USDC, the market loan token, or the vault token.
    error ProtectedToken();

    /// @notice Thrown when attempting to renounce ownership.
    error RenounceOwnershipDisabled();

    /// @notice Runs the owner check and refreshes the admin heartbeat for the 180-day fallback schedule timer.
    modifier onlyAdminTouch() {
        _checkOwner();
        lastAdminTouch = block.timestamp;
        _;
    }

    /// @notice Deploys a borrower reserve bound to a single Morpho market and a single ERC4626 vault.
    /// @param admin Initial owner; gates all admin actions and is required to keep the heartbeat alive.
    /// @param initialProposer Address allowed to schedule fallback protocol repayments after the idle window.
    /// @param initialOffRampRecipient Fixed recipient of off-ramp releases.
    /// @param helper_ Helper contract used for borrow and repay routing.
    /// @param vault_ ERC4626 vault whose asset must equal Helper's configured USDC token.
    /// @param marketParams_ Market this reserve borrows from; `marketId` is derived once at construction.
    constructor(
        address admin,
        address initialProposer,
        address initialOffRampRecipient,
        address helper_,
        address vault_,
        MarketParams memory marketParams_
    ) Ownable(admin) {
        if (
            admin == address(0) || initialProposer == address(0) || initialOffRampRecipient == address(0)
                || helper_ == address(0) || vault_ == address(0) || marketParams_.loanToken == address(0)
        ) {
            revert ErrorsLib.ZeroAddress();
        }

        helper = IHelper(helper_);
        address morpho_ = IHelper(helper_).MORPHO();
        morpho = IMorpho(morpho_);
        loanTokenVault = IERC4626(marketParams_.loanToken);
        vault = IERC4626(vault_);
        usdc = IERC20(IERC4626(vault_).asset());

        if (address(usdc) != IHelper(helper_).USDC()) revert ErrorsLib.InconsistentInput();
        if (loanTokenVault.asset() != address(usdc)) revert ErrorsLib.InconsistentInput();

        _marketParams = marketParams_;
        marketId = marketParams_.id();
        proposer = initialProposer;
        offRampRecipient = initialOffRampRecipient;
        lastAdminTouch = block.timestamp;

        usdc.forceApprove(helper_, type(uint256).max);
        usdc.forceApprove(marketParams_.loanToken, type(uint256).max);
        usdc.forceApprove(vault_, type(uint256).max);
        IERC20(marketParams_.loanToken).forceApprove(morpho_, type(uint256).max);
    }

    /// @notice Returns the full market parameters bound at construction time.
    /// @return The `MarketParams` struct used for every borrow and repay call.
    function marketParams() external view returns (MarketParams memory) {
        return _marketParams;
    }

    /// @notice Refreshes the admin heartbeat used by the 180-day proposer fallback schedule gate.
    function adminPing() external onlyAdminTouch {
        emit AdminPing(block.timestamp);
    }

    /// @notice Transfers ownership and refreshes the admin heartbeat.
    /// @param newOwner New admin address.
    function transferOwnership(address newOwner) public override onlyAdminTouch {
        super.transferOwnership(newOwner);
    }

    /// @notice Ownership renouncement is disabled so an admin remains available for veto and recovery actions.
    function renounceOwnership() public override onlyAdminTouch {
        revert RenounceOwnershipDisabled();
    }

    /// @notice Draws committed capital through Helper and deposits the received USDC into the vault.
    /// @param amount Amount of credit-market loan tokens to borrow.
    /// @return usdcReceived USDC delivered by Helper and deposited into the vault.
    function drawAndInvest(uint256 amount) external onlyAdminTouch nonReentrant returns (uint256 usdcReceived) {
        if (amount == 0) revert ErrorsLib.ZeroAssets();

        (usdcReceived,) = helper.borrow(_marketParams, amount);
        uint256 vaultShares = vault.deposit(usdcReceived, address(this));
        if (vaultShares == 0) revert ErrorsLib.ZeroAssets();

        emit DrawnAndInvested(amount, usdcReceived, vaultShares);
    }

    /// @notice Invests idle USDC already held by this contract into the vault.
    /// @param amount USDC to deposit into the vault.
    /// @return vaultShares Vault shares minted to this contract.
    function investIdle(uint256 amount) external onlyAdminTouch nonReentrant returns (uint256 vaultShares) {
        if (amount == 0) revert ErrorsLib.ZeroAssets();

        vaultShares = vault.deposit(amount, address(this));
        if (vaultShares == 0) revert ErrorsLib.ZeroAssets();
        emit IdleInvested(amount, vaultShares);
    }

    /// @notice Immediately releases vault liquidity to repay this reserve's protocol debt.
    /// @param amount USDC amount to repay, or `type(uint256).max` to repay the full outstanding debt.
    /// @return assetsRepaid USDC assets consumed by the repayment.
    /// @return sharesRepaid Borrow shares retired in the credit market.
    function releaseToProtocol(uint256 amount)
        external
        onlyAdminTouch
        nonReentrant
        returns (uint256 assetsRepaid, uint256 sharesRepaid)
    {
        return _releaseToProtocol(amount);
    }

    /// @notice Repays protocol debt directly through Morpho, bypassing the bound Helper.
    /// @dev Intended as an admin recovery path if Helper is unavailable or unsafe. `amount == type(uint256).max`
    /// repays all current borrow shares to avoid dust.
    /// @param amount USDC amount to repay, or `type(uint256).max` for full repayment.
    /// @return assetsRepaid USDC assets withdrawn from the vault for the repayment.
    /// @return sharesRepaid Borrow shares retired in the credit market.
    function emergencyRepay(uint256 amount)
        external
        onlyAdminTouch
        nonReentrant
        returns (uint256 assetsRepaid, uint256 sharesRepaid)
    {
        return _emergencyRepay(amount);
    }

    /// @notice Immediately releases vault liquidity to the fixed off-ramp recipient.
    /// @param amount USDC amount to withdraw from the vault and transfer to the off-ramp recipient.
    /// @return vaultShares Vault shares burned to obtain the USDC.
    function releaseToOfframp(uint256 amount) external onlyAdminTouch nonReentrant returns (uint256 vaultShares) {
        if (amount == 0) revert ErrorsLib.ZeroAssets();

        vaultShares = vault.withdraw(amount, address(this), address(this));
        usdc.safeTransfer(offRampRecipient, amount);

        emit OffRampRelease(offRampRecipient, amount, vaultShares);
    }

    /// @notice Schedules or overwrites the pending proposer-initiated fallback repayment.
    /// @dev Restricted to the configured proposer and available only after 180 days without admin activity.
    /// @param amount USDC amount the proposer wants to repay once the veto window elapses.
    function scheduleProtocolRepayment(uint256 amount) external {
        if (msg.sender != proposer) revert ErrorsLib.Unauthorized();
        if (amount == 0) revert ErrorsLib.ZeroAssets();
        if (block.timestamp < lastAdminTouch + FALLBACK_DELAY) revert FallbackNotReady();

        uint256 eta = block.timestamp + PROPOSER_DELAY;
        scheduledRepayment = ScheduledRepayment({amount: amount, eta: eta});

        emit ProtocolRepaymentScheduled(amount, eta);
    }

    /// @notice Vetoes the pending proposer-initiated fallback repayment.
    /// @dev Reverts if no repayment is currently scheduled.
    function vetoScheduledRepayment() external onlyAdminTouch {
        if (scheduledRepayment.eta == 0) revert InvalidOperation();

        delete scheduledRepayment;
        emit ProtocolRepaymentVetoed();
    }

    /// @notice Executes the pending proposer-initiated fallback repayment once the 7-day veto window has elapsed.
    /// @return assetsRepaid USDC assets consumed by the repayment.
    /// @return sharesRepaid Borrow shares retired in the credit market.
    function executeScheduledRepayment() external nonReentrant returns (uint256 assetsRepaid, uint256 sharesRepaid) {
        ScheduledRepayment memory operation = scheduledRepayment;
        if (operation.eta == 0) revert InvalidOperation();
        if (block.timestamp < operation.eta) revert OperationNotReady();

        uint256 amount = operation.amount;
        delete scheduledRepayment;
        (assetsRepaid, sharesRepaid) = _releaseToProtocol(amount);

        emit ScheduledProtocolRepaymentExecuted(amount, msg.sender);
    }

    /// @notice Rotates the proposer address.
    /// @param newProposer New proposer; must be non-zero and different from the current value.
    function setProposer(address newProposer) external onlyAdminTouch {
        if (newProposer == address(0)) revert ErrorsLib.ZeroAddress();
        if (newProposer == proposer) revert ErrorsLib.AlreadySet();

        emit ProposerUpdated(proposer, newProposer);
        proposer = newProposer;
    }

    /// @notice Rotates the off-ramp recipient address.
    /// @param newOffRampRecipient New off-ramp recipient; must be non-zero and different from the current value.
    function setOffRampRecipient(address newOffRampRecipient) external onlyAdminTouch {
        if (newOffRampRecipient == address(0)) revert ErrorsLib.ZeroAddress();
        if (newOffRampRecipient == offRampRecipient) revert ErrorsLib.AlreadySet();

        emit OffRampRecipientUpdated(offRampRecipient, newOffRampRecipient);
        offRampRecipient = newOffRampRecipient;
    }

    /// @notice Recovers unrelated tokens accidentally sent to the reserve.
    /// @dev USDC, the market loan token, and the vault share token are protected and cannot be rescued.
    /// @param token ERC20 token to recover.
    /// @param recipient Address that receives the recovered tokens.
    /// @param amount Amount of `token` to transfer.
    function rescueToken(address token, address recipient, uint256 amount) external onlyAdminTouch {
        if (token == address(usdc) || token == address(loanTokenVault) || token == address(vault)) {
            revert ProtectedToken();
        }
        if (recipient == address(0)) revert ErrorsLib.ZeroAddress();
        if (amount == 0) revert ErrorsLib.ZeroAssets();

        IERC20(token).safeTransfer(recipient, amount);
        emit RescueToken(token, recipient, amount);
    }

    /// @notice Returns this reserve's outstanding protocol debt denominated in USDC.
    /// @dev Reads the live position and market state without accruing premium; for in-tx accuracy callers should
    /// trigger premium accrual first.
    /// @return USDC amount that would fully repay the position at current accrued state.
    function outstandingDebtAssets() public view returns (uint256) {
        (,, uint256 usdcAssets) = _currentDebt();
        return usdcAssets;
    }

    /// @dev Shared repayment routine. `amount == type(uint256).max` routes through Helper's share-based full-repay
    /// path to avoid dust; any other value performs an assets-based partial repay bounded by current debt.
    function _releaseToProtocol(uint256 amount) internal returns (uint256 assetsRepaid, uint256 sharesRepaid) {
        if (amount == 0) revert ErrorsLib.ZeroAssets();

        _accrueReserveDebt();

        (,, uint256 fullDebt) = _currentDebt();
        uint256 usdcToWithdraw;
        if (amount == type(uint256).max) {
            if (fullDebt == 0) revert ErrorsLib.ZeroAssets();
            usdcToWithdraw = fullDebt;
        } else {
            if (amount > fullDebt) revert RepayAmountExceedsDebt();
            usdcToWithdraw = amount;
        }

        vault.withdraw(usdcToWithdraw, address(this), address(this));
        (assetsRepaid, sharesRepaid) = helper.repay(_marketParams, amount, address(this), "");

        emit ProtocolRepayment(assetsRepaid, sharesRepaid, msg.sender);
    }

    function _emergencyRepay(uint256 amount) internal returns (uint256 assetsRepaid, uint256 sharesRepaid) {
        if (amount == 0) revert ErrorsLib.ZeroAssets();

        _accrueReserveDebt();

        if (amount == type(uint256).max) {
            (uint256 borrowShares, uint256 loanTokenAssets, uint256 usdcAssets) = _currentDebt();
            if (borrowShares == 0 || usdcAssets == 0) revert ErrorsLib.ZeroAssets();

            assetsRepaid = usdcAssets;
            vault.withdraw(assetsRepaid, address(this), address(this));
            loanTokenVault.mint(loanTokenAssets, address(this));
            (, sharesRepaid) = morpho.repay(_marketParams, 0, borrowShares, address(this), "");

            emit ProtocolRepayment(assetsRepaid, sharesRepaid, msg.sender);
            return (assetsRepaid, sharesRepaid);
        }

        (,, uint256 fullDebt) = _currentDebt();
        if (amount > fullDebt) revert RepayAmountExceedsDebt();
        assetsRepaid = amount;

        vault.withdraw(assetsRepaid, address(this), address(this));
        uint256 mintedLoanTokens = loanTokenVault.deposit(assetsRepaid, address(this));
        if (mintedLoanTokens == 0) revert ErrorsLib.ZeroAssets();
        (, sharesRepaid) = morpho.repay(_marketParams, mintedLoanTokens, 0, address(this), "");

        emit ProtocolRepayment(assetsRepaid, sharesRepaid, msg.sender);
    }

    function _currentDebt() internal view returns (uint256 borrowShares, uint256 loanTokenAssets, uint256 usdcAssets) {
        Position memory reservePosition = morpho.position(marketId, address(this));
        borrowShares = uint256(reservePosition.borrowShares);
        if (borrowShares == 0) return (0, 0, 0);

        Market memory targetMarket = morpho.market(marketId);
        loanTokenAssets = borrowShares.toAssetsUp(targetMarket.totalBorrowAssets, targetMarket.totalBorrowShares);
        usdcAssets = loanTokenVault.previewMint(loanTokenAssets);
    }

    /// @dev Forces premium accrual against this reserve's borrow position so the subsequent debt read is accurate.
    function _accrueReserveDebt() internal {
        address[] memory borrowers = new address[](1);
        borrowers[0] = address(this);
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(marketId, borrowers);
    }
}
