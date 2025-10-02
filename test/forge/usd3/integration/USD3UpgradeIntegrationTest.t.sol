// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {USD3 as USD3_old} from "../../../../src/usd3/USD3_old.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {console2} from "forge-std/console2.sol";
import {IMorpho, MarketParams} from "../../../../src/interfaces/IMorpho.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {Math} from "../../../../lib/openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title USD3 Upgrade Integration Test
 * @notice Tests the upgrade path from USD3_old (waUSDC-based) to USD3 (USDC-based with internal wrapping)
 * @dev Validates that user funds are preserved during the upgrade process
 */
contract USD3UpgradeIntegrationTest is Setup {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                            TEST INFRASTRUCTURE
    //////////////////////////////////////////////////////////////*/

    // Proxy and implementation contracts
    USD3_old public oldImplementation;
    USD3 public newImplementation;
    TransparentUpgradeableProxy public usd3Proxy;
    ProxyAdmin public usd3ProxyAdmin;

    // Admin slot for ERC1967 proxy (from ERC1967Utils)
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // Test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public whale = makeAddr("whale");
    address[] public users;

    // State tracking
    mapping(address => uint256) public preUpgradeShares;
    mapping(address => uint256) public preUpgradeExpectedAssets;
    uint256 public totalSupplyBefore;
    uint256 public totalAssetsBefore;
    uint256 public waUSDCBalanceBefore;
    uint256 public morphoSharesBefore;

    // Constants
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function setUp() public override {
        super.setUp();

        // Setup test users
        users = new address[](4);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;
        users[3] = whale;

        // Fund users with waUSDC for old strategy deposits
        _fundUsersWithWaUSDC();

        // Deploy USD3_old with proxy pattern
        _deployOldUSD3WithProxy();
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _fundUsersWithWaUSDC() internal {
        // First fund users with USDC
        airdrop(asset, alice, 1000e6);
        airdrop(asset, bob, 2000e6);
        airdrop(asset, charlie, 500e6);
        airdrop(asset, whale, 10000e6);

        // Then have them wrap to waUSDC
        vm.startPrank(alice);
        asset.approve(address(waUSDC), 1000e6);
        waUSDC.deposit(1000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(waUSDC), 2000e6);
        waUSDC.deposit(2000e6, bob);
        vm.stopPrank();

        vm.startPrank(charlie);
        asset.approve(address(waUSDC), 500e6);
        waUSDC.deposit(500e6, charlie);
        vm.stopPrank();

        vm.startPrank(whale);
        asset.approve(address(waUSDC), 10000e6);
        waUSDC.deposit(10000e6, whale);
        vm.stopPrank();
    }

    function _deployOldUSD3WithProxy() internal {
        // Deploy old implementation
        oldImplementation = new USD3_old();

        // Get morphoCredit and marketId from the setup strategy
        USD3 setupStrategy = USD3(address(strategy));
        IMorpho morphoCredit = setupStrategy.morphoCredit();

        // Initialize data for USD3_old (with waUSDC as asset)
        bytes memory initData = abi.encodeWithSelector(
            USD3_old.initialize.selector, address(morphoCredit), setupStrategy.marketId(), management, keeper
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
        vm.prank(morphoCredit.owner());
        MorphoCredit(address(morphoCredit)).setUsd3(address(usd3Proxy));
    }

    function _capturePreUpgradeState() internal {
        ITokenizedStrategy oldStrategy = ITokenizedStrategy(address(usd3Proxy));

        // Capture total state
        totalSupplyBefore = oldStrategy.totalSupply();
        totalAssetsBefore = oldStrategy.totalAssets();

        // Capture user shares
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 shares = oldStrategy.balanceOf(user);
            preUpgradeShares[user] = shares;

            // Calculate expected assets for each user
            if (shares > 0) {
                preUpgradeExpectedAssets[user] = oldStrategy.previewRedeem(shares);
            }
        }

        // Capture waUSDC balance
        waUSDCBalanceBefore = waUSDC.balanceOf(address(usd3Proxy));

        // Capture Morpho position
        USD3_old oldUSD3 = USD3_old(address(usd3Proxy));
        USD3 setupStrategy = USD3(address(strategy));
        morphoSharesBefore = setupStrategy.morphoCredit().position(oldUSD3.marketId(), address(usd3Proxy)).supplyShares;
    }

    function _performUpgrade() internal {
        // Deploy new implementation
        newImplementation = new USD3();

        // Upgrade proxy to new implementation
        // Pass empty bytes since we'll call reinitialize separately
        usd3ProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(usd3Proxy)), address(newImplementation), bytes("")
        );

        // Call reinitialize to switch from waUSDC to USDC
        USD3(address(usd3Proxy)).reinitialize();
    }

    function _verifyPostUpgradeState() internal {
        ITokenizedStrategy newStrategy = ITokenizedStrategy(address(usd3Proxy));
        USD3 newUSD3 = USD3(address(usd3Proxy));

        // Verify asset is now USDC
        assertEq(address(newStrategy.asset()), USDC_ADDRESS, "Asset not switched to USDC");

        // Verify total supply unchanged
        assertEq(newStrategy.totalSupply(), totalSupplyBefore, "Total supply changed");

        // Verify total assets preserved (within rounding)
        assertApproxEqAbs(
            newStrategy.totalAssets(),
            totalAssetsBefore,
            users.length, // 1 wei per user max rounding
            "Total assets not preserved"
        );

        // Verify user shares exactly preserved
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            assertEq(newStrategy.balanceOf(user), preUpgradeShares[user], "User shares changed");
        }

        // Verify waUSDC approval is set
        assertEq(
            IERC20(USDC_ADDRESS).allowance(address(usd3Proxy), address(waUSDC)),
            type(uint256).max,
            "waUSDC approval not set"
        );

        // Verify waUSDC balance preserved or increased (from wrapping)
        uint256 totalWaUSDC = newUSD3.balanceOfWaUSDC() + newUSD3.suppliedWaUSDC();
        assertGe(totalWaUSDC, waUSDCBalanceBefore, "waUSDC position reduced");
    }

    /*//////////////////////////////////////////////////////////////
                            TEST CASES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test basic upgrade flow with multiple users
     */
    function test_basicUpgradeWithThreeUsers() public {
        // Have users deposit into old strategy (waUSDC-based)
        vm.startPrank(alice);
        waUSDC.approve(address(usd3Proxy), 1000e6);
        ITokenizedStrategy(address(usd3Proxy)).deposit(1000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        waUSDC.approve(address(usd3Proxy), 2000e6);
        ITokenizedStrategy(address(usd3Proxy)).deposit(2000e6, bob);
        vm.stopPrank();

        vm.startPrank(charlie);
        waUSDC.approve(address(usd3Proxy), 500e6);
        ITokenizedStrategy(address(usd3Proxy)).deposit(500e6, charlie);
        vm.stopPrank();

        // Capture state before upgrade
        _capturePreUpgradeState();

        // Log pre-upgrade state
        console2.log("Pre-upgrade state:");
        console2.log("  Total supply:", totalSupplyBefore);
        console2.log("  Total assets:", totalAssetsBefore);
        console2.log("  Alice shares:", preUpgradeShares[alice]);
        console2.log("  Bob shares:", preUpgradeShares[bob]);
        console2.log("  Charlie shares:", preUpgradeShares[charlie]);

        // Perform upgrade
        _performUpgrade();

        // Verify post-upgrade state
        _verifyPostUpgradeState();

        console2.log("Upgrade successful - all shares and assets preserved!");
    }

    /**
     * @notice Test upgrade with non-1:1 waUSDC share price
     */
    function test_upgradeWithNonOneToOneSharePrice() public {
        // Set waUSDC share price to 1.1:1 (10% yield accumulated)
        waUSDC.setSharePrice(1.1e6);

        // Have users deposit at different share prices
        vm.startPrank(alice);
        waUSDC.approve(address(usd3Proxy), 1000e6);
        ITokenizedStrategy(address(usd3Proxy)).deposit(1000e6, alice);
        vm.stopPrank();

        // Simulate more yield
        waUSDC.simulateYield(500); // 5% additional yield

        vm.startPrank(bob);
        waUSDC.approve(address(usd3Proxy), 2000e6);
        ITokenizedStrategy(address(usd3Proxy)).deposit(2000e6, bob);
        vm.stopPrank();

        // Capture and perform upgrade
        _capturePreUpgradeState();
        _performUpgrade();
        _verifyPostUpgradeState();

        // Verify users can still withdraw expected amounts
        ITokenizedStrategy newStrategy = ITokenizedStrategy(address(usd3Proxy));

        vm.startPrank(alice);
        uint256 aliceShares = newStrategy.balanceOf(alice);
        uint256 aliceAssets = newStrategy.redeem(aliceShares, alice, alice);
        assertGe(aliceAssets, 950e6, "Alice withdrawal too low"); // Allow for some rounding
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobShares = newStrategy.balanceOf(bob);
        uint256 bobAssets = newStrategy.redeem(bobShares, bob, bob);
        assertGe(bobAssets, 1900e6, "Bob withdrawal too low");
        vm.stopPrank();
    }

    /**
     * @notice Test that shares are exactly preserved during upgrade
     */
    function test_upgradePreservesExactShares() public {
        // Multiple deposits
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1000e6;
        amounts[1] = 2000e6;
        amounts[2] = 500e6;
        amounts[3] = 10000e6;

        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            waUSDC.approve(address(usd3Proxy), amounts[i]);
            ITokenizedStrategy(address(usd3Proxy)).deposit(amounts[i], users[i]);
            vm.stopPrank();
        }

        _capturePreUpgradeState();
        _performUpgrade();

        // Verify exact share preservation
        ITokenizedStrategy newStrategy = ITokenizedStrategy(address(usd3Proxy));
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 sharesBefore = preUpgradeShares[user];
            uint256 sharesAfter = newStrategy.balanceOf(user);
            assertEq(sharesAfter, sharesBefore, "Shares not exactly preserved");
        }
    }

    /**
     * @notice Test that new USDC deposits work after upgrade
     */
    function test_postUpgradeUSDCDeposits() public {
        // Initial deposit with old strategy
        vm.startPrank(alice);
        waUSDC.approve(address(usd3Proxy), 1000e6);
        ITokenizedStrategy(address(usd3Proxy)).deposit(1000e6, alice);
        vm.stopPrank();

        // Perform upgrade
        _capturePreUpgradeState();
        _performUpgrade();
        _verifyPostUpgradeState();

        // New user should be able to deposit USDC (not waUSDC)
        address newUser = makeAddr("newUser");
        airdrop(asset, newUser, 500e6);

        vm.startPrank(newUser);
        asset.approve(address(usd3Proxy), 500e6);
        uint256 newShares = ITokenizedStrategy(address(usd3Proxy)).deposit(500e6, newUser);
        vm.stopPrank();

        assertGt(newShares, 0, "No shares minted for new deposit");
        assertEq(asset.balanceOf(newUser), 0, "USDC not taken from new user");

        // Verify new deposit was wrapped to waUSDC internally
        USD3 newUSD3 = USD3(address(usd3Proxy));
        uint256 totalWaUSDC = newUSD3.balanceOfWaUSDC() + newUSD3.suppliedWaUSDC();
        assertGe(totalWaUSDC, waUSDCBalanceBefore + 500e6, "New deposit not wrapped to waUSDC");
    }

    /**
     * @notice Test that withdrawals return USDC after upgrade
     */
    function test_postUpgradeWithdrawals() public {
        // Setup deposits
        vm.startPrank(alice);
        waUSDC.approve(address(usd3Proxy), 1000e6);
        ITokenizedStrategy(address(usd3Proxy)).deposit(1000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        waUSDC.approve(address(usd3Proxy), 2000e6);
        ITokenizedStrategy(address(usd3Proxy)).deposit(2000e6, bob);
        vm.stopPrank();

        // Upgrade
        _capturePreUpgradeState();
        _performUpgrade();
        _verifyPostUpgradeState();

        // Alice withdraws - should receive USDC
        ITokenizedStrategy newStrategy = ITokenizedStrategy(address(usd3Proxy));

        uint256 aliceUSDCBefore = asset.balanceOf(alice);
        vm.startPrank(alice);
        uint256 aliceShares = newStrategy.balanceOf(alice);
        uint256 withdrawn = newStrategy.redeem(aliceShares, alice, alice);
        vm.stopPrank();

        assertEq(asset.balanceOf(alice), aliceUSDCBefore + withdrawn, "USDC not received");
        assertEq(waUSDC.balanceOf(alice), 0, "Should not receive waUSDC");
        assertApproxEqAbs(withdrawn, 1000e6, 2, "Withdrawal amount incorrect");
    }

    /**
     * @notice Test partial withdrawals before and after upgrade
     */
    function test_partialWithdrawalsAcrossUpgrade() public {
        // Alice deposits
        vm.startPrank(alice);
        waUSDC.approve(address(usd3Proxy), 1000e6);
        ITokenizedStrategy(address(usd3Proxy)).deposit(1000e6, alice);

        // Alice withdraws 30% before upgrade
        uint256 aliceShares = ITokenizedStrategy(address(usd3Proxy)).balanceOf(alice);
        uint256 withdrawShares = aliceShares * 30 / 100;
        ITokenizedStrategy(address(usd3Proxy)).redeem(withdrawShares, alice, alice);
        vm.stopPrank();

        // Bob deposits
        vm.startPrank(bob);
        waUSDC.approve(address(usd3Proxy), 2000e6);
        ITokenizedStrategy(address(usd3Proxy)).deposit(2000e6, bob);
        vm.stopPrank();

        // Upgrade
        _capturePreUpgradeState();
        _performUpgrade();
        _verifyPostUpgradeState();

        // Alice withdraws remaining 70% after upgrade
        ITokenizedStrategy newStrategy = ITokenizedStrategy(address(usd3Proxy));

        vm.startPrank(alice);
        uint256 remainingShares = newStrategy.balanceOf(alice);
        uint256 finalWithdraw = newStrategy.redeem(remainingShares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(finalWithdraw, 700e6, 2, "Final withdrawal incorrect");

        // Bob withdraws 50% after upgrade
        vm.startPrank(bob);
        uint256 bobShares = newStrategy.balanceOf(bob);
        uint256 bobWithdraw = newStrategy.redeem(bobShares / 2, bob, bob);
        vm.stopPrank();

        assertApproxEqAbs(bobWithdraw, 1000e6, 2, "Bob partial withdrawal incorrect");
    }

    /**
     * @notice Test upgrade with active Morpho positions
     */
    function test_upgradeWithActiveMorphoPosition() public {
        // Deposit and deploy funds to Morpho
        vm.startPrank(alice);
        waUSDC.approve(address(usd3Proxy), 1000e6);
        ITokenizedStrategy(address(usd3Proxy)).deposit(1000e6, alice);
        vm.stopPrank();

        // Set maxOnCredit to deploy funds
        setMaxOnCredit(8000); // 80% deployment

        // Trigger deployment
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Proxy)).tend();

        // Verify funds deployed
        USD3_old oldUSD3 = USD3_old(address(usd3Proxy));
        USD3 setupStrategy = USD3(address(strategy));
        uint256 morphoSharesBeforeUpgrade =
            setupStrategy.morphoCredit().position(oldUSD3.marketId(), address(usd3Proxy)).supplyShares;
        assertGt(morphoSharesBeforeUpgrade, 0, "No Morpho position before upgrade");

        // Upgrade
        _capturePreUpgradeState();
        _performUpgrade();
        _verifyPostUpgradeState();

        // Verify Morpho position maintained
        USD3 newUSD3 = USD3(address(usd3Proxy));
        uint256 morphoSharesAfter =
            setupStrategy.morphoCredit().position(newUSD3.marketId(), address(usd3Proxy)).supplyShares;
        assertEq(morphoSharesAfter, morphoSharesBeforeUpgrade, "Morpho position changed");
    }

    /**
     * @notice Test upgrade with empty strategy (no deposits)
     */
    function test_emptyStrategyUpgrade() public {
        // Don't make any deposits

        _capturePreUpgradeState();
        assertEq(totalSupplyBefore, 0, "Should have no supply");
        assertEq(totalAssetsBefore, 0, "Should have no assets");

        _performUpgrade();
        _verifyPostUpgradeState();

        // Verify new deposits work
        address newUser = makeAddr("newUser");
        airdrop(asset, newUser, 1000e6);

        vm.startPrank(newUser);
        asset.approve(address(usd3Proxy), 1000e6);
        uint256 shares = ITokenizedStrategy(address(usd3Proxy)).deposit(1000e6, newUser);
        vm.stopPrank();

        assertGt(shares, 0, "Should mint shares for new deposit");
    }

    /**
     * @notice Test upgrade with single whale depositor
     */
    function test_singleWhaleUpgrade() public {
        // Only whale deposits
        vm.startPrank(whale);
        waUSDC.approve(address(usd3Proxy), 10000e6);
        ITokenizedStrategy(address(usd3Proxy)).deposit(10000e6, whale);
        vm.stopPrank();

        _capturePreUpgradeState();
        _performUpgrade();
        _verifyPostUpgradeState();

        // Whale should be able to withdraw everything
        ITokenizedStrategy newStrategy = ITokenizedStrategy(address(usd3Proxy));

        vm.startPrank(whale);
        uint256 whaleShares = newStrategy.balanceOf(whale);
        uint256 withdrawn = newStrategy.redeem(whaleShares, whale, whale);
        vm.stopPrank();

        assertApproxEqAbs(withdrawn, 10000e6, 2, "Whale withdrawal incorrect");
        assertEq(newStrategy.totalSupply(), 0, "Should have no supply after whale exit");
    }

    /**
     * @notice Test upgrade with many small depositors
     */
    function test_manySmallUsersUpgrade() public {
        // Create 20 small users
        address[] memory smallUsers = new address[](20);
        for (uint256 i = 0; i < 20; i++) {
            smallUsers[i] = makeAddr(string(abi.encodePacked("user", i)));

            // Fund with small amount of USDC and wrap to waUSDC
            airdrop(asset, smallUsers[i], 10e6);
            vm.startPrank(smallUsers[i]);
            asset.approve(address(waUSDC), 10e6);
            waUSDC.deposit(10e6, smallUsers[i]);

            // Deposit into strategy
            waUSDC.approve(address(usd3Proxy), 10e6);
            ITokenizedStrategy(address(usd3Proxy)).deposit(10e6, smallUsers[i]);
            vm.stopPrank();
        }

        // Also include original users for variety
        users = smallUsers;

        _capturePreUpgradeState();
        _performUpgrade();
        _verifyPostUpgradeState();

        // Verify a few users can withdraw
        ITokenizedStrategy newStrategy = ITokenizedStrategy(address(usd3Proxy));
        for (uint256 i = 0; i < 5; i++) {
            vm.startPrank(smallUsers[i]);
            uint256 shares = newStrategy.balanceOf(smallUsers[i]);
            uint256 withdrawn = newStrategy.redeem(shares, smallUsers[i], smallUsers[i]);
            vm.stopPrank();

            assertApproxEqAbs(withdrawn, 10e6, 2, "Small user withdrawal incorrect");
        }
    }
}
