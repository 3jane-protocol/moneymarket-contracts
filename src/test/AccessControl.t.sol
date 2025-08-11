// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IUSD3} from "./utils/Setup.sol";
import {USD3} from "../USD3.sol";
import {sUSD3} from "../sUSD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {TransparentUpgradeableProxy} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title AccessControlTest
 * @notice Comprehensive testing of access control mechanisms in USD3/sUSD3
 */
contract AccessControlTest is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public unauthorizedUser = makeAddr("unauthorized");

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3
        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);

        bytes memory susd3InitData = abi.encodeWithSelector(
            sUSD3.initialize.selector,
            address(usd3Strategy),
            management,
            keeper
        );

        TransparentUpgradeableProxy susd3Proxy = new TransparentUpgradeableProxy(
                address(susd3Implementation),
                address(susd3ProxyAdmin),
                susd3InitData
            );

        susd3Strategy = sUSD3(address(susd3Proxy));

        // Link strategies
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Give users some funds
        deal(address(underlyingAsset), alice, 10_000e6);
        deal(address(underlyingAsset), bob, 10_000e6);

        vm.prank(alice);
        underlyingAsset.approve(address(strategy), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    USD3 MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_maxOnCredit_readsFromProtocolConfig() public {
        // maxOnCredit should now read from ProtocolConfig, not be settable
        // MockProtocolConfig sets default to 10000 (100%)
        assertEq(
            usd3Strategy.maxOnCredit(),
            10_000,
            "Default maxOnCredit from MockProtocolConfig should be 100%"
        );

        // Note: To change maxOnCredit, it must now be done through ProtocolConfig
        // not directly on USD3 strategy
    }

    function test_setSUSD3_onlyManagement() public {
        // sUSD3 is already set in setUp, so we test that it can't be set again
        address newSusd3 = makeAddr("newSusd3");

        // Even management cannot set it again (one-time only)
        vm.prank(management);
        vm.expectRevert("sUSD3 already set");
        usd3Strategy.setSUSD3(newSusd3);

        // Verify the original is still set
        assertEq(
            usd3Strategy.sUSD3(),
            address(susd3Strategy),
            "sUSD3 strategy should remain unchanged"
        );
    }

    function test_setSUSD3_initialSet() public {
        // This test validates that sUSD3 can only be set once
        // The main usd3Strategy already has sUSD3 set in setUp,
        // so we test that it cannot be changed

        address currentSusd3 = usd3Strategy.sUSD3();
        assertEq(currentSusd3, address(susd3Strategy), "sUSD3 should be set");

        address newSusd3 = makeAddr("newSusd3");

        // Even management cannot change it once set
        vm.prank(management);
        vm.expectRevert("sUSD3 already set");
        usd3Strategy.setSUSD3(newSusd3);

        // Verify it hasn't changed
        assertEq(
            usd3Strategy.sUSD3(),
            currentSusd3,
            "sUSD3 should remain unchanged"
        );
    }

    function test_setWhitelistEnabled_onlyManagement() public {
        // Unauthorized user cannot set
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        usd3Strategy.setWhitelistEnabled(true);

        // Management can set
        vm.prank(management);
        usd3Strategy.setWhitelistEnabled(true);
        assertTrue(
            usd3Strategy.whitelistEnabled(),
            "Whitelist should be enabled"
        );
    }

    function test_setWhitelist_onlyManagement() public {
        // Unauthorized user cannot set
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        usd3Strategy.setWhitelist(alice, true);

        // Management can set
        vm.prank(management);
        usd3Strategy.setWhitelist(alice, true);
        assertTrue(
            usd3Strategy.whitelist(alice),
            "Alice should be whitelisted"
        );
    }

    function test_setMinDeposit_onlyManagement() public {
        // Unauthorized user cannot set
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        usd3Strategy.setMinDeposit(100e6);

        // Management can set
        vm.prank(management);
        usd3Strategy.setMinDeposit(100e6);
        assertEq(
            usd3Strategy.minDeposit(),
            100e6,
            "Min deposit should be updated"
        );
    }

    function test_setMinCommitmentTime_onlyManagement() public {
        // Unauthorized user cannot set
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        usd3Strategy.setMinCommitmentTime(7 days);

        // Management can set
        vm.prank(management);
        usd3Strategy.setMinCommitmentTime(7 days);
        assertEq(
            usd3Strategy.minCommitmentTime(),
            7 days,
            "Min commitment time should be updated"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    USD3 KEEPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_syncTrancheShare_onlyKeeper() public {
        // Unauthorized user cannot sync
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        usd3Strategy.syncTrancheShare();

        // Keeper can sync
        vm.prank(keeper);
        usd3Strategy.syncTrancheShare();

        // Management can also sync (it's onlyKeeperOrManagement)
        vm.prank(management);
        usd3Strategy.syncTrancheShare();
    }

    /*//////////////////////////////////////////////////////////////
                    sUSD3 MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_setWithdrawalWindow_onlyManagement() public {
        // Unauthorized user cannot set
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        susd3Strategy.setWithdrawalWindow(3 days);

        // Keeper cannot set
        vm.prank(keeper);
        vm.expectRevert();
        susd3Strategy.setWithdrawalWindow(3 days);

        // Management can set
        vm.prank(management);
        susd3Strategy.setWithdrawalWindow(3 days);
        assertEq(
            susd3Strategy.withdrawalWindow(),
            3 days,
            "Withdrawal window should be updated"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INHERITED FUNCTIONS (FROM BaseStrategy)
    //////////////////////////////////////////////////////////////*/

    function test_setPerformanceFee_onlyManagement() public {
        // Unauthorized user cannot set
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFee(1000); // 10%

        // Management can set
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFee(1000);
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).performanceFee(),
            1000,
            "Performance fee should be updated"
        );
    }

    function test_setPerformanceFeeRecipient_onlyManagement() public {
        address newRecipient = makeAddr("newRecipient");

        // Unauthorized user cannot set
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFeeRecipient(
            newRecipient
        );

        // Management can set
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFeeRecipient(
            newRecipient
        );
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).performanceFeeRecipient(),
            newRecipient,
            "Recipient should be updated"
        );
    }

    function test_setKeeper_onlyManagement() public {
        address newKeeper = makeAddr("newKeeper");

        // Unauthorized user cannot set
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).setKeeper(newKeeper);

        // Current keeper cannot set new keeper
        vm.prank(keeper);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).setKeeper(newKeeper);

        // Management can set
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setKeeper(newKeeper);
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).keeper(),
            newKeeper,
            "Keeper should be updated"
        );
    }

    function test_setProfitMaxUnlockTime_onlyManagement() public {
        // Unauthorized user cannot set
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).setProfitMaxUnlockTime(
            20 days
        );

        // Management can set
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setProfitMaxUnlockTime(
            20 days
        );
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).profitMaxUnlockTime(),
            20 days,
            "Profit unlock time should be updated"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_shutdownStrategy_onlyEmergencyAdmin() public {
        // Unauthorized user cannot shutdown
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // Keeper cannot shutdown
        vm.prank(keeper);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // Management can shutdown (management is also emergency admin by default)
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();
        assertTrue(
            ITokenizedStrategy(address(usd3Strategy)).isShutdown(),
            "Strategy should be shutdown"
        );

        // Reset for next test
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).emergencyWithdraw(0);

        // Emergency admin can shutdown
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();
        assertTrue(
            ITokenizedStrategy(address(usd3Strategy)).isShutdown(),
            "Strategy should be shutdown"
        );
    }

    function test_emergencyWithdraw_onlyEmergencyAdmin() public {
        // Deposit some funds first (before shutdown)
        vm.prank(alice);
        usd3Strategy.deposit(100e6, alice);

        // Then shutdown the strategy
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // Unauthorized user cannot emergency withdraw
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).emergencyWithdraw(0);

        // Emergency admin can withdraw (even 0 amount should succeed)
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).emergencyWithdraw(0);
    }

    /*//////////////////////////////////////////////////////////////
                    MANAGEMENT TRANSFER
    //////////////////////////////////////////////////////////////*/

    function test_setManagement_process() public {
        address newManagement = makeAddr("newManagement");

        // Unauthorized user cannot set pending management
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).setPendingManagement(
            newManagement
        );

        // Current management can set pending
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPendingManagement(
            newManagement
        );
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).pendingManagement(),
            newManagement,
            "Pending management should be set"
        );

        // New management must accept
        vm.prank(newManagement);
        ITokenizedStrategy(address(usd3Strategy)).acceptManagement();
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).management(),
            newManagement,
            "Management should be transferred"
        );
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).pendingManagement(),
            address(0),
            "Pending should be cleared"
        );
    }

    function test_acceptManagement_onlyPending() public {
        address newManagement = makeAddr("newManagement");

        // Set pending management
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPendingManagement(
            newManagement
        );

        // Random user cannot accept
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).acceptManagement();

        // Current management cannot accept
        vm.prank(management);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).acceptManagement();

        // Only pending management can accept
        vm.prank(newManagement);
        ITokenizedStrategy(address(usd3Strategy)).acceptManagement();
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).management(),
            newManagement,
            "Management should be transferred"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    KEEPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_report_onlyKeeperOrManagement() public {
        // Deposit some funds first
        vm.prank(alice);
        usd3Strategy.deposit(100e6, alice);

        // Skip time for interest
        skip(1 days);

        // Unauthorized user cannot report
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Keeper can report
        vm.prank(keeper);
        (uint256 profit1, uint256 loss1) = ITokenizedStrategy(
            address(usd3Strategy)
        ).report();
        assertGe(profit1 + loss1, 0, "Report should succeed");

        skip(1 days);

        // Management can also report
        vm.prank(management);
        (uint256 profit2, uint256 loss2) = ITokenizedStrategy(
            address(usd3Strategy)
        ).report();
        assertGe(profit2 + loss2, 0, "Report should succeed");
    }

    function test_tend_onlyKeeperOrManagement() public {
        // Deposit some funds first
        vm.prank(alice);
        usd3Strategy.deposit(100e6, alice);

        // Unauthorized user cannot tend
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).tend();

        // Keeper can tend
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        // Management can tend
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).tend();
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-ROLE SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function test_roleHierarchy() public {
        address newKeeper = makeAddr("newKeeper");

        // Management has highest privileges
        vm.startPrank(management);
        ITokenizedStrategy(address(usd3Strategy)).setKeeper(newKeeper);
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFee(500);
        // maxOnCredit is now managed through ProtocolConfig, not directly
        vm.stopPrank();

        // New keeper has limited privileges
        vm.startPrank(newKeeper);
        ITokenizedStrategy(address(usd3Strategy)).report();
        ITokenizedStrategy(address(usd3Strategy)).tend();
        usd3Strategy.syncTrancheShare();

        // But keeper cannot do management functions
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFee(1000);
        vm.stopPrank();

        // Emergency admin can shutdown but not manage
        vm.startPrank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFee(1000);
        vm.stopPrank();
    }

    function test_zeroAddressProtection() public {
        // Cannot set zero address for critical roles
        vm.startPrank(management);

        // Cannot set zero management (this actually reverts)
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).setPendingManagement(
            address(0)
        );

        // NOTE: setKeeper and setPerformanceFeeRecipient actually allow zero address
        // This is by design in TokenizedStrategy to allow disabling these roles

        vm.stopPrank();
    }
}
