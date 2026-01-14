// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./CallableCreditBaseTest.sol";
import {ProtocolConfigLib} from "../../../src/libraries/ProtocolConfigLib.sol";

/// @title CallableCreditInvariantHandler
/// @notice Handler contract that exposes state-changing functions for invariant testing
contract CallableCreditInvariantHandler is CallableCreditBaseTest {
    using SharesMathLib for uint256;

    // Track all borrowers that have been used
    address[] public activeBorrowers;
    mapping(address => bool) public isBorrowerActive;

    // Track counter-protocols
    address[] public activeCounterProtocols;
    mapping(address => bool) public isCounterProtocolActive;

    // Ghost variables for tracking expected state
    uint256 public ghost_totalOpenedUsdc;
    uint256 public ghost_totalClosedUsdc;
    uint256 public ghost_totalDrawnUsdc;

    // Counters for call tracking
    uint256 public opens;
    uint256 public closes;
    uint256 public partialCloses;
    uint256 public targetedDraws;
    uint256 public proRataDraws;

    // Pre-created borrowers for testing
    address internal constant HANDLER_BORROWER_1 = address(0x1001);
    address internal constant HANDLER_BORROWER_2 = address(0x1002);
    address internal constant HANDLER_BORROWER_3 = address(0x1003);
    address internal constant HANDLER_BORROWER_4 = address(0x1004);

    uint256 constant MIN_AMOUNT = 1e6;
    uint256 constant MAX_AMOUNT = 100_000e6;
    uint256 constant CREDIT_LINE_MULTIPLIER = 10;

    function setUp() public override {
        super.setUp();

        // Supply more liquidity
        _supplyLiquidity(1_000_000_000e6);

        // Authorize second counter-protocol
        _authorizeCounterProtocol(COUNTER_PROTOCOL_2);

        // Setup all borrowers with credit lines
        _setupBorrowerWithCreditLine(HANDLER_BORROWER_1, MAX_AMOUNT * CREDIT_LINE_MULTIPLIER);
        _setupBorrowerWithCreditLine(HANDLER_BORROWER_2, MAX_AMOUNT * CREDIT_LINE_MULTIPLIER);
        _setupBorrowerWithCreditLine(HANDLER_BORROWER_3, MAX_AMOUNT * CREDIT_LINE_MULTIPLIER);
        _setupBorrowerWithCreditLine(HANDLER_BORROWER_4, MAX_AMOUNT * CREDIT_LINE_MULTIPLIER);

        // Initialize counter-protocol list
        activeCounterProtocols.push(COUNTER_PROTOCOL);
        activeCounterProtocols.push(COUNTER_PROTOCOL_2);
        isCounterProtocolActive[COUNTER_PROTOCOL] = true;
        isCounterProtocolActive[COUNTER_PROTOCOL_2] = true;
    }

    // ============ Handler Functions ============

    /// @notice Open a position for a borrower
    function handler_open(uint256 borrowerSeed, uint256 counterProtocolSeed, uint256 amount) external {
        address borrower = _selectBorrower(borrowerSeed);
        address counterProtocol = _selectCounterProtocol(counterProtocolSeed);
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        // Skip if this would exceed caps (let cap tests handle that)
        try callableCredit.borrowerTotalCcWaUsdc(borrower) returns (uint256 currentCc) {
            uint256 creditLine = IMorpho(address(morpho)).position(ccMarketId, borrower).collateral;
            if (currentCc + amount > creditLine) return;
        } catch {
            return;
        }

        vm.prank(counterProtocol);
        try callableCredit.open(borrower, amount) {
            opens++;
            ghost_totalOpenedUsdc += amount;

            if (!isBorrowerActive[borrower]) {
                activeBorrowers.push(borrower);
                isBorrowerActive[borrower] = true;
            }
        } catch {}
    }

    /// @notice Full close a position
    function handler_close(uint256 borrowerSeed, uint256 counterProtocolSeed) external {
        if (activeBorrowers.length == 0) return;

        address borrower = _selectActiveBorrower(borrowerSeed);
        address counterProtocol = _selectCounterProtocol(counterProtocolSeed);

        uint256 shares = callableCredit.borrowerShares(counterProtocol, borrower);
        if (shares == 0) return;

        uint256 principalBefore = callableCredit.getBorrowerPrincipal(counterProtocol, borrower);

        vm.prank(counterProtocol);
        try callableCredit.close(borrower) {
            closes++;
            ghost_totalClosedUsdc += principalBefore;
        } catch {}
    }

    /// @notice Partial close a position
    function handler_partialClose(uint256 borrowerSeed, uint256 counterProtocolSeed, uint256 closeFraction) external {
        if (activeBorrowers.length == 0) return;

        address borrower = _selectActiveBorrower(borrowerSeed);
        address counterProtocol = _selectCounterProtocol(counterProtocolSeed);

        uint256 shares = callableCredit.borrowerShares(counterProtocol, borrower);
        if (shares == 0) return;

        uint256 principal = callableCredit.getBorrowerPrincipal(counterProtocol, borrower);
        closeFraction = bound(closeFraction, 1, 99);
        uint256 closeAmount = (principal * closeFraction) / 100;
        if (closeAmount == 0) closeAmount = MIN_AMOUNT;
        if (closeAmount > principal) closeAmount = principal;

        vm.prank(counterProtocol);
        try callableCredit.close(borrower, closeAmount) {
            partialCloses++;
            ghost_totalClosedUsdc += closeAmount;
        } catch {}
    }

    /// @notice Targeted draw from a specific borrower
    function handler_targetedDraw(uint256 borrowerSeed, uint256 counterProtocolSeed, uint256 drawFraction) external {
        if (activeBorrowers.length == 0) return;

        address borrower = _selectActiveBorrower(borrowerSeed);
        address counterProtocol = _selectCounterProtocol(counterProtocolSeed);

        uint256 shares = callableCredit.borrowerShares(counterProtocol, borrower);
        if (shares == 0) return;

        uint256 principal = callableCredit.getBorrowerPrincipal(counterProtocol, borrower);
        drawFraction = bound(drawFraction, 1, 99);
        uint256 drawAmount = (principal * drawFraction) / 100;
        if (drawAmount == 0) drawAmount = MIN_AMOUNT;
        if (drawAmount > principal) drawAmount = principal;

        vm.prank(counterProtocol);
        try callableCredit.draw(borrower, drawAmount, RECIPIENT) {
            targetedDraws++;
            ghost_totalDrawnUsdc += drawAmount;
        } catch {}
    }

    /// @notice Pro-rata draw from a silo
    function handler_proRataDraw(uint256 counterProtocolSeed, uint256 drawFraction) external {
        address counterProtocol = _selectCounterProtocol(counterProtocolSeed);

        (uint128 totalPrincipal,,) = callableCredit.silos(counterProtocol);
        if (totalPrincipal == 0) return;

        drawFraction = bound(drawFraction, 1, 99);
        uint256 drawAmount = (uint256(totalPrincipal) * drawFraction) / 100;
        if (drawAmount == 0) drawAmount = MIN_AMOUNT;
        if (drawAmount > totalPrincipal) drawAmount = totalPrincipal;

        vm.prank(counterProtocol);
        try callableCredit.draw(drawAmount, RECIPIENT) {
            proRataDraws++;
            ghost_totalDrawnUsdc += drawAmount;
        } catch {}
    }

    /// @notice Warp time forward
    function handler_warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 7 days);
        vm.warp(block.timestamp + seconds_);
    }

    // ============ Selection Helpers ============

    function _selectBorrower(uint256 seed) internal pure returns (address) {
        address[4] memory borrowers = [HANDLER_BORROWER_1, HANDLER_BORROWER_2, HANDLER_BORROWER_3, HANDLER_BORROWER_4];
        return borrowers[seed % 4];
    }

    function _selectActiveBorrower(uint256 seed) internal view returns (address) {
        if (activeBorrowers.length == 0) return HANDLER_BORROWER_1;
        return activeBorrowers[seed % activeBorrowers.length];
    }

    function _selectCounterProtocol(uint256 seed) internal view returns (address) {
        return activeCounterProtocols[seed % activeCounterProtocols.length];
    }

    // ============ View Functions for Invariant Checks ============

    function getCallableCredit() external view returns (CallableCredit) {
        return callableCredit;
    }

    function getWausdc() external view returns (WaUSDCMock) {
        return wausdc;
    }

    function getMorpho() external view returns (IMorpho) {
        return morpho;
    }

    function getCcMarketId() external view returns (Id) {
        return ccMarketId;
    }

    function getActiveBorrowersCount() external view returns (uint256) {
        return activeBorrowers.length;
    }

    function getActiveBorrowerAt(uint256 index) external view returns (address) {
        return activeBorrowers[index];
    }

    function getActiveCounterProtocolsCount() external view returns (uint256) {
        return activeCounterProtocols.length;
    }

    function getActiveCounterProtocolAt(uint256 index) external view returns (address) {
        return activeCounterProtocols[index];
    }

    function getCallStats() external view returns (uint256, uint256, uint256, uint256, uint256) {
        return (opens, closes, partialCloses, targetedDraws, proRataDraws);
    }
}

