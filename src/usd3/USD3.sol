// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.22;

import {BaseHooksUpgradeable} from "./base/BaseHooksUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, IMorphoCredit, MarketParams, Id} from "../interfaces/IMorpho.sol";
import {MorphoLib} from "../libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {IERC4626} from "../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {Pausable} from "../../lib/openzeppelin/contracts/utils/Pausable.sol";
import {TokenizedStrategyStorageLib} from "@periphery/libraries/TokenizedStrategyStorageLib.sol";
import {IProtocolConfig} from "../interfaces/IProtocolConfig.sol";
import {ProtocolConfigLib} from "../libraries/ProtocolConfigLib.sol";

interface IAavePool {
    function getVirtualUnderlyingBalance(address asset) external view returns (uint128);
}

interface IWaUSDC is IERC4626 {
    function POOL() external view returns (IAavePool);
}

/**
 * @title USD3
 * @author 3Jane Protocol
 * @notice Senior tranche strategy for USDC-based lending on 3Jane's credit markets
 * @dev Implements Yearn V3 tokenized strategy pattern for unsecured lending via MorphoCredit.
 * Deploys USDC capital to 3Jane's modified Morpho Blue markets that use credit-based
 * underwriting instead of collateral. Features first-loss protection through sUSD3
 * subordinate tranche absorption.
 *
 * Key features:
 * - Senior tranche with first-loss protection from sUSD3 holders
 * - Configurable deployment ratio to credit markets (maxOnCredit)
 * - Automatic yield distribution to sUSD3 via performance fees
 * - Loss absorption through direct share burning of sUSD3 holdings
 * - Supply-cap exemptions for protocol-controlled deposit receivers
 * - Dynamic fee adjustment via ProtocolConfig integration
 *
 * Yield Distribution Mechanism:
 * - Tranche share distributed to sUSD3 holders via TokenizedStrategy's performance fee
 * - Performance fee can be set from 0-100% through syncTrancheShare()
 * - Direct storage manipulation bypasses TokenizedStrategy's 50% fee limit
 * - Keeper-controlled updates ensure protocol-wide consistency
 *
 * Loss Absorption Mechanism:
 * - When losses occur, sUSD3 shares are burned first (subordination)
 * - Direct storage manipulation used to burn shares without asset transfers
 * - USD3 holders protected up to total sUSD3 holdings
 * - Losses exceeding sUSD3 balance shared proportionally among USD3 holders
 */
