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

**Ideas**

- **Per-Borrower Premium Tracking in `MorphoCredit.sol`**:
    - Introduce a new struct to store individual borrower premium details per market:
      ```solidity
      struct BorrowerPremiumDetails {
          uint256 lastPremiumAccrualTime; // Timestamp of the last premium accrual for this borrower
          uint256 premiumRate;            // Current risk premium rate (e.g., annual rate in WAD)
      }
      mapping(Id => mapping(address => BorrowerPremiumDetails)) public borrowerPremiumDetails;
      ```
    - Implement a function callable by an authorized entity (e.g., 3CA) to set/update a borrower's `premiumRate`. This function will also trigger an accrual of any outstanding premium at the old rate.

- **Premium Accrual Mechanism**:
    - Create an internal function `_accrueIndividualBorrowerPremium(Id marketId, address borrower)` within `MorphoCredit.sol`.
    - This function will:
        - Calculate the premium owed by the `borrower` since `lastPremiumAccrualTime` based on their `borrowShares` and `premiumRate`.
        - Increase the `borrower`'s `position[marketId][borrower].borrowShares` by the shares equivalent of this accrued premium.
        - Increase `market[marketId].totalBorrowAssets` by the accrued premium amount.
        - Increase `market[marketId].totalSupplyAssets` by the same accrued premium amount (this is how suppliers benefit).
        - Calculate and process protocol fees on the accrued premium, adding fee shares to `position[marketId][feeRecipient].supplyShares` and `market[marketId].totalSupplyShares`.
        - Update the `borrower`'s `lastPremiumAccrualTime`.
        - Emit an event detailing the premium accrual.
    - The `_accrueIndividualBorrowerPremium` function will be called:
        - Before the standard market-wide `_accrueInterest` when a borrower interacts with their debt position (e.g., `borrow`, `repay`, `liquidate`).
        - When a borrower's `premiumRate` is updated.
        - Potentially by a keeper for inactive borrowers to ensure regular accrual.

- **Supply Interest**:
    - Suppliers will implicitly benefit from the accrued borrower premiums because these premiums increase the `market.totalSupplyAssets`, thereby increasing the value of each supply share.
    - No on-chain calculation of a "weighted average premium" will be done to adjust the supply rate directly.

- **Off-Chain Analytics for UI**:
    - A weighted average of active `premiumRate`s can be calculated off-chain by services like 3CA or frontends to display an estimated "Total APR" (Base APR from IRM + Average Premium APR) to users.

- **Careful Integration**: Ensure that the new premium accrual logic integrates correctly with the existing interest accrual (`_accrueInterest`) and fee mechanisms in `Morpho.sol` to prevent double counting or other inconsistencies.

**Further reading**

1. 3.1.3, 3.1.4: https://www.3jane.xyz/pdf/whitepaper.pdf
