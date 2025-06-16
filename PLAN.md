**Motivation**

All utilization curves in crypto are asset-specific and user-agnostic, in that every user in the same market (ex: Aave USDC, Morpho USDC/ETH) pays the same interest rate. This model is not transferrable for unsecured credit because we must analyze assets as well as *creditworthiness,* which varies with each user. As a result, we must implement our own interest rate model which accounts for a base interest rate as well as a per-user default credit risk premia interest rate.

**Overview**

Deliver modifications to the Morpho Blue `MorphoCredit.sol` contract to support per-borrower risk premiums for credit lines on 3Jane. The existing interest rate model (IRM) mechanism in Morpho Blue will continue to handle the base pool interest rate (e.g., SOFR proxy from Aave V3 USDC market).

This work will focus on adding a mechanism within `MorphoCredit.sol` to:
1. Track a per-borrower default risk premium rate.
2. Accrue this premium to the individual borrower's debt.
3. Ensure this accrued premium correctly increases the total assets in the market, thereby benefiting suppliers.

Repos:

1. https://github.com/3jane-protocol/3jane-irm/blob/main/src/adaptive-curve-irm/JaneAdaptiveCurveIrm.sol (External to this effort, will provide base rate via `IIrm` interface)
2. https://github.com/3jane-protocol/3jane-morpho-blue/blob/main/src/MorphoCredit.sol (Target for modifications)

**In-Scope**

- Smart-contract code within `MorphoCredit.sol` for tracking and accruing per-borrower risk premiums.
- Logic to ensure accrued premiums increase a borrower's debt (`borrowShares`) and the market's `totalBorrowAssets` and `totalSupplyAssets`.
- Handling of protocol fees on the accrued premium amounts.
- Interfaces & events required for off-chain services (like 3CA and keepers) to manage premium rates and trigger accruals.
- Unit + fuzz tests, gas benchmarks, and Foundry deployment scripts for the changes in `MorphoCredit.sol`.
- Test-net deployment (Sepolia) with mock data demonstrating the premium accrual.

**Out‑of‑Scope**

- Implementation or modification of the base Interest Rate Model (IRM) itself (e.g., `AdaptiveCurveIRM`). We assume an external IRM, compliant with Morpho Blue's `IIrm` interface, will provide the base market interest rate.
- Computing the borrower premium rate (handled off‑chain by **3CA**).
- Designing the utilisation curve itself (we reuse AdaptiveCurve parameters).
- Alternative SOFR oracles (Aave deposit rate is the initial proxy, managed by the external IRM).

**Implementation**

- **Per-Borrower Premium Tracking in `MorphoCredit.sol`**:
    - Introduce a new struct to store individual borrower premium details per market:
      ```solidity
      struct BorrowerPremiumDetails {
          uint128 lastPremiumAccrualTime; // Timestamp of the last premium accrual for this borrower
          uint128 premiumRate;            // Current risk premium rate (e.g., annual rate in WAD)
          uint256 borrowAssetsAtLastAccrual; // Snapshot of borrow position at last premium accrual
      }
      mapping(Id => mapping(address => BorrowerPremiumDetails)) public borrowerPremiumDetails;
      ```
    - Implement a function callable by an authorized entity (e.g., 3CA) to set/update a borrower's `premiumRate`. This function will also trigger an accrual of any outstanding premium at the old rate.
    - Add validation to ensure `premiumRate <= MAX_PREMIUM_RATE` (e.g., 1e18 for 100% APR max).

