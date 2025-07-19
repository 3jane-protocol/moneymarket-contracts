# 3Jane Protocol - Smart Contract Audit Scope

![Alt text](architecture.png)

## Executive Summary

3Jane is a credit-based money market built on top of Morpho Blue that provides unsecured credit lines underwritten against DeFi assets and FICO credit scores. 3Jane provides the following augmentations on top of the base Morpho functionality:
1. Dynamic risk-based pricing: interest rates per user are the sum of the a) base variable rate on the morpho utilization curve b) fixed default credit risk premium assigned on a per-user basis.
2. Repayment schedules: liquidations are replaced by monthly repayments a user must perform in order to be considered healthy, past which point they are considered delinquent or even in default which adds an additional penalty interest rate. The protocol may in real-time mark down the position to reflect the recovery rate (which may be less than the amount borrowed). If funds are considered non-recoverable, the debt may be written off via settle which may or may not be covered by the insurance fund.

Read the whitepaper for more: https://www.3jane.xyz/pdf/whitepaper.pdf

## Protocol Overview

### 1. USD3 (Senior Tranche Strategy)

**Location**: `usd3/src/USD3.sol`

**Purpose**: Senior tranche strategy that provides stable yield with capital protection through sUSD3 subordination. This is a derivation of the yearn v3 vault strategy. 

### 2. sUSD3 (Junior Tranche Strategy)

**Location**: `usd3/src/sUSD3.sol`

**Purpose**: Junior tranche strategy that absorbs first losses and provides levered yield opportunities. This is a derivation of the yearn v3 vault strategy. 

### 3. MorphoCredit

**Location**: `morpho-blue/src/MorphoCredit.sol`

**Purpose**: Extends Morpho Blue with credit-based lending, per-borrower risk premiums, and delinquency management.

**Key Features**:

-  **Three-Tier Interest System**: 

	i . Base Rate: Market-wide rate from IRM

    ii. Premium Rate: Per-borrower risk premium

    iii. Penalty Rate: Additional rate for delinquent borrowers

-  **Premium Accrual**: Continuous premium calculation based on credit scores

-  **Payment Cycles**: Structured repayment obligations

-  **Markdown System**: Dynamic debt value reduction for defaulted positions

-  **Delinquency Management**: Grace periods and penalty rate application

### 4. ProtocolConfig (Configuration Management)

**Location**: `morpho-blue/src/ProtocolConfig.sol`

**Purpose**: Centralized configuration management for all protocol parameters.

**Key Features**:

-  **Credit Line Config**: LTV limits, credit line bounds, DRP limits

-  **Market Config**: Grace periods, delinquency periods, minimum borrow amounts

-  **IRM Config**: Interest rate model parameters

-  **Tranche Config**: USD3/sUSD3 ratios and lock durations

-  **Admin Controls**: Owner-only parameter updates

### 5. CreditLine (Credit Line Management)

**Location**: `morpho-blue/src/CreditLine.sol`

**Purpose**: Manages credit line creation, validation, and configuration for individual borrowers.

**Key Features**:

-  **Credit Line Validation**: Enforces protocol limits and constraints

-  **External Verification**: Optional prover integration for additional validation

-  **OZD **: Open zeppelin defender. 

-  **Parameter Bounds**: Validates LTV, credit amounts, and premium rates

### 6. Interest Rate Module (IRM)

**Location**: `morpho-blue/src/irm/adaptive-curve-irm/AdaptiveCurveIrm.sol`

**Purpose**: Implements adaptive interest rate curves that respond to market utilization.

**Key Features**:

-  **Adaptive Curves**: Interest rates adjust based on market utilization

-  **Target Utilization**: Protocol-defined optimal utilization rate

-  **Rate Bounds**: Minimum and maximum rate constraints

-  **Exponential Adaptation**: Smooth rate transitions over time

### 7. MarkdownManager (Debt Valuation)

**Location**: `morpho-blue/src/MarkdownManager.sol`
**Purpose**: Manages debt markdown calculations for defaulted positions.

**Key Features**:

-  **Markdown Calculation**: Reduces debt value based on time in default

-  **Multiplier System**: Time-based value reduction multipliers

-  **Default Tracking**: Monitors borrower default status and duration

### 8. Helper 

**Location**: `morpho-blue/src/Helper.sol`

**Purpose**: Provides convenient integration functions for users to interact with the protocol.

### 8. InsuranceFund 

**Location**: `morpho-blue/src/InsuranceFund.sol`

**Purpose**: Simple custody of insurance fund assets (ex: USDC)


## Out-of-Scope
1. $xJANE
2. NPL Auction
3. zkTLS Proofs (Prover)