// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Setup, ERC20, IUSD3} from "./utils/Setup.sol";
import {USD3} from "../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../src/usd3/sUSD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {TransparentUpgradeableProxy} from
    "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {InvariantHandler} from "./handlers/InvariantHandler.sol";

/**
 * @title InvariantsTest
 * @notice Formal invariant testing for USD3/sUSD3 protocol
 * @dev Uses Foundry's invariant testing framework to verify critical properties
 */
contract InvariantsTest is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    InvariantHandler public handler;

    // Test actors
    address[] public actors;
    mapping(address => bool) public isActor;

    // State tracking for invariant checks
    uint256 public totalDepositedUSD3;
    uint256 public totalDepositedSUSD3;
    mapping(address => uint256) public userBalanceSnapshots;

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3
        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);

        bytes memory susd3InitData =
            abi.encodeWithSelector(sUSD3.initialize.selector, address(usd3Strategy), management, keeper);

        TransparentUpgradeableProxy susd3Proxy =
            new TransparentUpgradeableProxy(address(susd3Implementation), address(susd3ProxyAdmin), susd3InitData);

        susd3Strategy = sUSD3(address(susd3Proxy));

        // Link strategies
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Set MAX_ON_CREDIT to enable potential debt calculation for sUSD3 deposits
        setMaxOnCredit(8000); // 80% max deployment

        // Set MORPHO_DEBT_CAP for debt-based subordination
        setMorphoDebtCap(10_000e6); // 10K USDC debt cap

        // Setup test actors
        _setupActors();

        // Deploy handler contract
        handler = new InvariantHandler(address(usd3Strategy), address(susd3Strategy), address(underlyingAsset), actors);

        // Target only the handler contract for invariant testing
        targetContract(address(handler));
    }

    function _setupActors() internal {
        // Create test actors with USDC
        for (uint256 i = 0; i < 5; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);
            isActor[actor] = true;

            // Give actor USDC
            deal(address(underlyingAsset), actor, 100_000e6);

            // Approve strategies
            vm.prank(actor);
            underlyingAsset.approve(address(usd3Strategy), type(uint256).max);

            // Some actors deposit to USD3
            if (i < 3) {
                vm.prank(actor);
                usd3Strategy.deposit(500e6, actor);
                totalDepositedUSD3 += 500e6;
            }
        }

        // Create market debt to enable sUSD3 deposits (debt-based subordination)
        // Only create debt if there were USD3 deposits
        if (totalDepositedUSD3 > 0) {
            address borrower = makeAddr("marketBorrower");
            // Create debt smaller than deposits to ensure liquidity
            uint256 debtAmount = totalDepositedUSD3 / 2; // 50% of deposits
            if (debtAmount > 100e6) {
                // At least $100 debt
                createMarketDebt(borrower, debtAmount);
            }
        }

        // Give some actors USD3 to deposit into sUSD3 (smaller amounts to respect subordination ratio)
        for (uint256 i = 0; i < 2; i++) {
            address actor = actors[i];
            uint256 usd3Balance = ERC20(address(usd3Strategy)).balanceOf(actor);

            if (usd3Balance > 0) {
                // Check available deposit limit based on debt-based subordination
                uint256 availableLimit = susd3Strategy.availableDepositLimit(actor);
                if (availableLimit > 0) {
                    // Only deposit 10% of balance or the available limit, whichever is smaller
                    uint256 depositAmount = usd3Balance / 10;
                    if (depositAmount > availableLimit) {
                        depositAmount = availableLimit;
                    }

                    vm.prank(actor);
                    ERC20(address(usd3Strategy)).approve(address(susd3Strategy), depositAmount);

                    vm.prank(actor);
                    susd3Strategy.deposit(depositAmount, actor);
                    totalDepositedSUSD3 += depositAmount;
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INVARIANT DEFINITIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Invariant: Total supply equals sum of all balances
     * @dev This must hold for both USD3 and sUSD3
     */
    function invariant_totalSupplyConsistency() public {
        // USD3 total supply consistency
        uint256 usd3TotalSupply = ERC20(address(usd3Strategy)).totalSupply();
        uint256 usd3SumOfBalances = 0;

        // Sum up all USD3 balances
        for (uint256 i = 0; i < actors.length; i++) {
            usd3SumOfBalances += ERC20(address(usd3Strategy)).balanceOf(actors[i]);
        }
        // Add sUSD3's USD3 balance
        usd3SumOfBalances += ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        // Add any other holders (management, keeper, etc.)
        usd3SumOfBalances += ERC20(address(usd3Strategy)).balanceOf(management);
        usd3SumOfBalances += ERC20(address(usd3Strategy)).balanceOf(keeper);

        assertApproxEqAbs(usd3TotalSupply, usd3SumOfBalances, 100, "USD3: Total supply != sum of balances");

        // sUSD3 total supply consistency
        uint256 susd3TotalSupply = ERC20(address(susd3Strategy)).totalSupply();
        uint256 susd3SumOfBalances = 0;

        for (uint256 i = 0; i < actors.length; i++) {
            susd3SumOfBalances += ERC20(address(susd3Strategy)).balanceOf(actors[i]);
        }

        assertApproxEqAbs(susd3TotalSupply, susd3SumOfBalances, 100, "sUSD3: Total supply != sum of balances");
    }

    /**
     * @notice Invariant: Subordination deposit limit is correctly enforced
     * @dev Verifies that sUSD3 deposit limits are properly enforced based on debt-based subordination
     * @dev sUSD3 can only back up to maxSubRatio of the market debt
     */
    function invariant_subordinationDepositEnforcement() public {
        // Get the subordinated debt cap from USD3
        uint256 debtCapUSDC = susd3Strategy.getSubordinatedDebtCapInAssets();

        // Get current sUSD3 holdings of USD3
        uint256 susd3Usd3Holdings = ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy));

        // Convert USD3 holdings to USDC value
        uint256 susd3HoldingsUSDC = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(susd3Usd3Holdings);

        // Get deposit limit for an actual actor, not the test contract
        address testActor = actors.length > 0 ? actors[0] : address(this);
        uint256 depositLimit = susd3Strategy.availableDepositLimit(testActor);

        if (debtCapUSDC == 0) {
            // No debt to subordinate, no deposits should be allowed
            assertEq(depositLimit, 0, "Should not allow deposits when no debt exists");
        } else if (susd3HoldingsUSDC >= debtCapUSDC) {
            // Already at or above cap
            assertEq(depositLimit, 0, "Should not allow deposits when at debt cap");
        } else {
            // Should allow deposits up to the cap
            uint256 remainingCapacityUSDC = debtCapUSDC - susd3HoldingsUSDC;
            uint256 expectedLimitUSD3 = ITokenizedStrategy(address(usd3Strategy)).convertToShares(remainingCapacityUSDC);
            assertEq(depositLimit, expectedLimitUSD3, "Deposit limit calculation incorrect");
        }
    }

    /**
     * @notice Invariant: Subordination ratio is maintained based on debt
     * @dev Verifies sUSD3 holdings don't exceed the debt-based subordination cap
     */
    function invariant_totalSubordinationRatio() public {
        // Get the subordinated debt cap from USD3
        uint256 debtCapUSDC = susd3Strategy.getSubordinatedDebtCapInAssets();

        // Get current sUSD3 holdings of USD3
        address susd3Addr = address(susd3Strategy);
        uint256 susd3Holdings = ERC20(address(usd3Strategy)).balanceOf(susd3Addr);

        if (susd3Holdings == 0) {
            return; // No subordination to check
        }

        // Convert USD3 holdings to USDC value
        uint256 susd3HoldingsUSDC = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(susd3Holdings);

        // sUSD3 holdings should not exceed the debt-based cap
        // Note: The cap can be temporarily exceeded if debt decreases
        // but new deposits will be blocked
        if (debtCapUSDC > 0) {
            // This is a soft invariant - holdings can exceed cap if debt decreases
            // but availableDepositLimit should be 0 when at/above cap
            if (susd3HoldingsUSDC > debtCapUSDC) {
                // Check deposit limit for one of the actors instead of this contract
                if (actors.length > 0) {
                    uint256 depositLimit = susd3Strategy.availableDepositLimit(actors[0]);
                    // Allow for small rounding tolerance (0.01% of cap)
                    uint256 tolerance = debtCapUSDC / 10000;
                    assertLe(depositLimit, tolerance, "Deposits should be effectively blocked when above debt cap");
                }
            }
        }
    }

    /**
     * @notice Invariant: USD3 total assets >= total supply (no losses without sUSD3 absorption)
     * @dev If sUSD3 exists, it should absorb losses first
     */
    function invariant_lossAbsorptionOrder() public {
        uint256 usd3TotalAssets = ITokenizedStrategy(address(usd3Strategy)).totalAssets();
        uint256 usd3TotalSupply = ERC20(address(usd3Strategy)).totalSupply();
        uint256 susd3TotalSupply = ERC20(address(susd3Strategy)).totalSupply();

        if (susd3TotalSupply > 0) {
            // If sUSD3 exists and there are losses, sUSD3 should absorb them
            // USD3 should maintain its value
            assertGe(
                usd3TotalAssets,
                (usd3TotalSupply * 99) / 100, // Allow 1% variance for rounding
                "USD3 suffered losses while sUSD3 exists"
            );
        }
    }

    /**
     * @notice Invariant: Share price monotonicity (except during losses)
     * @dev Share prices should only decrease during loss events
     */
    function invariant_sharePriceMonotonicity() public {
        // This invariant would need historical tracking in production
        // For testing, we verify share price calculation is consistent

        if (ERC20(address(usd3Strategy)).totalSupply() > 0) {
            uint256 sharePrice = (ITokenizedStrategy(address(usd3Strategy)).totalAssets() * 1e18)
                / ERC20(address(usd3Strategy)).totalSupply();
            assertGe(sharePrice, 0.99e18, "USD3 share price dropped significantly");
        }

        if (ERC20(address(susd3Strategy)).totalSupply() > 0) {
            uint256 susd3Assets = ITokenizedStrategy(address(susd3Strategy)).totalAssets();
            uint256 susd3SharePrice = (susd3Assets * 1e18) / ERC20(address(susd3Strategy)).totalSupply();
            assertGe(susd3SharePrice, 0.9e18, "sUSD3 share price dropped too much");
        }
    }

    /**
     * @notice Invariant: No negative balances or underflows
     * @dev Balances should never underflow
     */
    function invariant_noNegativeBalances() public {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];

            // Check USD3 balance
            uint256 usd3Balance = ERC20(address(usd3Strategy)).balanceOf(actor);
            assertLe(usd3Balance, type(uint256).max / 2, "USD3 balance overflow");

            // Check sUSD3 balance
            uint256 susd3Balance = ERC20(address(susd3Strategy)).balanceOf(actor);
            assertLe(susd3Balance, type(uint256).max / 2, "sUSD3 balance overflow");
        }
    }

    /**
     * @notice Invariant: Deposit/withdraw symmetry
     * @dev Users should be able to withdraw what they deposit (minus fees/losses)
     */
    function invariant_depositWithdrawSymmetry() public {
        // For each actor, if they have shares, they should be able to withdraw
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 usd3Shares = ERC20(address(usd3Strategy)).balanceOf(actor);

            if (usd3Shares > 0) {
                uint256 withdrawable = ITokenizedStrategy(address(usd3Strategy)).previewRedeem(usd3Shares);
                assertGt(withdrawable, 0, "Cannot withdraw despite having shares");

                // Withdrawable should be reasonable compared to shares
                assertGe(
                    withdrawable,
                    (usd3Shares * 90) / 100, // At least 90% of share value
                    "Withdrawable amount too low"
                );
            }
        }
    }

    /**
     * @notice Invariant: MaxDeposit respects limits
     * @dev maxDeposit should respect subordination ratio and other limits
     */
    function invariant_maxDepositRespected() public {
        // Check USD3 max deposit
        uint256 usd3MaxDeposit = ITokenizedStrategy(address(usd3Strategy)).maxDeposit(address(this));
        if (!ITokenizedStrategy(address(usd3Strategy)).isShutdown()) {
            assertGt(usd3MaxDeposit, 0, "USD3 maxDeposit is 0 when not shutdown");
        }

        // Check sUSD3 max deposit respects subordination
        uint256 susd3MaxDeposit = ITokenizedStrategy(address(susd3Strategy)).maxDeposit(address(this));
        uint256 usd3Supply = ERC20(address(usd3Strategy)).totalSupply();
        uint256 susd3Supply = ERC20(address(susd3Strategy)).totalSupply();

        if (susd3Supply > 0 && usd3Supply > 0) {
            // Get debt-based cap from sUSD3
            uint256 debtCap = susd3Strategy.getSubordinatedDebtCapInAssets();
            uint256 susd3HoldingsInAssets = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(
                ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy))
            );
            uint256 availableRoom = debtCap > susd3HoldingsInAssets ? debtCap - susd3HoldingsInAssets : 0;

            assertLe(
                susd3MaxDeposit,
                availableRoom + 1000, // Allow small variance
                "sUSD3 maxDeposit exceeds subordination limit"
            );
        }
    }

    /**
     * @notice Invariant: Protocol solvency
     * @dev Total assets should cover total liabilities
     */
    // TODO: Fix morphoCredit reference
    // function invariant_protocolSolvency() public {
    //     uint256 totalMorphoDeployed = 0;
    //     uint256 totalIdle = underlyingAsset.balanceOf(address(usd3Strategy));
    //
    //     // Get Morpho position
    //     uint256 morphoAssets = morphoCredit.expectedSupplyAssets(
    //         usd3Strategy.marketParams(),
    //         address(usd3Strategy)
    //     );
    //     totalMorphoDeployed = morphoAssets;
    //
    //     uint256 totalAssets = totalIdle + totalMorphoDeployed;
    //     uint256 totalLiabilities = ERC20(address(usd3Strategy)).totalSupply();
    //
    //     // Total assets should cover at least 95% of liabilities (allowing for fees)
    //     assertGe(
    //         totalAssets,
    //         totalLiabilities * 95 / 100,
    //         "Protocol is insolvent"
    //     );
    // }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper to simulate random user actions
     * @dev Called by Foundry's invariant testing framework
     */
    function deposit_USD3(uint256 amount, uint256 actorSeed) public {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1e6, 10_000e6); // 1 to 10,000 USDC

        uint256 balance = underlyingAsset.balanceOf(actor);
        if (balance >= amount) {
            vm.prank(actor);
            try usd3Strategy.deposit(amount, actor) returns (uint256) {
                totalDepositedUSD3 += amount;
            } catch {}
        }
    }

    function withdraw_USD3(uint256 shares, uint256 actorSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = ERC20(address(usd3Strategy)).balanceOf(actor);
        shares = bound(shares, 0, balance);

        if (shares > 0) {
            vm.prank(actor);
            try usd3Strategy.redeem(shares, actor, actor) returns (uint256) {
                // Success
            } catch {}
        }
    }

    function deposit_sUSD3(uint256 amount, uint256 actorSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 usd3Balance = ERC20(address(usd3Strategy)).balanceOf(actor);
        amount = bound(amount, 0, usd3Balance);

        if (amount > 0) {
            vm.prank(actor);
            ERC20(address(usd3Strategy)).approve(address(susd3Strategy), amount);

            vm.prank(actor);
            try susd3Strategy.deposit(amount, actor) returns (uint256) {
                totalDepositedSUSD3 += amount;
            } catch {}
        }
    }

    function transfer_shares(uint256 amount, uint256 fromSeed, uint256 toSeed) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];

        if (from == to) return;

        uint256 balance = ERC20(address(usd3Strategy)).balanceOf(from);
        amount = bound(amount, 0, balance);

        if (amount > 0) {
            vm.prank(from);
            try usd3Strategy.transfer(to, amount) returns (bool) {
                // Success
            } catch {}
        }
    }
}
