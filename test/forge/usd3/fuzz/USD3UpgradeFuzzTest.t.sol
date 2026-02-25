// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {IUSD3} from "../../../../src/usd3/interfaces/IUSD3.sol";
import {USD3 as USD3_old} from "../../../../src/usd3/USD3_old.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IERC20, ERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Math} from "../../../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {IMorpho} from "../../../../src/interfaces/IMorpho.sol";

/**
 * @title USD3 Upgrade Fuzz Test
 * @notice Fuzz tests for the USD3 upgrade path to ensure invariants hold across random scenarios
 * @dev Tests upgrade with random user counts, deposit amounts, and waUSDC share prices
 */
contract USD3UpgradeFuzzTest is Setup {
    using Math for uint256;

    // Proxy and implementation contracts
    USD3_old public oldImplementation;
    USD3 public newImplementation;
    TransparentUpgradeableProxy public usd3Proxy;
    ProxyAdmin public usd3ProxyAdmin;

    // Admin slot for ERC1967 proxy (from ERC1967Utils)
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // Constants
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant MAX_USERS = 20;

    function setUp() public override {
        super.setUp();
        _deployOldUSD3WithProxy();
    }

    function _deployOldUSD3WithProxy() internal {
        // Deploy old implementation
        oldImplementation = new USD3_old();

        // Initialize data for USD3_old (with waUSDC as asset)
        // Get morphoCredit and marketId from the base Setup
        USD3 setupStrategyTemp = USD3(address(strategy));
        bytes memory initData = abi.encodeWithSelector(
            USD3_old.initialize.selector,
            address(setupStrategyTemp.morphoCredit()),
            setupStrategyTemp.marketId(),
            management,
            keeper
        );

        // Deploy proxy with this contract as the owner of the internal ProxyAdmin
        // Note: TransparentUpgradeableProxy creates its own ProxyAdmin internally
        usd3Proxy = new TransparentUpgradeableProxy(
            address(oldImplementation),
            address(this), // Owner of the internally-created ProxyAdmin
            initData
        );

        // Get the actual ProxyAdmin address from the proxy's storage
        bytes32 adminSlot = vm.load(address(usd3Proxy), ADMIN_SLOT);
        usd3ProxyAdmin = ProxyAdmin(address(uint160(uint256(adminSlot))));

        // Set USD3 address on MorphoCredit
        USD3 setupStrategy = USD3(address(strategy));
        IMorpho morphoCredit = setupStrategy.morphoCredit();
        vm.prank(morphoCredit.owner());
        MorphoCredit(address(morphoCredit)).setUsd3(address(usd3Proxy));
    }

    function _performUpgrade() internal {
        // Execute the multisig batch operations BEFORE upgrade as per USD3 reinitialize natspec
        ITokenizedStrategy strategyInterface = ITokenizedStrategy(address(usd3Proxy));

        // Store current values
        uint256 currentProfitMaxUnlockTime = strategyInterface.profitMaxUnlockTime();

        // Step 1: Set performance fee to 0
        vm.prank(management);
        strategyInterface.setPerformanceFee(0);

        // Step 2: Set profit unlock time to 0
        vm.prank(management);
        strategyInterface.setProfitMaxUnlockTime(0);

        // Step 3: Report to update totalAssets from stale waUSDC values
        vm.prank(keeper);
        strategyInterface.report();

        // Step 4: Deploy new implementation
        newImplementation = new USD3();

        // Step 5: Upgrade proxy to new implementation
        usd3ProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(usd3Proxy)), address(newImplementation), bytes("")
        );

        // Step 6: Call reinitialize to switch from waUSDC to USDC
        USD3(address(usd3Proxy)).reinitialize();

        // Step 7: Report again to re-sync totalAssets under new USDC accounting
        vm.prank(keeper);
        strategyInterface.report();

        // Step 8: Sync tranche share (restores performance fee)
        vm.prank(keeper);
        IUSD3(address(usd3Proxy)).syncTrancheShare();

        // Step 9: Restore profit unlock time
        vm.prank(management);
        strategyInterface.setProfitMaxUnlockTime(currentProfitMaxUnlockTime);
    }

    /**
     * @notice Fuzz test that total shares are preserved during upgrade
     */
    function testFuzz_upgradePreservesTotalShares(uint8 numUsers, uint256 seed, uint256 waUSDCPrice) public {
        // Bound inputs
        numUsers = uint8(bound(numUsers, 2, MAX_USERS));
        waUSDCPrice = bound(waUSDCPrice, 1000010, 1999990); // >1x to <2x appreciation (realistic range)

        // Start with 1:1 for initial deposits
        waUSDC.setSharePrice(1e6);

        // Create and fund users with random amounts
        address[] memory users = new address[](numUsers);
        uint256 totalDeposited = 0;
        uint256 totalSharesBefore = 0;

        for (uint256 i = 0; i < numUsers; i++) {
            // Create user
            users[i] = makeAddr(string(abi.encodePacked("user", i)));

            // Generate random deposit amount using Setup's bounds
            uint256 depositAmount = bound(uint256(keccak256(abi.encode(seed, i))), minFuzzAmount, maxFuzzAmount);

            // Fund user with USDC and wrap to waUSDC
            airdrop(asset, users[i], depositAmount);
            vm.startPrank(users[i]);
            asset.approve(address(waUSDC), depositAmount);
            waUSDC.deposit(depositAmount, users[i]);

            // Deposit into old strategy
            uint256 waUSDCBalance = waUSDC.balanceOf(users[i]);
            waUSDC.approve(address(usd3Proxy), waUSDCBalance);
            uint256 shares = ITokenizedStrategy(address(usd3Proxy)).deposit(waUSDCBalance, users[i]);
            vm.stopPrank();

            totalDeposited += depositAmount;
            totalSharesBefore += shares;
        }

        // Capture total supply before upgrade
        uint256 totalSupplyBefore = ITokenizedStrategy(address(usd3Proxy)).totalSupply();
        assertEq(totalSupplyBefore, totalSharesBefore, "Total supply mismatch before upgrade");

        // Now set the actual waUSDC price to simulate appreciation
        waUSDC.setSharePrice(waUSDCPrice);

        // Perform upgrade
        _performUpgrade();

        // Verify total shares preserved
        uint256 totalSupplyAfter = ITokenizedStrategy(address(usd3Proxy)).totalSupply();
        assertEq(totalSupplyAfter, totalSupplyBefore, "Total shares not preserved");

        // Verify sum of user shares equals total
        uint256 sumOfUserShares = 0;
        for (uint256 i = 0; i < numUsers; i++) {
            sumOfUserShares += ITokenizedStrategy(address(usd3Proxy)).balanceOf(users[i]);
        }
        assertEq(sumOfUserShares, totalSupplyAfter, "Sum of user shares != total supply");
    }

    /**
     * @notice Fuzz test that user proportions are maintained during upgrade
     */
    function testFuzz_upgradePreservesUserProportions(uint256[5] memory deposits, uint256 sharePrice) public {
        // Bound inputs
        sharePrice = bound(sharePrice, 1000010, 1999990); // >1x to <2x appreciation (realistic range)
        for (uint256 i = 0; i < deposits.length; i++) {
            deposits[i] = bound(deposits[i], minFuzzAmount, maxFuzzAmount);
        }

        // Start with 1:1 for initial deposits
        waUSDC.setSharePrice(1e6);

        // Create users and track their proportion of total
        address[] memory users = new address[](5);
        uint256[] memory sharesBefore = new uint256[](5);
        uint256 totalSharesBefore = 0;

        for (uint256 i = 0; i < 5; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));

            // Fund and deposit
            airdrop(asset, users[i], deposits[i]);
            vm.startPrank(users[i]);
            asset.approve(address(waUSDC), deposits[i]);
            waUSDC.deposit(deposits[i], users[i]);

            uint256 waUSDCBalance = waUSDC.balanceOf(users[i]);
            waUSDC.approve(address(usd3Proxy), waUSDCBalance);
            sharesBefore[i] = ITokenizedStrategy(address(usd3Proxy)).deposit(waUSDCBalance, users[i]);
            vm.stopPrank();

            totalSharesBefore += sharesBefore[i];
        }

        // Calculate proportions before upgrade
        uint256[] memory proportionsBefore = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            if (totalSharesBefore > 0) {
                proportionsBefore[i] = sharesBefore[i].mulDiv(1e18, totalSharesBefore);
            }
        }

        // Now set the actual waUSDC price to simulate appreciation
        waUSDC.setSharePrice(sharePrice);

        // Perform upgrade
        _performUpgrade();

        // Calculate proportions after upgrade
        uint256 totalSharesAfter = ITokenizedStrategy(address(usd3Proxy)).totalSupply();
        for (uint256 i = 0; i < 5; i++) {
            uint256 sharesAfter = ITokenizedStrategy(address(usd3Proxy)).balanceOf(users[i]);
            uint256 proportionAfter = 0;
            if (totalSharesAfter > 0) {
                proportionAfter = sharesAfter.mulDiv(1e18, totalSharesAfter);
            }

            // Verify proportion maintained (allow tiny rounding difference)
            assertApproxEqAbs(
                proportionAfter,
                proportionsBefore[i],
                1, // Max 1 wei difference in proportion calculation
                "User proportion not maintained"
            );
        }
    }

    /**
     * @notice Fuzz test that withdrawals work correctly after upgrade
     */
    function testFuzz_withdrawalsWorkPostUpgrade(uint256 depositAmount, uint256 withdrawPercent, uint256 sharePrice)
        public
    {
        // Bound inputs
        depositAmount = bound(depositAmount, minFuzzAmount, maxFuzzAmount);
        withdrawPercent = bound(withdrawPercent, 1, 100);
        sharePrice = bound(sharePrice, 1000010, 1999990); // >1x to <2x appreciation (realistic range)

        // Start with 1:1 for initial deposits
        waUSDC.setSharePrice(1e6);

        // Create user and deposit
        address user = makeAddr("user");
        airdrop(asset, user, depositAmount);
        // Give waUSDC some buffer for rounding differences
        airdrop(asset, address(waUSDC), depositAmount);

        vm.startPrank(user);
        asset.approve(address(waUSDC), depositAmount);
        waUSDC.deposit(depositAmount, user);

        uint256 waUSDCBalance = waUSDC.balanceOf(user);
        waUSDC.approve(address(usd3Proxy), waUSDCBalance);
        uint256 shares = ITokenizedStrategy(address(usd3Proxy)).deposit(waUSDCBalance, user);
        vm.stopPrank();

        // Now set the actual waUSDC price to simulate appreciation
        waUSDC.setSharePrice(sharePrice);

        // Perform upgrade
        _performUpgrade();

        // Calculate withdrawal amount
        uint256 sharesToWithdraw = shares.mulDiv(withdrawPercent, 100);

        // Preview the withdrawal to ensure we don't try to redeem more than available
        uint256 maxRedeem = ITokenizedStrategy(address(usd3Proxy)).maxRedeem(user);
        if (sharesToWithdraw > maxRedeem) {
            sharesToWithdraw = maxRedeem;
        }

        // Withdraw after upgrade
        vm.startPrank(user);
        uint256 withdrawn = ITokenizedStrategy(address(usd3Proxy)).redeem(sharesToWithdraw, user, user);
        vm.stopPrank();

        // Verify withdrawal returned USDC (not waUSDC)
        assertEq(asset.balanceOf(user), withdrawn, "Did not receive USDC");
        assertEq(waUSDC.balanceOf(user), 0, "Should not receive waUSDC");

        // Verify amount is reasonable (should be close to expected based on share price)
        // The withdrawal amount should reflect the waUSDC appreciation
        uint256 expectedWithdrawal = depositAmount.mulDiv(withdrawPercent, 100).mulDiv(sharePrice, 1e6);
        assertApproxEqRel(withdrawn, expectedWithdrawal, 0.1e18, "Withdrawal amount unexpected"); // 10% tolerance
    }

    function testFuzz_withdrawalsBalancePostUpgrade(uint256 depositAmount, uint256 sharePrice) public {
        // Bound inputs
        depositAmount = bound(depositAmount, minFuzzAmount, maxFuzzAmount);
        sharePrice = bound(sharePrice, 1000010, 1999990); // >1x to <2x appreciation (realistic range)

        waUSDC.setSharePrice(sharePrice);

        // Fund waUSDC with extra USDC to back the appreciated share price
        // If sharePrice is 1.1, waUSDC needs 10% more USDC than shares to back redemptions
        // We simulate waUSDC having existing reserves from prior deposits/yield
        uint256 existingReserves = depositAmount.mulDiv(sharePrice - 1e6, 1e6);
        airdrop(asset, address(waUSDC), existingReserves);

        // Create user and deposit
        address user = makeAddr("user");
        airdrop(asset, user, depositAmount);

        vm.startPrank(user);
        asset.approve(address(waUSDC), depositAmount);
        waUSDC.deposit(depositAmount, user);

        uint256 waUSDCBalance = waUSDC.balanceOf(user);
        waUSDC.approve(address(usd3Proxy), waUSDCBalance);
        ITokenizedStrategy(address(usd3Proxy)).deposit(waUSDCBalance, user);
        vm.stopPrank();

        // Perform upgrade
        _performUpgrade();

        // Withdraw after upgrade
        vm.startPrank(user);
        uint256 withdrawn = ITokenizedStrategy(address(usd3Proxy))
            .redeem(ITokenizedStrategy(address(usd3Proxy)).balanceOf(user), user, user);
        vm.stopPrank();

        // Verify withdrawal returned USDC (not waUSDC)
        assertEq(asset.balanceOf(user), withdrawn, "Did not receive USDC");
        assertEq(waUSDC.balanceOf(user), 0, "Should not receive waUSDC");
        assertApproxEqRel(withdrawn, depositAmount, 0.001e18, "Withdrawal amount unexpected"); // 1% tolerance
    }

    /**
     * @notice Fuzz test that total assets are preserved during upgrade
     */
    function testFuzz_totalAssetsPreserved(uint8 numUsers, uint256 seed, uint256 sharePrice) public {
        // Bound inputs
        numUsers = uint8(bound(numUsers, 1, MAX_USERS));
        sharePrice = bound(sharePrice, 1000010, 1999990); // >1x to <2x appreciation (realistic range)

        // Start with 1:1 for initial deposits
        waUSDC.setSharePrice(1e6);

        // Create and fund users
        uint256 totalDeposited = 0;
        for (uint256 i = 0; i < numUsers; i++) {
            address user = makeAddr(string(abi.encodePacked("user", i)));

            // Random deposit
            uint256 depositAmount = bound(
                uint256(keccak256(abi.encode(seed, i))),
                minFuzzAmount,
                maxFuzzAmount / numUsers // Divide by numUsers to avoid overflow
            );

            // Fund and deposit
            airdrop(asset, user, depositAmount);
            vm.startPrank(user);
            asset.approve(address(waUSDC), depositAmount);
            waUSDC.deposit(depositAmount, user);

            uint256 waUSDCBalance = waUSDC.balanceOf(user);
            waUSDC.approve(address(usd3Proxy), waUSDCBalance);
            ITokenizedStrategy(address(usd3Proxy)).deposit(waUSDCBalance, user);
            vm.stopPrank();

            totalDeposited += depositAmount;
        }

        // Capture total assets before upgrade
        uint256 totalAssetsBefore = ITokenizedStrategy(address(usd3Proxy)).totalAssets();

        // Now set the actual waUSDC price to simulate appreciation
        waUSDC.setSharePrice(sharePrice);

        // Perform upgrade
        _performUpgrade();

        // Verify total assets reflect the waUSDC appreciation correctly
        uint256 totalAssetsAfter = ITokenizedStrategy(address(usd3Proxy)).totalAssets();
        // After upgrade with report, totalAssets should reflect the waUSDC appreciation
        uint256 expectedTotalAssets = totalAssetsBefore * sharePrice / 1e6;
        assertApproxEqRel(
            totalAssetsAfter,
            expectedTotalAssets,
            0.01e18, // 1% tolerance for rounding
            "Total assets should reflect waUSDC appreciation"
        );
    }

    /**
     * @notice Fuzz test that no funds are locked during upgrade
     */
    function testFuzz_noFundsLocked(uint256[3] memory deposits, uint256 sharePrice) public {
        // Bound inputs
        sharePrice = bound(sharePrice, 1000010, 1999990); // >1x to <2x appreciation (realistic range)
        for (uint256 i = 0; i < deposits.length; i++) {
            deposits[i] = bound(deposits[i], minFuzzAmount, maxFuzzAmount / 3);
        }

        // Start with 1:1 for initial deposits
        waUSDC.setSharePrice(1e6);

        // Create users and deposit
        address[] memory users = new address[](3);
        uint256 totalDeposits = 0;
        for (uint256 i = 0; i < 3; i++) {
            totalDeposits += deposits[i];
        }
        // Give waUSDC extra USDC for rounding differences
        airdrop(asset, address(waUSDC), totalDeposits);

        for (uint256 i = 0; i < 3; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));

            // Fund and deposit
            airdrop(asset, users[i], deposits[i]);
            vm.startPrank(users[i]);
            asset.approve(address(waUSDC), deposits[i]);
            waUSDC.deposit(deposits[i], users[i]);

            uint256 waUSDCBalance = waUSDC.balanceOf(users[i]);
            waUSDC.approve(address(usd3Proxy), waUSDCBalance);
            ITokenizedStrategy(address(usd3Proxy)).deposit(waUSDCBalance, users[i]);
            vm.stopPrank();
        }

        // Now set the actual waUSDC price to simulate appreciation
        waUSDC.setSharePrice(sharePrice);

        // Perform upgrade
        _performUpgrade();

        // All users should be able to withdraw their funds
        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(users[i]);
            uint256 shares = ITokenizedStrategy(address(usd3Proxy)).balanceOf(users[i]);
            // Use maxRedeem to avoid trying to redeem more than available due to rounding
            uint256 maxRedeem = ITokenizedStrategy(address(usd3Proxy)).maxRedeem(users[i]);
            uint256 sharesToRedeem = shares > maxRedeem ? maxRedeem : shares;
            uint256 withdrawn = ITokenizedStrategy(address(usd3Proxy)).redeem(sharesToRedeem, users[i], users[i]);
            vm.stopPrank();

            totalWithdrawn += withdrawn;
            assertGt(withdrawn, 0, "User could not withdraw");
        }

        // Verify strategy is empty after all withdrawals (allow up to 3 shares for rounding with 3 users)
        assertLe(
            ITokenizedStrategy(address(usd3Proxy)).totalSupply(), 3, "Too many shares remain after full withdrawal"
        );
        // Allow more tolerance for rounding during conversions
        assertLe(ITokenizedStrategy(address(usd3Proxy)).totalAssets(), 100, "Assets remain after full withdrawal");
    }

    /**
     * @notice Fuzz test new USDC deposits after upgrade
     */
    function testFuzz_newDepositsAfterUpgrade(uint256 preUpgradeDeposit, uint256 postUpgradeDeposit, uint256 sharePrice)
        public
    {
        // Skip edge case where unbounded value is max uint256 (causes mock issues)
        vm.assume(postUpgradeDeposit < type(uint256).max / 2);

        // Bound inputs
        preUpgradeDeposit = bound(preUpgradeDeposit, minFuzzAmount, maxFuzzAmount / 2);
        postUpgradeDeposit = bound(postUpgradeDeposit, minFuzzAmount, maxFuzzAmount / 2);
        sharePrice = bound(sharePrice, 1000010, 1999990); // >1x to <2x appreciation (realistic range)

        // Start with 1:1 for initial deposits
        waUSDC.setSharePrice(1e6);

        // Pre-upgrade deposit
        address oldUser = makeAddr("oldUser");
        airdrop(asset, oldUser, preUpgradeDeposit);

        vm.startPrank(oldUser);
        asset.approve(address(waUSDC), preUpgradeDeposit);
        waUSDC.deposit(preUpgradeDeposit, oldUser);

        uint256 waUSDCBalance = waUSDC.balanceOf(oldUser);
        waUSDC.approve(address(usd3Proxy), waUSDCBalance);
        uint256 oldShares = ITokenizedStrategy(address(usd3Proxy)).deposit(waUSDCBalance, oldUser);
        vm.stopPrank();

        // Now set the actual waUSDC price to simulate appreciation
        waUSDC.setSharePrice(sharePrice);

        // Perform upgrade
        _performUpgrade();

        // After upgrade, ensure waUSDC has enough USDC to handle redemptions
        {
            uint256 totalUSDCNeeded = waUSDC.convertToAssets(waUSDC.totalSupply());
            uint256 currentBalance = asset.balanceOf(address(waUSDC));
            if (totalUSDCNeeded > currentBalance) {
                airdrop(asset, address(waUSDC), totalUSDCNeeded - currentBalance + 10e6);
            }
        }

        // New user deposits USDC after upgrade
        address newUser = makeAddr("newUser");
        airdrop(asset, newUser, postUpgradeDeposit);

        vm.startPrank(newUser);
        asset.approve(address(usd3Proxy), postUpgradeDeposit);
        uint256 newShares = ITokenizedStrategy(address(usd3Proxy)).deposit(postUpgradeDeposit, newUser);
        vm.stopPrank();

        // Verify both users have shares
        assertGt(newShares, 0, "New user did not receive shares");
        assertEq(ITokenizedStrategy(address(usd3Proxy)).balanceOf(oldUser), oldShares, "Old user shares changed");

        // Verify both can withdraw
        // For old user - try to withdraw a small test amount
        vm.prank(oldUser);
        uint256 oldMaxRedeem = ITokenizedStrategy(address(usd3Proxy)).maxRedeem(oldUser);

        if (oldMaxRedeem > 0) {
            uint256 testAmount = oldMaxRedeem > 1e6 ? 1e6 : oldMaxRedeem;
            vm.prank(oldUser);
            uint256 oldWithdraw = ITokenizedStrategy(address(usd3Proxy)).redeem(testAmount, oldUser, oldUser);
            assertGt(oldWithdraw, 0, "Old user cannot withdraw");
        }

        vm.startPrank(newUser);
        uint256 newMaxRedeem = ITokenizedStrategy(address(usd3Proxy)).maxRedeem(newUser);
        uint256 newSharesToRedeem = newShares > newMaxRedeem ? newMaxRedeem : newShares;
        uint256 newWithdraw = ITokenizedStrategy(address(usd3Proxy)).redeem(newSharesToRedeem, newUser, newUser);
        vm.stopPrank();
        assertGt(newWithdraw, 0, "New user cannot withdraw");
    }
}