contract USD3 is BaseHooksUpgradeable {
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                        CONSTANTS
    //////////////////////////////////////////////////////////////*/
    IWaUSDC public constant WAUSDC = IWaUSDC(0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E);

    /*//////////////////////////////////////////////////////////////
                        STORAGE - MORPHO PARAMETERS
    //////////////////////////////////////////////////////////////*/
    /// @notice MorphoCredit contract for lending operations
    IMorpho public morphoCredit;

    /// @notice Market ID for the lending market this strategy uses
    Id public marketId;

    /// @notice Market parameters for the lending market
    MarketParams internal _marketParams;

    /*//////////////////////////////////////////////////////////////
                        UPGRADEABLE STORAGE
    //////////////////////////////////////////////////////////////*/
    /// @notice Address of the subordinate sUSD3 strategy
    /// @dev Used for loss absorption and yield distribution
    address public sUSD3;

    bool private __deprecated_whitelistEnabled;

    mapping(address => bool) private __deprecated_whitelist;

    mapping(address => bool) private __deprecated_depositorWhitelist;

    /// @notice Minimum deposit amount required
    uint256 public minDeposit;

    mapping(address => uint256) private __deprecated_depositTimestamp;

    /// @notice Receivers that bypass USD3 supply-cap headroom and first-time minimum-deposit checks.
    mapping(address => bool) public supplyCapExempt;

    /// @notice Conduits whose self-deposits add to the ring-fenced liquidity accumulator.
    mapping(address => bool) public ringFenceConduit;

    /// @notice Fenced capital-call cash in USDC asset units.
    uint256 public ringFencedLiquidity;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/
    event SUSD3StrategyUpdated(address oldStrategy, address newStrategy);
    event SupplyCapExemptUpdated(address indexed account, bool exempt);
    event RingFenceConduitUpdated(address indexed conduit, bool enabled);
    event RingFencedLiquidityIncreased(address indexed conduit, uint256 assets, uint256 newTotal);
    event RingFenceReleased(uint256 assets, uint256 newTotal);
    event MinDepositUpdated(uint256 newMinDeposit);
    event TrancheShareSynced(uint256 trancheShare);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the symbol for the USD3 token
     * @return Symbol string "USD3"
     */
    function symbol() external pure returns (string memory) {
        return "USD3";
    }

    /**
     * @notice Get the market parameters for this strategy
     * @return MarketParams struct containing lending market configuration
     */
    function marketParams() external view returns (MarketParams memory) {
        return _marketParams;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Get current market liquidity information
     * @return totalSupplyAssets Total assets supplied to the market
     * @return totalShares Total supply shares in the market
     * @return totalBorrowAssets Total assets borrowed from the market
     * @return waUSDCLiquidity Available liquidity in the market
     */
    function getMarketLiquidity()
        public
        view
        returns (uint256 totalSupplyAssets, uint256 totalShares, uint256 totalBorrowAssets, uint256 waUSDCLiquidity)
    {
        (totalSupplyAssets, totalShares, totalBorrowAssets,) = morphoCredit.expectedMarketBalances(_marketParams);
        waUSDCLiquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
    }

    /**
     * @dev Get strategy's position in the market
     * @return shares Number of supply shares held
     * @return waUSDCMax Maximum waUSDC that can be withdrawn
     * @return waUSDCLiquidity Available market liquidity in waUSDC
     */
    function getPosition() internal view returns (uint256 shares, uint256 waUSDCMax, uint256 waUSDCLiquidity) {
        shares = morphoCredit.position(marketId, address(this)).supplyShares;
        uint256 totalSupplyAssets;
        uint256 totalShares;
        (totalSupplyAssets, totalShares,, waUSDCLiquidity) = getMarketLiquidity();
        waUSDCMax = shares.toAssetsDown(totalSupplyAssets, totalShares);
    }

    function _protocolConfig() internal view returns (IProtocolConfig) {
        return IProtocolConfig(IMorphoCredit(address(morphoCredit)).protocolConfig());
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Maximum waUSDC deployment allowed by sUSD3 backing alone.
    /// Returns type(uint256).max when no subordination constraint applies.
    function _subordinationDeployCapWaUSDC() internal view returns (uint256) {
        if (sUSD3 == address(0)) return type(uint256).max;

        IProtocolConfig config = _protocolConfig();
        uint256 backingRatio = config.config(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO);
        if (backingRatio == 0) return type(uint256).max;

        uint256 sUSD3Shares = TokenizedStrategy.balanceOf(sUSD3);
        uint256 _totalSupply = TokenizedStrategy.totalSupply();
        uint256 _totalAssets = TokenizedStrategy.totalAssets();

        if (_totalSupply == 0 || _totalAssets == 0 || sUSD3Shares == 0) return 0;

        // Conservative (floor-rounded) USD3 share-to-USDC conversion,
        // same accounting model as sUSD3.sol availableDepositLimit/availableWithdrawLimit
        uint256 sUSD3ValueUSDC = sUSD3Shares.mulDiv(_totalAssets, _totalSupply, Math.Rounding.Floor);
        uint256 maxDebtUSDC = (sUSD3ValueUSDC * 10_000) / backingRatio;

        return WAUSDC.convertToShares(maxDebtUSDC);
    }

    /// @dev Effective deployment cap: min(maxOnCredit-based cap, subordination cap)
    function _effectiveDeployCapWaUSDC(uint256 totalWaUSDC) internal view returns (uint256) {
        uint256 maxOnCreditCap = (totalWaUSDC * maxOnCredit()) / 10_000;
        uint256 subCap = _subordinationDeployCapWaUSDC();
        return Math.min(maxOnCreditCap, subCap);
    }

    /// @dev Wraps idle USDC into waUSDC via a fallible whole-share mint. Skips (leaving USDC idle,
    /// counted at face by nav) when paused, below one share, or — on the deposit/tend path
    /// (enforceSlack) — when the mint's ≤1-unit rounding cost is not covered by realized-but-unreported
    /// interest, so deposit spam cannot walk totalAssets past nav()+2 and freeze withdrawals.
    function _wrapUSDC(uint256 amount, uint256 pendingCredit, bool enforceSlack) private {
        if (amount == 0 || Pausable(address(WAUSDC)).paused()) return;
        uint256 shares = WAUSDC.previewDeposit(amount);
        uint256 maxShares = WAUSDC.maxMint(address(this));
        if (shares > maxShares) shares = maxShares;
        if (shares == 0) return;
        if (enforceSlack) {
            uint256 aggregate = suppliedWaUSDC() + balanceOfWaUSDC();
            uint256 baseValue = WAUSDC.convertToAssets(aggregate);
            uint256 cost = WAUSDC.previewMint(shares);
            uint256 gain = WAUSDC.convertToAssets(aggregate + shares) - baseValue;
            if (cost > gain) {
                uint256 navNow = baseValue + asset.balanceOf(address(this));
                if (TokenizedStrategy.totalAssets() + pendingCredit + (cost - gain) > navNow) return;
            }
        }
        try WAUSDC.mint(shares, address(this)) {} catch {}
    }

    /// @dev Deploy funds to MorphoCredit market respecting maxOnCredit ratio and subordination cap
    /// @param _amount Amount of asset to deploy
    function _deployFunds(uint256 _amount) internal override {
        if (_amount == 0) return;

        // Wrap USDC to waUSDC. pendingCredit = _amount (the full loose balance) is exact for a fresh deposit
        // and conservative otherwise: any pre-existing idle inflates it, so the slack gate can only over-skip,
        // never over-wrap. TokenizedStrategy passes the full loose balance on each deposit, so a deferred pile is
        // retried by the next deposit and is also cleared by the ungated report-time wrap; no keeper signal is needed.
        _wrapUSDC(_amount, _amount, true);

        // A paused wrapper blocks every waUSDC transfer, not just mint and burn, so supplying to Morpho would
        // revert and take the deposit with it. Hold the funds locally instead; a later tend or report deploys
        // them once the pause lifts. Mirrors the guard in _tend.
        if (Pausable(address(WAUSDC)).paused()) return;

        uint256 maxOnCreditRatio = maxOnCredit();
        if (maxOnCreditRatio == 0) {
            // Don't deploy anything when set to 0%, keep all waUSDC local
            return;
        }

        // Calculate total waUSDC (deployed + local)
        uint256 deployedWaUSDC = suppliedWaUSDC();
        uint256 localWaUSDC = balanceOfWaUSDC();
        uint256 totalWaUSDC = deployedWaUSDC + localWaUSDC;

        uint256 maxDeployableWaUSDC = _effectiveDeployCapWaUSDC(totalWaUSDC);

        if (maxDeployableWaUSDC <= deployedWaUSDC) {
            // Already at or above max, keep all new waUSDC local
            return;
        }

        // Deploy only the amount needed to reach max
        uint256 waUSDCToSupply = Math.min(localWaUSDC, maxDeployableWaUSDC - deployedWaUSDC);

        _supplyToMorpho(waUSDCToSupply);
    }

    /// @dev Withdraw funds from MorphoCredit market
    /// @param _amount Amount of asset to free up
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) {
            return;
        }

        // Calculate how much waUSDC we need
        uint256 waUSDCNeeded = WAUSDC.previewWithdraw(_amount);

        // Check local waUSDC balance first
        uint256 localWaUSDC = balanceOfWaUSDC();

        if (localWaUSDC < waUSDCNeeded) {
            // Need to withdraw from MorphoCredit
            uint256 waUSDCToWithdraw = waUSDCNeeded - localWaUSDC;

            uint256 withdrawn = _withdrawFromMorpho(waUSDCToWithdraw);

            if (withdrawn > 0) {
                localWaUSDC = balanceOfWaUSDC();
            }
        }

        uint256 waUSDCToUnwrap = Math.min(Math.min(localWaUSDC, waUSDCNeeded), WAUSDC.maxRedeem(address(this)));

        if (waUSDCToUnwrap > 0) {
            WAUSDC.redeem(waUSDCToUnwrap, address(this), address(this));
        }
    }

    /// @dev Emergency withdraw function to free funds from MorphoCredit
    /// @param amount The amount to withdraw (use type(uint256).max for all)
    function _emergencyWithdraw(uint256 amount) internal override {
        // This is called during shutdown to free funds from Morpho
        // Use _freeFunds which already handles the withdrawal logic
        _freeFunds(amount);
    }

    /// @dev Harvest interest from MorphoCredit and report total assets
    /// @return Total assets held by the strategy
    function _harvestAndReport() internal override returns (uint256) {
        MarketParams memory params = _marketParams;

        morphoCredit.accrueInterest(params);

        if (!TokenizedStrategy.isShutdown()) _wrapUSDC(asset.balanceOf(address(this)), 0, false);

        return nav();
    }

    /// @dev Rebalances between idle and deployed funds to maintain maxOnCredit ratio
    /// @param _totalIdle Current idle funds available
    function _tend(uint256 _totalIdle) internal override {
        if (TokenizedStrategy.isShutdown()) {
            return;
        }
        if (Pausable(address(WAUSDC)).paused()) return;

        // First wrap any idle USDC to waUSDC
        _wrapUSDC(_totalIdle, 0, true);

        _applyDeployCap(true);
    }

    /// @dev Rebalances deployed waUSDC toward the effective deployment cap.
    /// Withdraws excess from MorphoCredit when over the cap; otherwise tops up
    /// deployment from local waUSDC only when supplying is permitted.
    /// @param allowSupply Whether deploying additional local waUSDC is allowed
    function _applyDeployCap(bool allowSupply) private {
        // Calculate based on waUSDC amounts
        uint256 deployedWaUSDC = suppliedWaUSDC();
        uint256 localWaUSDC = balanceOfWaUSDC();
        uint256 totalWaUSDC = deployedWaUSDC + localWaUSDC;

        uint256 targetDeployedWaUSDC = _effectiveDeployCapWaUSDC(totalWaUSDC);

        if (deployedWaUSDC > targetDeployedWaUSDC) {
            // Withdraw excess from MorphoCredit
            uint256 waUSDCToWithdraw = deployedWaUSDC - targetDeployedWaUSDC;
            _withdrawFromMorpho(waUSDCToWithdraw);
        } else if (allowSupply && targetDeployedWaUSDC > deployedWaUSDC && localWaUSDC > 0) {
            // Deploy more if we have local waUSDC
            uint256 waUSDCToDeploy = Math.min(localWaUSDC, targetDeployedWaUSDC - deployedWaUSDC);
            _supplyToMorpho(waUSDCToDeploy);
        }
    }

    /// @dev Signal keepers when deployment drifts from the effective cap
    function _tendTrigger() internal view override returns (bool) {
        if (TokenizedStrategy.isShutdown()) {
            return false;
        }
        if (Pausable(address(WAUSDC)).paused()) return false;

        uint256 deployed = suppliedWaUSDC();
        uint256 localWaUSDC = balanceOfWaUSDC();
        uint256 totalWaUSDC = deployed + localWaUSDC;
        uint256 target = _effectiveDeployCapWaUSDC(totalWaUSDC);

        if (target == 0) return deployed > 0;

        IProtocolConfig config = _protocolConfig();
        uint256 driftBps = config.config(ProtocolConfigLib.TEND_DRIFT_THRESHOLD);
        if (driftBps == 0) driftBps = 10;
        require(driftBps < 10_000);
        uint256 threshold = (target * driftBps) / 10_000;

        if (deployed > target) {
            return (deployed - target) > threshold;
        }
        if (target > deployed && localWaUSDC > 0) {
            return (target - deployed) > threshold;
        }
        return false;
    }

    /// @dev Helper function to supply waUSDC to MorphoCredit
    /// @param amount Amount of waUSDC to supply
    /// @return supplied Actual amount supplied (for consistency with withdraw helper)
    function _supplyToMorpho(uint256 amount) internal returns (uint256 supplied) {
        if (amount == 0) return 0;

        morphoCredit.supply(_marketParams, amount, 0, address(this), "");
        return amount;
    }

    /// @dev Helper function to withdraw waUSDC from MorphoCredit
    /// @param amountRequested Amount of waUSDC to withdraw
    /// @return amountWithdrawn Actual amount withdrawn (may be less than requested)
    function _withdrawFromMorpho(uint256 amountRequested) internal returns (uint256 amountWithdrawn) {
        if (amountRequested == 0) return 0;

        morphoCredit.accrueInterest(_marketParams);
        (uint256 shares, uint256 waUSDCMax, uint256 waUSDCLiquidity) = getPosition();

        uint256 availableWaUSDC = Math.min(waUSDCMax, waUSDCLiquidity);

        if (availableWaUSDC == 0) {
            return 0;
        }

        amountWithdrawn = Math.min(amountRequested, availableWaUSDC);

        if (amountWithdrawn > 0) {
            if (amountWithdrawn >= waUSDCMax) {
                morphoCredit.withdraw(_marketParams, 0, shares, address(this), address(this));
            } else {
                morphoCredit.withdraw(_marketParams, amountWithdrawn, 0, address(this), address(this));
            }
        }

        return amountWithdrawn;
    }

    function _waUSDCGlobalRedeemable() internal view returns (uint256) {
        return WAUSDC.convertToShares(WAUSDC.POOL().getVirtualUnderlyingBalance(WAUSDC.asset()));
    }

    /*//////////////////////////////////////////////////////////////
                    PUBLIC VIEW FUNCTIONS (OVERRIDES)
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the withdrawable assets for an owner after liquidity and floor checks.
    /// @dev The bps floor is a scaling/rate knob applied to then-current total assets, so repeated redemptions drain
    /// geometrically toward the nominal floor. The nominal floor is the hard ring-fence and should be set alongside
    /// the bps floor whenever a fixed asset amount must remain reserved.
    /// @return Maximum amount that can be withdrawn
    function availableWithdrawLimit(address) public view override returns (uint256) {
        // Get available liquidity first
        uint256 idleAsset = asset.balanceOf(address(this));
        uint256 totalAssets = TokenizedStrategy.totalAssets();

        // First-loss guard: while nav trails totalAssets, an unrealized loss is pending, so halt withdrawals
        // until report() burns it against the sUSD3 first-loss tranche rather than paying exiting senior holders at a
        // stale price. The +2 tolerance absorbs the <=1-unit waUSDC wrap/unwrap rounding drift. Deposit-side drift is
        // gated at the source in _wrapUSDC (enforceSlack); the withdraw-side redeem can still nudge the gap past +2,
        // but that halt is transient and liveness-only: nav() converts at the live waUSDC rate, so accruing interest
        // lifts nav() back over totalAssets on its own, and report() re-bases totalAssets to nav definitively. No
        // funds are at risk, so the residual withdraw-side drift is accepted rather than tracked in mutable state
        // under this guard.
        if (nav() + 2 < totalAssets) {
            return 0;
        }

        (, uint256 waUSDCMax, uint256 waUSDCLiquidity) = getPosition();

        uint256 availableWaUSDC;

        if (Pausable(address(WAUSDC)).paused()) {
            availableWaUSDC = 0;
        } else {
            uint256 localWaUSDC = balanceOfWaUSDC();
            uint256 morphoWaUSDC = Math.min(waUSDCMax, waUSDCLiquidity);
            uint256 totalRedeemableWaUSDC = localWaUSDC + morphoWaUSDC;

            if (totalRedeemableWaUSDC > 0) {
                if (WAUSDC.maxRedeem(address(this)) == 0 && WAUSDC.maxRedeem(address(morphoCredit)) == 0) {
                    availableWaUSDC = 0;
                } else {
                    availableWaUSDC = Math.min(totalRedeemableWaUSDC, _waUSDCGlobalRedeemable());
                }
            }
        }

        uint256 availableLiquidity = idleAsset + WAUSDC.convertToAssets(availableWaUSDC);

        // During shutdown, bypass the going-concern redemption constraints below.
        if (TokenizedStrategy.isShutdown()) {
            return availableLiquidity;
        }

        // The fence reserves realized cash liquidity; nominal and bps floors reserve against totalAssets below.
        availableLiquidity = Math.saturatingSub(availableLiquidity, ringFencedLiquidity);

        IProtocolConfig config = _protocolConfig();
        uint256 nominalFloor = config.config(ProtocolConfigLib.USD3_REDEMPTION_FLOOR);
        uint256 floorBps = config.config(ProtocolConfigLib.USD3_REDEMPTION_FLOOR_BPS);
        if (floorBps > MAX_BPS) floorBps = MAX_BPS;
        uint256 bpsFloor = totalAssets.mulDiv(floorBps, MAX_BPS);
        uint256 floor = Math.max(nominalFloor, bpsFloor);

        return Math.min(availableLiquidity, Math.saturatingSub(totalAssets, floor));
    }

    /// @dev Returns available deposit limit, enforcing borrower restrictions and supply cap
    /// @param _owner Address to check limit for
    /// @return Maximum amount that can be deposited
    function availableDepositLimit(address _owner) public view override returns (uint256) {
        if (Pausable(address(WAUSDC)).paused()) {
            return 0;
        }

        // Block deposits from borrowers
        if (morphoCredit.borrowShares(marketId, _owner) > 0) {
            return 0;
        }

        uint256 cap = _protocolConfig().config(ProtocolConfigLib.USD3_SUPPLY_CAP);
        if (cap == 0) {
            return 0;
        }
        if (supplyCapExempt[_owner] || cap == type(uint256).max) {
            return type(uint256).max;
        }

        uint256 currentTotalAssets = TokenizedStrategy.totalAssets();
        if (cap <= currentTotalAssets) {
            return 0;
        }
        return cap - currentTotalAssets;
    }

    /*//////////////////////////////////////////////////////////////
                        HOOKS IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Pre-deposit hook to enforce the first-time minimum deposit
    function _preDepositHook(uint256 assets, uint256 shares, address receiver) internal override {
        if (assets == 0 && shares > 0) {
            assets = TokenizedStrategy.previewMint(shares);
        }

        // Handle type(uint256).max case - resolve to actual balance
        if (assets == type(uint256).max) {
            assets = asset.balanceOf(msg.sender);
        }

        // Enforce minimum deposit only for first-time depositors
        uint256 currentBalance = TokenizedStrategy.balanceOf(receiver);
        if (currentBalance == 0 && !supplyCapExempt[receiver]) {
            require(assets >= minDeposit, "<min");
        }
    }

    /// @dev Accumulates ring-fenced liquidity for conduit self-deposits.
    function _postDepositHook(uint256 assets, uint256 shares, address receiver) internal override {
        if (msg.sender == receiver && ringFenceConduit[receiver]) {
            if (assets == type(uint256).max) assets = TokenizedStrategy.convertToAssets(shares);
            ringFencedLiquidity += assets;
            emit RingFencedLiquidityIncreased(receiver, assets, ringFencedLiquidity);
        }
    }

    /**
     * @notice Report profit and loss with pre-report context for accurate loss absorption
     * @return profit Amount of profit generated
     * @return loss Amount of loss incurred
     */
    function report() external override returns (uint256 profit, uint256 loss) {
        uint256 preSupply = TokenizedStrategy.totalSupply();
        uint256 preAssets = TokenizedStrategy.totalAssets();

        _preReportHook();
        (profit, loss) = _reportInternal();
        _postReportHook(loss, preAssets, preSupply);
    }

    /// @dev Handles loss absorption and post-report rebalancing.
    function _postReportHook(uint256 loss, uint256 preAssets, uint256 preSupply) internal {
        if (loss > 0 && sUSD3 != address(0) && preAssets > 0 && preSupply > 0) {
            // Get sUSD3's current USD3 balance
            uint256 susd3Balance = TokenizedStrategy.balanceOf(sUSD3);

            if (susd3Balance > 0) {
                // Total shares required to cover the loss at the pre-report PPS
                uint256 totalBurnNeeded = loss.mulDiv(preSupply, preAssets, Math.Rounding.Floor);

                // Internal burn from locked shares is reflected in the post-report totalSupply
                uint256 postSupply = TokenizedStrategy.totalSupply();
                uint256 lockedBurn = preSupply > postSupply ? preSupply - postSupply : 0;

                // Burn only the remaining shares from sUSD3
                uint256 sharesToBurn = totalBurnNeeded > lockedBurn ? totalBurnNeeded - lockedBurn : 0;

                // Cap at sUSD3's actual balance - they can't lose more than they have
                if (sharesToBurn > susd3Balance) {
                    sharesToBurn = susd3Balance;
                }

                if (sharesToBurn > 0) {
                    _burnSharesFromSusd3(sharesToBurn);
                }
            }
        }

        _tend(asset.balanceOf(address(this)));
    }

    /// @dev Post-transfer hook that rebalances deployment after sUSD3 unstakes.
    /// When sUSD3 transfers out USD3 shares its subordination backing shrinks, so the
    /// deployment cap is re-applied (withdraw-only) to pull any excess back from MorphoCredit.
    /// Skipped during shutdown.
    /// @param from Address transferring shares
    /// @param amount Amount of shares being transferred
    function _postTransferHook(address from, address, uint256 amount, bool success) internal override {
        if (success && amount > 0 && from == sUSD3 && !TokenizedStrategy.isShutdown()) _applyDeployCap(false);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Directly burn shares from sUSD3's balance using storage manipulation
     *
     * IMPORTANT: Direct storage manipulation is necessary here because TokenizedStrategy
     * does not expose a public burn function. The only ways to burn shares in
     * TokenizedStrategy are through withdraw/redeem (which require asset transfers)
     * or internal profit/loss accounting. Since we need to burn sUSD3's shares
     * without triggering asset transfers, direct storage manipulation is the only
     * viable approach.
     *
     * @param amount Number of shares to burn from sUSD3
     */
    function _burnSharesFromSusd3(uint256 amount) internal {
        // Calculate storage slots using the library
        bytes32 totalSupplySlot = TokenizedStrategyStorageLib.totalSupplySlot();
        bytes32 balanceSlot = TokenizedStrategyStorageLib.balancesSlot(sUSD3);

        // Read current values
        uint256 currentBalance;
        uint256 currentTotalSupply;
        assembly {
            currentBalance := sload(balanceSlot)
            currentTotalSupply := sload(totalSupplySlot)
        }

        // Ensure we don't burn more than available
        uint256 actualBurn = amount;
        if (actualBurn > currentBalance) {
            actualBurn = currentBalance;
        }

        // Update storage
        assembly {
            sstore(balanceSlot, sub(currentBalance, actualBurn))
            sstore(totalSupplySlot, sub(currentTotalSupply, actualBurn))
        }

        // Emit Transfer event to address(0) for transparency
        emit IERC20.Transfer(sUSD3, address(0), actualBurn);
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the balance of waUSDC held locally (not deployed to MorphoCredit)
     * @return Amount of waUSDC held in this contract
     */
    function balanceOfWaUSDC() public view returns (uint256) {
        return WAUSDC.balanceOf(address(this));
    }

    /**
     * @notice Get the amount of waUSDC supplied to MorphoCredit
     * @return Amount of waUSDC deployed to the lending market
     */
    function suppliedWaUSDC() public view returns (uint256) {
        return morphoCredit.expectedSupplyAssets(_marketParams, address(this));
    }

    /// @dev Net asset value of the strategy in USDC terms
    /// @return Sum of deployed and local waUSDC converted to assets, plus idle USDC held by the strategy
    function nav() public view returns (uint256) {
        return WAUSDC.convertToAssets(suppliedWaUSDC() + balanceOfWaUSDC()) + asset.balanceOf(address(this));
    }

    /**
     * @notice Get the maximum percentage of funds to deploy to credit markets from ProtocolConfig
     * @return Maximum deployment ratio in basis points (10000 = 100%)
     * @dev Returns the value from ProtocolConfig directly. If not configured in ProtocolConfig,
     *      it returns 0, effectively preventing deployment until explicitly configured.
     */
    function maxOnCredit() public view returns (uint256) {
        IProtocolConfig config = _protocolConfig();
        return config.getMaxOnCredit();
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the sUSD3 subordinate strategy address
     * @param _sUSD3 Address of the sUSD3 strategy
     * @dev Only callable by management. After calling, also set performance fee recipient.
     */
    function setSUSD3(address _sUSD3) external onlyManagement {
        require(sUSD3 == address(0));
        require(_sUSD3 != address(0));

        sUSD3 = _sUSD3;
        emit SUSD3StrategyUpdated(address(0), _sUSD3);

        // NOTE: After calling this, management should also call:
        // ITokenizedStrategy(usd3Address).setPerformanceFeeRecipient(_sUSD3)
        // to ensure yield distribution goes to sUSD3
    }

    /**
     * @notice Update supply-cap and first-time minimum-deposit exemption status for a receiver.
     * @param _account Receiver address to update.
     * @param _exempt True to bypass supply-cap headroom and first-time minimum-deposit checks, false to remove
     * exemption.
     */
    function setSupplyCapExempt(address _account, bool _exempt) external onlyManagement {
        supplyCapExempt[_account] = _exempt;
        emit SupplyCapExemptUpdated(_account, _exempt);
    }

    /**
     * @notice Update whether a conduit self-deposit adds to ring-fenced liquidity.
     * @param _conduit Receiver address to update.
     * @param _enabled True to accumulate self-deposits into the ring fence, false to disable accumulation.
     */
    function setRingFenceConduit(address _conduit, bool _enabled) external onlyManagement {
        ringFenceConduit[_conduit] = _enabled;
        emit RingFenceConduitUpdated(_conduit, _enabled);
    }

    /**
     * @notice Release ring-fenced liquidity back into the withdrawable liquidity calculation.
     * @param _assets Amount of fenced liquidity to release, in USDC asset units.
     */
    function releaseRingFence(uint256 _assets) external onlyManagement {
        require(_assets <= ringFencedLiquidity, "!fence");
        ringFencedLiquidity -= _assets;
        emit RingFenceReleased(_assets, ringFencedLiquidity);
    }

    /**
     * @notice Set minimum deposit amount
     * @param _minDeposit Minimum amount required for deposits
     */
    function setMinDeposit(uint256 _minDeposit) external onlyManagement {
        minDeposit = _minDeposit;
        emit MinDepositUpdated(_minDeposit);
    }

    /*//////////////////////////////////////////////////////////////
                        KEEPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sync the tranche share (performance fee) from ProtocolConfig
     * @dev Reads TRANCHE_SHARE_VARIANT from ProtocolConfig and updates local storage
     *
     * IMPORTANT: Direct storage manipulation is necessary here because TokenizedStrategy's
     * setPerformanceFee() function has a hardcoded MAX_FEE limit of 5000 (50%). Since we
     * need to support higher fee distributions to sUSD3 (potentially up to 100% for full
     * subordination scenarios), we must bypass this restriction by directly modifying the
     * storage slot.
     *
     * Storage layout in TokenizedStrategy (slot 9):
     * - Bits 0-31: profitMaxUnlockTime (uint32)
     * - Bits 32-47: performanceFee (uint16) <- We modify this
     * - Bits 48-207: performanceFeeRecipient (address)
     *
     * @dev Only callable by keepers to ensure controlled updates
     */
    function syncTrancheShare() external onlyKeepers {
        // Get the protocol config through MorphoCredit
        IProtocolConfig config = _protocolConfig();

        // Read the tranche share variant (yield share to sUSD3 in basis points)
        uint256 trancheShare = config.getTrancheShareVariant();
        require(trancheShare <= 10_000);

        // Get the storage slot for performanceFee using the library
        bytes32 targetSlot = TokenizedStrategyStorageLib.profitConfigSlot();

        // Read current slot value
        uint256 currentSlotValue;
        assembly {
            currentSlotValue := sload(targetSlot)
        }

        // Clear the performanceFee bits (32-47) and set new value
        uint256 mask = ~(uint256(0xFFFF) << 32);
        uint256 newSlotValue = (currentSlotValue & mask) | (trancheShare << 32);

        // Write back to storage
        assembly {
            sstore(targetSlot, newSlotValue)
        }

        emit TrancheShareSynced(trancheShare);
    }

    /*//////////////////////////////////////////////////////////////
                        STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[37] private __gap;
}
