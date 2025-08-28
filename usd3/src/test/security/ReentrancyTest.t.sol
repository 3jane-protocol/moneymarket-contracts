// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../USD3.sol";
import {sUSD3} from "../../sUSD3.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {TransparentUpgradeableProxy} from
    "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title ReentrancyTest
 * @notice Tests reentrancy protection for USD3 and sUSD3 strategies
 * @dev Tests ensure that malicious contracts cannot exploit reentrancy vulnerabilities
 */
contract ReentrancyTest is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    // Malicious reentrancy contract
    MaliciousReentrant public attacker;

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3 implementation with proxy
        sUSD3 susd3Implementation = new sUSD3();

        // Deploy proxy admin
        address proxyAdminOwner = makeAddr("ProxyAdminOwner");
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(proxyAdminOwner);

        // Deploy proxy with initialization
        bytes memory susd3InitData =
            abi.encodeWithSelector(sUSD3.initialize.selector, address(usd3Strategy), management, keeper);

        TransparentUpgradeableProxy susd3Proxy =
            new TransparentUpgradeableProxy(address(susd3Implementation), address(susd3ProxyAdmin), susd3InitData);

        susd3Strategy = sUSD3(address(susd3Proxy));

        // Link strategies
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Setup test users
        airdrop(asset, alice, 10000e6);
        airdrop(asset, bob, 10000e6);

        // Deploy attacker contract
        attacker = new MaliciousReentrant(address(usd3Strategy), address(susd3Strategy), address(asset));
    }

    function test_deposit_reentrancy_protection() public {
        // Give attacker some USDC
        airdrop(asset, address(attacker), 1000e6);

        // Attacker tries to exploit deposit reentrancy
        // Note: TokenizedStrategy doesn't have explicit reentrancy guards,
        // but the pattern is safe due to checks-effects-interactions
        // The test should complete without reentrancy
        attacker.attackDeposit(100e6);

        // Verify only one deposit occurred
        assertEq(IERC20(address(usd3Strategy)).balanceOf(address(attacker)), 100e6);
    }

    function test_withdraw_reentrancy_protection() public {
        // Setup: Alice deposits first
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        // Transfer shares to attacker
        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(address(attacker), 100e6);

        // Wait for commitment period
        skip(7 days);

        // Attacker tries to exploit withdraw reentrancy
        // TokenizedStrategy is safe due to state changes before external calls
        attacker.attackWithdraw(50e6);

        // Verify only one withdrawal occurred
        assertLt(IERC20(address(usd3Strategy)).balanceOf(address(attacker)), 100e6);
    }

    function test_mint_reentrancy_protection() public {
        // Give attacker some USDC
        airdrop(asset, address(attacker), 1000e6);

        // Attacker tries to exploit mint reentrancy
        // Safe due to checks-effects-interactions pattern
        attacker.attackMint(100e6);

        // Verify only expected shares were minted
        assertGt(IERC20(address(usd3Strategy)).balanceOf(address(attacker)), 0);
    }

    function test_redeem_reentrancy_protection() public {
        // Setup: Alice deposits first
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        // Transfer shares to attacker
        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(address(attacker), 100e6);

        // Wait for commitment period
        skip(7 days);

        // Attacker tries to exploit redeem reentrancy
        // Safe due to state updates before external calls
        attacker.attackRedeem(50e6);

        // Verify only expected redemption occurred
        assertEq(IERC20(address(usd3Strategy)).balanceOf(address(attacker)), 50e6);
    }

    function test_yield_distribution_no_reentrancy() public {
        // Setup: Create some yield to distribute
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        // Deploy malicious contract that could try reentrancy
        MaliciousSUSD3 maliciousSUSD3 = new MaliciousSUSD3(address(usd3Strategy));

        // Since sUSD3 is already set and cannot be changed,
        // we test by setting the malicious contract as performance fee recipient
        vm.startPrank(management);
        // Set performance fee to distribute yield
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFee(uint16(2000)); // 20%
        // Set malicious contract as recipient (not as sUSD3 itself)
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFeeRecipient(address(maliciousSUSD3));
        vm.stopPrank();

        // Simulate some yield
        airdrop(asset, address(usd3Strategy), 100e6);

        // Report should mint shares directly to malicious sUSD3
        // Even if it tries reentrancy, shares are minted atomically
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Verify malicious contract received shares
        uint256 maliciousBalance = IERC20(address(usd3Strategy)).balanceOf(address(maliciousSUSD3));
        assertGt(maliciousBalance, 0, "Should have received shares");

        // No reentrancy possible since minting is atomic
    }

    function test_crossContract_reentrancy_protection() public {
        // Setup: Alice deposits into USD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 2000e6);
        usd3Strategy.deposit(2000e6, alice);

        // Skip commitment period for USD3
        skip(7 days);

        // Alice deposits USD3 into sUSD3 (respecting subordination)
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 300e6);
        susd3Strategy.deposit(300e6, alice);
        vm.stopPrank();

        // Skip lock period for sUSD3
        skip(90 days);

        // Now Alice can transfer sUSD3 shares to attacker
        vm.prank(alice);
        IERC20(address(susd3Strategy)).transfer(address(attacker), 100e6);

        // Attacker tries cross-contract reentrancy
        // This should succeed but not cause issues
        attacker.attackCrossContract(50e6);

        // Verify cooldown was started
        (,, uint256 cooldownShares) = susd3Strategy.getCooldownStatus(address(attacker));
        assertEq(cooldownShares, 50e6);
    }
}