- **Premium Accrual Mechanism**:
    - Create an internal function `_accrueBorrowerPremium(Id marketId, address borrower)` within `MorphoCredit.sol`.
    - This function will:
        - Calculate current borrow position: `currentBorrowAssets = borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares)`.
        - Calculate base growth factor: `baseGrowthFactor = currentBorrowAssets / borrowAssetsAtLastAccrual` (captures how much the position grew from base rate).
        - Calculate premium with compounding: 
            - Simple approach: `premiumAmount = borrowAssetsAtLastAccrual * premiumRate * timeElapsed * baseGrowthFactor`
            - This calculates the premium on the current total asset value of the borrower's debt, which implicitly includes all prior base rate growth.
        - Convert `premiumAmount` to shares and add to `position[marketId][borrower].borrowShares`.
        - Increase `market[marketId].totalBorrowAssets` by `premiumAmount`.
        - Increase `market[marketId].totalSupplyAssets` by `premiumAmount` (this is how suppliers benefit).
        - Calculate and process protocol fees on `premiumAmount`, adding fee shares to `position[marketId][feeRecipient].supplyShares` and `market[marketId].totalSupplyShares`.
        - Update `borrowerPremiumDetails[marketId][borrower]`:
            - Set `lastPremiumAccrualTime` to current timestamp.
            - Set `borrowAssetsAtLastAccrual` to `currentBorrowAssets`.
        - Emit an event detailing the premium accrual.
    - The `_accrueBorrowerPremium` function will be called:
        - Before the standard market-wide `_accrueInterest` when a borrower interacts with their debt position (e.g., `borrow`, `repay`, `liquidate`).
        - When a borrower's `premiumRate` is updated.
        - Potentially by a keeper for inactive borrowers to ensure regular accrual.
    - Add batch premium accrual function `accruePremiumsForBorrowers(Id marketId, address[] calldata borrowers)` for gas-efficient keeper operations.

- **Supply Interest**:
    - Suppliers will implicitly benefit from the accrued borrower premiums because these premiums increase the `market.totalSupplyAssets`, thereby increasing the value of each supply share.
    - No on-chain calculation of a "weighted average premium" will be done to adjust the supply rate directly.

- **Off-Chain Analytics for UI**:
    - A weighted average of active `premiumRate`s can be calculated off-chain by services like 3CA or frontends to display an estimated "Total APR" (Base APR from IRM + Average Premium APR) to users.

- **Careful Integration**: Ensure that the new premium accrual logic integrates correctly with the existing interest accrual (`_accrueInterest`) and fee mechanisms in `Morpho.sol` to prevent double counting or other inconsistencies.

**Potential Gas Cost Inefficiencies**

*   **Increased Cost for Core User Actions:**
    *   Functions like `borrow`, `repay`, and `liquidate` will now also call `_accrueBorrowerPremium`.
    *   This involves additional SLOADs for `borrowerPremiumDetails`, arithmetic for premium calculation, and SSTOREs for updating `borrowerPremiumDetails.lastPremiumAccrualTime`, `position.borrowShares`, `market.totalBorrowAssets`, `market.totalSupplyAssets`, and fee-related storage.
*   **Storage Operations:**
    *   New `borrowerPremiumDetails` mapping means at least one new SLOAD and SSTORE per individual premium accrual.
    *   Updates to market totals and user positions involve SSTOREs.
*   **Arithmetic Operations:**
    *   Premium calculation (scaling annual rate to elapsed time).
    *   Asset-to-shares conversions for premium and fees involve divisions.
*   **Function to Update `premiumRate`:**
    *   Will trigger `_accrueBorrowerPremium` (with its costs) plus an SSTORE for the rate.
*   **Keeper Mechanism:**
    *   Keeper transactions for inactive borrowers will bear the full gas cost of individual accrual.

**Testing Plan**

**A. Unit Tests for New Logic (`_accrueBorrowerPremium` and related setters):**

*   **`_accrueBorrowerPremium` Function:**
    *   Correct Premium Calculation: Vary `premiumRate`, `elapsedTime`, `borrowShares`.
    *   Base Growth Calculation: Test scenarios where market interest has accrued multiple times between premium accruals.
    *   State Updates: Verify `position.borrowShares`, `market.totalBorrowAssets`, `market.totalSupplyAssets`, `borrowerPremiumDetails.lastPremiumAccrualTime`, `borrowerPremiumDetails.borrowAssetsAtLastAccrual`.
    *   Fee Accrual: Verify fee calculation, `feeRecipient.supplyShares`, `market.totalSupplyShares`. Test zero/non-zero fees.
    *   Event Emission: Verify `PremiumAccrued` event with correct parameters.
    *   Edge Cases: Accrual with zero/small market totals.
    *   Precision Loss: Test with very small premiums/shares.
    *   Overflow Protection: Test with extreme time gaps.
