**Motivation**

All utilization curves in crypto are asset-specific and user-agnostic, in that every user in the same market (ex: Aave USDC, Morpho USDC/ETH) pays the same interest rate. This model is not transferrable for unsecured credit because we must analyze assets as well as *creditworthiness,* which varies with each user. As a result, we must implement our own interest rate model which accounts for a base interest rate as well as a per-user default credit risk premia interest rate.

**Overview**

Deliver a standalone, upgradeable Solidity module `InterestRateModelV1` that extends the Morpho Blue **AdaptiveCurveIRM** to support credit lines on 3Jane. The module must dynamically combine (1) the base pool interest rate which is at minimum the SOFR (Aave V3 USDC market).

On top of the base rate, create a mechanisM that incorporates a (1) per‑borrower default risk premia, and (w) a global parameter delinquency interest rate while preserving the utilisation‑based incentives of the original curve.

Repos:

1. https://github.com/3jane-protocol/3jane-irm/blob/main/src/adaptive-curve-irm/JaneAdaptiveCurveIrm.sol 
2. https://github.com/3jane-protocol/3jane-morpho-blue/blob/main/src/MorphoCredit.sol 

**In-Scope**

- Smart‑contract code for the rate model + correct interest rate accumulation in morpho blue contract
- Interfaces & events required by the core money‑market / CreditLine contracts.
- Unit + fuzz tests, gas benchmarks, and Foundry deployment scripts.
- Test‑net deployment (Sepolia) with mock data.

**Out‑of‑Scope**

- Computing the borrower premium (handled off‑chain by **3CA**).
- Designing the utilisation curve itself (we reuse AdaptiveCurve parameters). Although if you think we should make adjustments to [base constants](https://github.com/3jane-protocol/3jane-irm/blob/main/src/adaptive-curve-irm/libraries/ConstantsLib.sol) that make more sense for unsecured credit I am all ears
- Alternative SOFR oracles (Aave deposit rate is the initial proxy).

**Ideas**

- Build a per borrower premium tracking that is perodically rolled up into their base borrow position. Something like:

```solidity
    struct BorrowerPremium {
      uint256 lastUpdateTime;     // When premium was last rolled up
      uint256 premiumRate;        // Current risk premium rate
  }
```

- Leave the base borrow interest accural logic mostly intacted.
- For supply interest, incorporate a weighted average of all the borrow premia and included that in interest accurual.
- Be careful not to double accrue.

**Further reading**

1. 3.1.3, 3.1.4: https://www.3jane.xyz/pdf/whitepaper.pdf