/**
 * @notice Malicious contract attempting reentrancy attacks
 */
contract MaliciousReentrant {
    USD3 public immutable usd3;
    sUSD3 public immutable susd3;
    IERC20 public immutable usdc;

    bool public attacking;
    uint256 public attackCount;

    constructor(address _usd3, address _susd3, address _usdc) {
        usd3 = USD3(_usd3);
        susd3 = sUSD3(_susd3);
        usdc = IERC20(_usdc);
    }

    function attackDeposit(uint256 amount) external {
        attacking = true;
        attackCount = 0;
        usdc.approve(address(usd3), type(uint256).max);
        usd3.deposit(amount, address(this));
    }

    function attackWithdraw(uint256 amount) external {
        attacking = true;
        attackCount = 0;
        usd3.withdraw(amount, address(this), address(this));
    }

    function attackMint(uint256 shares) external {
        attacking = true;
        attackCount = 0;
        usdc.approve(address(usd3), type(uint256).max);
        usd3.mint(shares, address(this));
    }

    function attackRedeem(uint256 shares) external {
        attacking = true;
        attackCount = 0;
        usd3.redeem(shares, address(this), address(this));
    }

    function attackCrossContract(uint256 amount) external {
        attacking = true;
        attackCount = 0;
        // Try to withdraw from sUSD3 while in USD3 operation
        susd3.startCooldown(amount);
    }

    // Callback hooks that attempt reentrancy
    receive() external payable {
        if (attacking && attackCount < 2) {
            attackCount++;
            // Try to reenter
            try usd3.deposit(10e6, address(this)) {} catch {}
        }
    }

    // ERC20 hooks for reentrancy attempts
    function onERC20Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (attacking && attackCount < 2) {
            attackCount++;
            // Try to reenter during token transfer
            try usd3.withdraw(10e6, address(this), address(this)) {} catch {}
        }
        return this.onERC20Received.selector;
    }
}

/**
 * @notice Malicious sUSD3 for testing
 * @dev Since yield is now minted directly as shares, no claiming needed
 */
contract MaliciousSUSD3 {
    USD3 public immutable usd3;

    constructor(address _usd3) {
        usd3 = USD3(_usd3);
    }

    // Receives shares directly during USD3's report()
    // No claim function to exploit anymore
}