*   **Function to Set/Update `premiumRate` (e.g., `setBorrowerPremiumRate`):**
    *   Authorization: Ensure only authorized entity can call.
    *   Prior Accrual: Verify `_accrueBorrowerPremium` called with old rate before update.
    *   State Update: Verify `borrowerPremiumDetails.premiumRate` updated.
    *   Event Emission: Verify rate change event.
    *   Test setting for new borrower and updating existing.
    *   Rate Bounds: Test rejection of rates exceeding MAX_PREMIUM_RATE.

**B. Integration Tests (Interaction with `MorphoCredit.sol` operations):**

*   For `borrow`, `repay`, `liquidate`:
    *   Ensure `_accrueBorrowerPremium` called *before* `_accrueInterest`.
    *   Verify combined state changes are correct.
    *   Health Checks: Ensure `_isHealthy` uses `borrowShares` including accrued premium.
*   For `withdrawCollateral`, `withdraw`:
    *   Ensure `_accrueBorrowerPremium` called for borrower if `_accrueInterest` is triggered.
*   **`accrueInterest` (public function):**
    *   Confirm it only triggers market-wide `_accrueInterest`, not individual premium accruals for all borrowers.
*   **No Double Counting/Accrual:**
    *   Rigorously test to prevent double counting of premiums or fees.
*   **Race Conditions:**
    *   Test concurrent keeper and user actions.
*   **Authorization Edge Cases:**
    *   Test scenarios with compromised rate setter.

**C. Scenario Tests:**

*   **Lifecycle of a Loan with Premium:**
    *   Supply -> Borrow (no premium) -> Set `premiumRate` -> User interaction (triggers accrual) -> Verify balances -> Change `premiumRate` -> Verify accrual/new rate -> Repay fully -> Liquidate (ensure premium accrued first).
*   **Multiple Borrowers:** Market with different premium rates, verify independent accrual.
*   **Impact on Suppliers:** Demonstrate `totalSupplyAssets` growth reflects base interest and all accrued premiums.

**D. Gas Benchmarking:**

*   Measure gas increase for `borrow`, `repay`, `liquidate` with/without active premium.
*   Measure gas cost of `setBorrowerPremiumRate`.
*   Measure gas cost of keeper-triggered `_accrueBorrowerPremium`.

**E. Fuzz Testing:**

*   Fuzz inputs to `_accrueBorrowerPremium`.
*   Fuzz sequences of operations involving borrowers with premiums.

**Future Considerations**

1. **Rate Update Frequency**: Define how often 3CA will update premium rates to optimize gas costs versus premium accuracy.

2. **Historical Premium Tracking**: Consider emitting events with old/new rates for comprehensive audit trails and off-chain analytics.

3. **Emergency Pause Mechanism**: Design a circuit breaker to pause premium accrual in case of critical issues or market anomalies.

4. **Premium Caps**: Implement maximum debt limits (base + premium) relative to collateral value to prevent runaway debt accumulation.

5. **Keeper Incentive Model**: Design economic incentives for keepers to accrue premiums for inactive borrowers, potentially through:
   - Fee sharing from accrued premiums
   - Batch operation rewards
   - Priority fee rebates

6. **Integration with Existing Morpho Ecosystem**: Ensure compatibility with Morpho's existing periphery contracts and integrations.

7. **Cross-Market Premium Correlation**: Consider future enhancements where premium rates might be influenced by borrower behavior across multiple markets.

8. **Automated Premium Adjustment**: Explore on-chain mechanisms for dynamic premium adjustment based on utilization or other risk indicators.

**Further reading**

1. 3.1.3, 3.1.4: https://www.3jane.xyz/pdf/whitepaper.pdf