/// @title CallableCreditInvariantTest
/// @notice Invariant tests for CallableCredit
contract CallableCreditInvariantTest is Test {
    CallableCreditInvariantHandler public handler;

    function setUp() public {
        handler = new CallableCreditInvariantHandler();
        handler.setUp();

        // Target the handler for fuzzing
        targetContract(address(handler));

        // Define which functions the fuzzer should call
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.handler_open.selector;
        selectors[1] = handler.handler_close.selector;
        selectors[2] = handler.handler_partialClose.selector;
        selectors[3] = handler.handler_targetedDraw.selector;
        selectors[4] = handler.handler_proRataDraw.selector;
        selectors[5] = handler.handler_warpTime.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ============ Invariant: Total Shares Consistency ============

    /// @notice Total shares in a silo should equal sum of all borrower shares
    function invariant_totalSharesEqualsSumOfBorrowerShares() public view {
        CallableCredit cc = handler.getCallableCredit();
        uint256 counterProtocolCount = handler.getActiveCounterProtocolsCount();

        for (uint256 i = 0; i < counterProtocolCount; i++) {
            address counterProtocol = handler.getActiveCounterProtocolAt(i);
            (, uint128 totalShares,) = cc.silos(counterProtocol);

            uint256 sumBorrowerShares = 0;
            uint256 borrowerCount = handler.getActiveBorrowersCount();

            for (uint256 j = 0; j < borrowerCount; j++) {
                address borrower = handler.getActiveBorrowerAt(j);
                sumBorrowerShares += cc.borrowerShares(counterProtocol, borrower);
            }

            assertEq(totalShares, sumBorrowerShares, "Invariant violated: total shares != sum of borrower shares");
        }
    }

    // ============ Invariant: Principal-Shares Consistency ============

    /// @notice Principal and shares should be consistent (both zero or both non-zero)
    /// @dev With pro-rata draws, principal can reach zero while shares remain because
    ///      pro-rata draw reduces principal but not shares. This is valid state.
    ///      The invariant checks that principal > 0 implies shares > 0.
    function invariant_principalSharesConsistency() public view {
        CallableCredit cc = handler.getCallableCredit();
        uint256 counterProtocolCount = handler.getActiveCounterProtocolsCount();

        for (uint256 i = 0; i < counterProtocolCount; i++) {
            address counterProtocol = handler.getActiveCounterProtocolAt(i);
            (uint128 totalPrincipal, uint128 totalShares,) = cc.silos(counterProtocol);

            // Principal > 0 implies shares > 0 (principal cannot exist without shares)
            if (totalPrincipal > 0) {
                assertGt(totalShares, 0, "Invariant violated: principal exists but shares are zero");
            }

            // Note: shares > 0 with principal == 0 is VALID after pro-rata draws
            // This represents a dust position that can only be cleared via close()
        }
    }

    // ============ Invariant: waUSDC Tracking Consistency ============

    /// @notice totalCcWaUsdc should be >= sum of silo waUSDC held
    /// @dev totalCcWaUsdc tracks historical opens minus closes, not current holdings after draws
    ///      Draws reduce silo.totalWaUsdcHeld but not totalCcWaUsdc (capacity tracking)
    function invariant_totalCcWaUsdcConsistency() public view {
        CallableCredit cc = handler.getCallableCredit();
        uint256 counterProtocolCount = handler.getActiveCounterProtocolsCount();
        uint256 sumSiloWaUsdc = 0;

        for (uint256 i = 0; i < counterProtocolCount; i++) {
            address counterProtocol = handler.getActiveCounterProtocolAt(i);
            (,, uint128 totalWaUsdcHeld) = cc.silos(counterProtocol);
            sumSiloWaUsdc += totalWaUsdcHeld;
        }

        uint256 totalCcWaUsdc = cc.totalCcWaUsdc();
        // totalCcWaUsdc >= sumSiloWaUsdc because draws reduce silo holdings but not tracking
        assertGe(totalCcWaUsdc, sumSiloWaUsdc, "Invariant violated: totalCcWaUsdc < sum of silo waUSDC");
    }

    // ============ Invariant: Borrower waUSDC Tracking ============

    /// @notice Borrower total CC waUSDC tracking should be >= their current holdings
    /// @dev Like totalCcWaUsdc, borrowerTotalCcWaUsdc tracks opens minus closes, not current holdings
    ///      Draws reduce silo holdings proportionally but not the tracking
    function invariant_borrowerCcWaUsdcConsistency() public view {
        CallableCredit cc = handler.getCallableCredit();
        uint256 borrowerCount = handler.getActiveBorrowersCount();
        uint256 counterProtocolCount = handler.getActiveCounterProtocolsCount();

        for (uint256 i = 0; i < borrowerCount; i++) {
            address borrower = handler.getActiveBorrowerAt(i);
            uint256 trackedBorrowerCc = cc.borrowerTotalCcWaUsdc(borrower);

            // Calculate current holdings from shares (proportional to silo waUSDC)
            uint256 currentHoldings = 0;
            for (uint256 j = 0; j < counterProtocolCount; j++) {
                address counterProtocol = handler.getActiveCounterProtocolAt(j);
                uint256 borrowerSharesAmt = cc.borrowerShares(counterProtocol, borrower);
                (, uint128 totalShares, uint128 totalWaUsdcHeld) = cc.silos(counterProtocol);

                if (totalShares > 0 && borrowerSharesAmt > 0) {
                    currentHoldings += (borrowerSharesAmt * uint256(totalWaUsdcHeld)) / uint256(totalShares);
                }
            }

            // Tracked amount should be >= current holdings (draws reduce holdings but not tracking)
            // Allow 1 wei tolerance for rounding differences in share calculations
            assertGe(
                trackedBorrowerCc + 1,
                currentHoldings,
                "Invariant violated: borrower tracking < current holdings (beyond rounding tolerance)"
            );
        }
    }

    // ============ Invariant: Principal Derivable from Shares ============

    /// @notice getBorrowerPrincipal should be derivable from shares
    function invariant_principalDerivableFromShares() public view {
        CallableCredit cc = handler.getCallableCredit();
        uint256 borrowerCount = handler.getActiveBorrowersCount();
        uint256 counterProtocolCount = handler.getActiveCounterProtocolsCount();

        for (uint256 i = 0; i < counterProtocolCount; i++) {
            address counterProtocol = handler.getActiveCounterProtocolAt(i);
            (uint128 totalPrincipal, uint128 totalShares,) = cc.silos(counterProtocol);

            uint256 sumDerivedPrincipal = 0;

            for (uint256 j = 0; j < borrowerCount; j++) {
                address borrower = handler.getActiveBorrowerAt(j);
                uint256 derivedPrincipal = cc.getBorrowerPrincipal(counterProtocol, borrower);
                sumDerivedPrincipal += derivedPrincipal;
            }

            // Sum of derived principals should approximately equal total principal
            // Allow for rounding errors (1 wei per borrower)
            assertApproxEqAbs(
                sumDerivedPrincipal,
                uint256(totalPrincipal),
                borrowerCount + 1,
                "Invariant violated: sum of derived principals != total principal"
            );
        }
    }

    // ============ Invariant: No Orphaned Shares ============

    /// @notice A borrower with shares should have derivable principal > 0 if silo has substantial principal
    /// @dev After pro-rata draws, principal can become very small (dust) while shares exist.
    ///      Due to SharesMathLib's virtual shares (1e6), small principal amounts may round to 0
    ///      when deriving individual borrower principal. We only check when:
    ///      1. Silo has substantial principal (> 1e6 USDC equivalent)
    ///      2. Borrower has significant share of total
    function invariant_noOrphanedShares() public view {
        CallableCredit cc = handler.getCallableCredit();
        uint256 borrowerCount = handler.getActiveBorrowersCount();
        uint256 counterProtocolCount = handler.getActiveCounterProtocolsCount();

        for (uint256 i = 0; i < counterProtocolCount; i++) {
            address counterProtocol = handler.getActiveCounterProtocolAt(i);
            (uint128 totalPrincipal, uint128 totalShares,) = cc.silos(counterProtocol);

            // Skip silos with no shares, no principal, or dust principal
            // Dust principal can occur after many pro-rata draws
            if (totalShares == 0 || totalPrincipal < 1e6) continue;

            for (uint256 j = 0; j < borrowerCount; j++) {
                address borrower = handler.getActiveBorrowerAt(j);
                uint256 shares = cc.borrowerShares(counterProtocol, borrower);

                if (shares > 0) {
                    // With non-zero shares and silo with substantial principal,
                    // principal should be derivable for significant share holders
                    uint256 principal = cc.getBorrowerPrincipal(counterProtocol, borrower);

                    // Only assert if shares are very significant relative to total (> 1%)
                    // AND silo has meaningful principal
                    // This avoids false positives from SharesMathLib rounding
                    if (shares * 100 > totalShares && totalPrincipal > 1e6) {
                        // If shares are > 1% of total and principal is substantial, should have derivable principal
                        assertGt(
                            principal,
                            0,
                            "Invariant violated: significant shares with zero principal when silo has substantial principal"
                        );
                    }
                }
            }
        }
    }

    // ============ Invariant: waUSDC Balance Consistency ============

    /// @notice CallableCredit waUSDC balance should be >= sum of silo waUSDC held
    function invariant_waUsdcBalanceConsistency() public view {
        CallableCredit cc = handler.getCallableCredit();
        WaUSDCMock waUsdcMock = handler.getWausdc();
        uint256 actualBalance = waUsdcMock.balanceOf(address(cc));
        uint256 counterProtocolCount = handler.getActiveCounterProtocolsCount();

        uint256 sumSiloWaUsdc = 0;
        for (uint256 i = 0; i < counterProtocolCount; i++) {
            address counterProtocol = handler.getActiveCounterProtocolAt(i);
            (,, uint128 totalWaUsdcHeld) = cc.silos(counterProtocol);
            sumSiloWaUsdc += totalWaUsdcHeld;
        }

        assertGe(actualBalance, sumSiloWaUsdc, "Invariant violated: actual waUSDC balance < tracked silo amounts");
    }

    // ============ Summary Function ============

    /// @notice Log summary of invariant test execution
    function invariant_callSummary() public view {
        (uint256 opens, uint256 closes, uint256 partialCloses, uint256 targetedDraws, uint256 proRataDraws) =
            handler.getCallStats();

        console.log("Call Summary:");
        console.log("  Opens:", opens);
        console.log("  Closes:", closes);
        console.log("  Partial Closes:", partialCloses);
        console.log("  Targeted Draws:", targetedDraws);
        console.log("  Pro-Rata Draws:", proRataDraws);
        console.log("  Active Borrowers:", handler.getActiveBorrowersCount());
    }
}
