// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../../lib/forge-std/src/Test.sol";
import "../../../lib/forge-std/src/console.sol";

import {Helper} from "../../../src/Helper.sol";
import {IHelper} from "../../../src/interfaces/IHelper.sol";
import {IERC4626} from "../../../lib/forge-std/src/interfaces/IERC4626.sol";
import {IMorpho, IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {MarketParams} from "../../../src/interfaces/IMorpho.sol";
import {IERC20} from "../../../src/interfaces/IERC20.sol";

import {BaseTest} from "../BaseTest.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "../../../src/libraries/periphery/MorphoLib.sol";
import {Position, Id, Market} from "../../../src/interfaces/IMorpho.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {TransparentUpgradeableProxy} from
    "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

// Mock contracts for dependencies with price per share functionality
contract USD3Mock is IERC4626 {
    uint256 public pricePerShare = 1e18; // Default 1:1 ratio
    ERC20Mock public underlying; // waUSDC

    // ERC20 state
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Whitelist functionality for USD3
    mapping(address => bool) public whitelist;
    bool public whitelistEnabled = false;

    function setUnderlying(address _underlying) external {
        underlying = ERC20Mock(_underlying);
    }

    function setPricePerShare(uint256 _pricePerShare) external {
        pricePerShare = _pricePerShare;
    }

    // Whitelist management functions
    function setWhitelist(address user, bool allowed) external {
        whitelist[user] = allowed;
    }

    function setWhitelistEnabled(bool enabled) external {
        whitelistEnabled = enabled;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        // Calculate shares based on price per share
        uint256 shares = (assets * 1e18) / pricePerShare;
        _mint(receiver, shares);

        // Transfer underlying assets (waUSDC) to this contract
        if (address(underlying) != address(0)) {
            underlying.transferFrom(msg.sender, address(this), assets);
        }

        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        // Check if caller has permission to redeem owner's shares
        if (msg.sender != owner) {
            require(allowance[owner][msg.sender] >= shares, "insufficient allowance");
            allowance[owner][msg.sender] -= shares;
        }

        require(balanceOf[owner] >= shares, "insufficient shares");
        uint256 assets = (shares * pricePerShare) / 1e18;
        _burn(owner, shares);

        // Transfer underlying assets (waUSDC) to receiver
        if (address(underlying) != address(0)) {
            underlying.transfer(receiver, assets);
        }

        return assets;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // Additional ERC4626 functions required by the interface
    function asset() external view returns (address) {
        return address(underlying);
    }

    function totalAssets() external view returns (uint256) {
        return address(underlying) != address(0) ? underlying.balanceOf(address(this)) : 0;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / pricePerShare;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * pricePerShare) / 1e18;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / pricePerShare;
    }

    function mint(uint256 shares, address receiver) external returns (uint256) {
        uint256 assets = (shares * pricePerShare) / 1e18;
        if (address(underlying) != address(0)) {
            underlying.transferFrom(msg.sender, address(this), assets);
        }
        _mint(receiver, shares);
        return assets;
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return (shares * pricePerShare) / 1e18;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256) {
        uint256 shares = (assets * 1e18) / pricePerShare;
        if (msg.sender != owner) {
            require(allowance[owner][msg.sender] >= shares, "insufficient allowance");
            allowance[owner][msg.sender] -= shares;
        }
        require(balanceOf[owner] >= shares, "insufficient shares");
        _burn(owner, shares);
        if (address(underlying) != address(0)) {
            underlying.transfer(receiver, assets);
        }
        return shares;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return (balanceOf[owner] * pricePerShare) / 1e18;
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / pricePerShare;
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf[owner];
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return (shares * pricePerShare) / 1e18;
    }

    // ERC20 metadata (required by IERC4626 which extends IERC20)
    function name() external pure returns (string memory) {
        return "USD3 Mock";
    }

    function symbol() external pure returns (string memory) {
        return "USD3";
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }

    // ERC20 functions
    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    // Helper function to set balance for testing
    function setBalance(address account, uint256 amount) public {
        if (amount > balanceOf[account]) totalSupply += amount - balanceOf[account];
        else totalSupply -= balanceOf[account] - amount;
        balanceOf[account] = amount;
    }
}

contract WrapMock is IERC4626 {
    ERC20Mock public immutable underlying;
    uint256 public pricePerShare = 1e18; // Default 1:1 ratio

    // ERC20 state
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address _underlying) {
        underlying = ERC20Mock(_underlying);
    }

    // ERC20 metadata functions
    function name() external pure returns (string memory) {
        return "Wrapped Asset USDC";
    }

    function symbol() external pure returns (string memory) {
        return "waUSDC";
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function setPricePerShare(uint256 _pricePerShare) external {
        pricePerShare = _pricePerShare;
    }

    // Helper function to set balance for testing
    function setBalance(address account, uint256 amount) public {
        if (amount > balanceOf[account]) totalSupply += amount - balanceOf[account];
        else totalSupply -= balanceOf[account] - amount;
        balanceOf[account] = amount;
    }

    // ERC20 functions
    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    // IERC4626 functions
    function asset() external view returns (address) {
        return address(underlying);
    }

    function totalAssets() external view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / pricePerShare;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * pricePerShare) / 1e18;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / pricePerShare;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        // Transfer underlying tokens from caller
        underlying.transferFrom(msg.sender, address(this), assets);
        // Calculate shares based on price per share
        uint256 shares = (assets * 1e18) / pricePerShare;
        _mint(receiver, shares);
        return shares;
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return (shares * pricePerShare) / 1e18;
    }

    function mint(uint256 shares, address receiver) external returns (uint256) {
        uint256 assets = (shares * pricePerShare) / 1e18;
        underlying.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        return assets;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return (balanceOf[owner] * pricePerShare) / 1e18;
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / pricePerShare;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256) {
        uint256 shares = (assets * 1e18) / pricePerShare;
        require(balanceOf[owner] >= shares, "insufficient wrapped balance");
        _burn(owner, shares);
        // Transfer underlying tokens to receiver
        underlying.transfer(receiver, assets);
        return shares;
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf[owner];
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return (shares * pricePerShare) / 1e18;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        require(balanceOf[owner] >= shares, "insufficient balance");
        uint256 assets = (shares * pricePerShare) / 1e18;
        _burn(owner, shares);
        underlying.transfer(receiver, assets);
        return assets;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}

contract MorphoMock {
    ERC20Mock public loanToken;
    ERC20Mock public collateralToken;

    function setTokens(address _loanToken, address _collateralToken) external {
        loanToken = ERC20Mock(_loanToken);
        collateralToken = ERC20Mock(_collateralToken);
    }

    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        // Simulate borrow by transferring loan tokens to receiver
        // The receiver is Helper, not the user
        if (marketParams.loanToken != address(0)) {
            // Cast to our mock interface that has transfer
            WrapMock(marketParams.loanToken).transfer(receiver, assets);
        }
        return (assets, shares);
    }

    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        // Simulate repay by transferring loan tokens from msg.sender to this contract
        // Use the loanToken from marketParams
        if (marketParams.loanToken != address(0)) {
            ERC20Mock(marketParams.loanToken).transferFrom(msg.sender, address(this), assets);
        }
        return (assets, shares);
    }
}

// Simple ERC4626 wrapper for testing with real MorphoCredit
contract SimpleERC4626 is IERC4626 {
    ERC20Mock public immutable underlying;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(address _underlying) {
        underlying = ERC20Mock(_underlying);
    }

    // ERC20 functions
    function name() external pure returns (string memory) {
        return "waUSDC";
    }

    function symbol() external pure returns (string memory) {
        return "waUSDC";
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    // ERC4626 functions
    function asset() external view returns (address) {
        return address(underlying);
    }

    function totalAssets() external view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        underlying.transferFrom(msg.sender, address(this), assets);
        totalSupply += assets;
        balanceOf[receiver] += assets;
        emit Transfer(address(0), receiver, assets);
        return assets;
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function mint(uint256 shares, address receiver) external returns (uint256) {
        underlying.transferFrom(msg.sender, address(this), shares);
        totalSupply += shares;
        balanceOf[receiver] += shares;
        emit Transfer(address(0), receiver, shares);
        return shares;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return balanceOf[owner];
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256) {
        if (msg.sender != owner) {
            allowance[owner][msg.sender] -= assets;
        }
        totalSupply -= assets;
        balanceOf[owner] -= assets;
        emit Transfer(owner, address(0), assets);
        underlying.transfer(receiver, assets);
        return assets;
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf[owner];
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        if (msg.sender != owner) {
            allowance[owner][msg.sender] -= shares;
        }
        totalSupply -= shares;
        balanceOf[owner] -= shares;
        emit Transfer(owner, address(0), shares);
        underlying.transfer(receiver, shares);
        return shares;
    }

    // Helper function for testing
    function setBalance(address account, uint256 amount) external {
        uint256 current = balanceOf[account];
        if (amount > current) {
            totalSupply += amount - current;
        } else {
            totalSupply -= current - amount;
        }
        balanceOf[account] = amount;
    }
}

contract HelperTest is BaseTest {
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;

    Helper public helper;
    USD3Mock public usd3;
    USD3Mock public sUsd3;
    ERC20Mock public usdc;
    WrapMock public waUsdc;
    MorphoMock public morphoMock;

    address public user = makeAddr("User");
    address public receiver = makeAddr("Receiver");
    address public owner = makeAddr("Owner");

    uint256 public constant DEPOSIT_AMOUNT = 1000e6; // 1000 USDC
    uint256 public constant BORROW_AMOUNT = 500e6; // 500 USDC

    function setUp() public override {
        super.setUp();

        // Deploy mock contracts
        usdc = new ERC20Mock();
        waUsdc = new WrapMock(address(usdc));
        usd3 = new USD3Mock();
        sUsd3 = new USD3Mock();
        morphoMock = new MorphoMock();

        // Configure USD3Mock with waUSDC as underlying
        usd3.setUnderlying(address(waUsdc));
        sUsd3.setUnderlying(address(usd3));

        // Whitelist the user for USD3
        usd3.setWhitelist(user, true);
        usd3.setWhitelist(address(helper), true); // Also whitelist helper for intermediate deposits

        // Configure MorphoMock with tokens
        morphoMock.setTokens(address(waUsdc), address(usdc));

        // Deploy Helper contract
        helper = new Helper(address(morphoMock), address(usd3), address(sUsd3), address(usdc), address(waUsdc));

        // Set up initial balances
        usdc.setBalance(user, DEPOSIT_AMOUNT * 10);
        usdc.setBalance(address(helper), 0);

        // Give MorphoMock some waUSDC to borrow from
        waUsdc.setBalance(address(morphoMock), DEPOSIT_AMOUNT * 10);

        // Approve tokens
        vm.startPrank(user);
        usdc.approve(address(helper), type(uint256).max);
        usd3.approve(address(helper), type(uint256).max);
        sUsd3.approve(address(helper), type(uint256).max);
        waUsdc.approve(address(helper), type(uint256).max);
        waUsdc.approve(address(morphoMock), type(uint256).max);
        vm.stopPrank();
    }

    function test_Constructor() public {
        // Test that all addresses are set correctly
        assertEq(helper.MORPHO(), address(morphoMock));
        assertEq(helper.USD3(), address(usd3));
        assertEq(helper.sUSD3(), address(sUsd3));
        assertEq(helper.USDC(), address(usdc));
        assertEq(helper.WAUSDC(), address(waUsdc));
    }

    function test_Constructor_ZeroAddress() public {
        // Test that constructor reverts with zero addresses
        vm.expectRevert();
        new Helper(address(0), address(usd3), address(sUsd3), address(usdc), address(waUsdc));

        vm.expectRevert();
        new Helper(address(morphoMock), address(0), address(sUsd3), address(usdc), address(waUsdc));

        vm.expectRevert();
        new Helper(address(morphoMock), address(usd3), address(0), address(usdc), address(waUsdc));

        vm.expectRevert();
        new Helper(address(morphoMock), address(usd3), address(sUsd3), address(0), address(waUsdc));

        vm.expectRevert();
        new Helper(address(morphoMock), address(usd3), address(sUsd3), address(usdc), address(0));
    }

    function test_SimpleDepositRedeem() public {
        // Test with 1:1 price per share (no premiums)
        uint256 waUSDCPricePerShare = 1e18; // 1:1 ratio
        uint256 usd3PricePerShare = 1e18; // 1:1 ratio
        uint256 sUsd3PricePerShare = 1e18; // 1:1 ratio

        waUsdc.setPricePerShare(waUSDCPricePerShare);
        usd3.setPricePerShare(usd3PricePerShare);
        sUsd3.setPricePerShare(sUsd3PricePerShare);

        uint256 initialUSDCBalance = usdc.balanceOf(user);

        console.log("=== SIMPLE DEPOSIT ===");
        console.log("Initial USDC balance:", initialUSDCBalance);

        // Step 1: Deposit without hop (USDC -> waUSDC -> USD3)
        vm.startPrank(user);
        uint256 shares = helper.deposit(DEPOSIT_AMOUNT, user, false);
        vm.stopPrank();

        console.log("USD3 shares received:", shares);
        console.log("Expected shares:", DEPOSIT_AMOUNT);

        // Verify the shares match expected
        assertEq(shares, DEPOSIT_AMOUNT);
        assertEq(usd3.balanceOf(user), DEPOSIT_AMOUNT);

        // Step 2: Redeem USD3 shares
        vm.startPrank(user);
        uint256 redeemedAssets = helper.redeem(shares, user);
        vm.stopPrank();

        console.log("Redeemed assets:", redeemedAssets);
        console.log("Expected assets:", DEPOSIT_AMOUNT);

        // Verify the redeemed assets match expected
        assertEq(redeemedAssets, DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(user), initialUSDCBalance);

        // Verify all shares were burned
        assertEq(usd3.balanceOf(user), 0);
        assertEq(waUsdc.balanceOf(address(helper)), 0);
    }

    function test_DepositWithHop() public {
        // Test deposit with hop=true (USDC -> waUSDC -> USD3 -> sUSD3)
        uint256 initialUSDCBalance = usdc.balanceOf(user);

        // Give waUsdc some balance to USD3 mock for deposits
        waUsdc.setBalance(address(usd3), DEPOSIT_AMOUNT * 10);
        // Give USD3 some balance to sUSD3 mock for deposits
        usd3.setBalance(address(sUsd3), DEPOSIT_AMOUNT * 10);

        vm.startPrank(user);
        uint256 shares = helper.deposit(DEPOSIT_AMOUNT, user, true);
        vm.stopPrank();

        // With 1:1 ratios, should receive same amount in sUSD3
        assertEq(shares, DEPOSIT_AMOUNT);
        assertEq(sUsd3.balanceOf(user), DEPOSIT_AMOUNT);

        // User should have no USD3 (it was deposited into sUSD3)
        assertEq(usd3.balanceOf(user), 0);

        // Helper should have no tokens
        assertEq(usd3.balanceOf(address(helper)), 0);
        assertEq(sUsd3.balanceOf(address(helper)), 0);
        assertEq(waUsdc.balanceOf(address(helper)), 0);

        // User's USDC should be reduced by deposit amount
        assertEq(usdc.balanceOf(user), initialUSDCBalance - DEPOSIT_AMOUNT);
    }

    function test_RedeemFromSUSD3() public {
        // First deposit with hop to get sUSD3
        waUsdc.setBalance(address(usd3), DEPOSIT_AMOUNT * 10);
        usd3.setBalance(address(sUsd3), DEPOSIT_AMOUNT * 10);

        vm.startPrank(user);
        uint256 sUsd3Shares = helper.deposit(DEPOSIT_AMOUNT, user, true);
        vm.stopPrank();

        // Now test redemption: sUSD3 -> USD3 -> waUSDC -> USDC
        // Give mocks necessary balances for redemption
        usd3.setBalance(address(sUsd3), DEPOSIT_AMOUNT * 10); // sUSD3 needs USD3 to redeem
        waUsdc.setBalance(address(usd3), DEPOSIT_AMOUNT * 10); // USD3 needs waUSDC to redeem
        usdc.setBalance(address(waUsdc), DEPOSIT_AMOUNT * 10); // waUSDC needs USDC to redeem

        // First, user needs to convert sUSD3 back to USD3
        vm.startPrank(user);
        uint256 usd3Amount = sUsd3.redeem(sUsd3Shares, user, user);
        vm.stopPrank();

        assertEq(usd3Amount, DEPOSIT_AMOUNT);
        assertEq(usd3.balanceOf(user), DEPOSIT_AMOUNT);
        assertEq(sUsd3.balanceOf(user), 0);

        // Now redeem USD3 through Helper
        vm.startPrank(user);
        uint256 usdcAmount = helper.redeem(usd3Amount, user);
        vm.stopPrank();

        // Should get back original USDC amount with 1:1 ratios
        assertEq(usdcAmount, DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(user), DEPOSIT_AMOUNT * 10); // Initial balance restored
        assertEq(usd3.balanceOf(user), 0);

        // Helper should have no tokens
        assertEq(waUsdc.balanceOf(address(helper)), 0);
        assertEq(usd3.balanceOf(address(helper)), 0);
    }

    function test_DepositWithHop_WithDifferentPriceRatios() public {
        // Test with different price ratios to ensure calculations work correctly
        waUsdc.setPricePerShare(1.1e18); // 10% premium
        usd3.setPricePerShare(1.05e18); // 5% premium
        sUsd3.setPricePerShare(1.02e18); // 2% premium

        // Give sufficient balances for conversions
        waUsdc.setBalance(address(usd3), DEPOSIT_AMOUNT * 20);
        usd3.setBalance(address(sUsd3), DEPOSIT_AMOUNT * 20);

        uint256 initialUSDCBalance = usdc.balanceOf(user);

        vm.startPrank(user);
        uint256 shares = helper.deposit(DEPOSIT_AMOUNT, user, true);
        vm.stopPrank();

        // Calculate expected shares through all conversions
        // USDC -> waUSDC: 1000e6 / 1.1 = 909.09e6 waUSDC shares
        uint256 expectedWaUSDCShares = (DEPOSIT_AMOUNT * 1e18) / 1.1e18;
        // waUSDC -> USD3: 909.09e6 / 1.05 = 865.80e6 USD3 shares
        uint256 expectedUSD3Shares = (expectedWaUSDCShares * 1e18) / 1.05e18;
        // USD3 -> sUSD3: 865.80e6 / 1.02 = 848.82e6 sUSD3 shares
        uint256 expectedSUSD3Shares = (expectedUSD3Shares * 1e18) / 1.02e18;

        assertEq(shares, expectedSUSD3Shares);
        assertEq(sUsd3.balanceOf(user), expectedSUSD3Shares);
        assertEq(usdc.balanceOf(user), initialUSDCBalance - DEPOSIT_AMOUNT);
    }

    function test_BorrowRepayCycle() public {
        // Test borrow and repay with proper USDC flow
        uint256 initialUSDCBalance = usdc.balanceOf(user);

        MarketParams memory marketParams = MarketParams({
            loanToken: address(waUsdc),
            collateralToken: address(usdc),
            oracle: address(0),
            irm: address(0),
            lltv: 0.8e18,
            creditLine: address(1)
        });

        // Configure MorphoMock to transfer waUSDC to Helper (not user)
        // MorphoMock's borrow should send to the 'receiver' parameter which is Helper

        // Give waUsdc mock USDC to unwrap for the borrower
        usdc.setBalance(address(waUsdc), BORROW_AMOUNT * 10);
        // Give MorphoMock some waUSDC to lend
        waUsdc.setBalance(address(morphoMock), BORROW_AMOUNT * 10);

        // Ensure waUsdc can transfer USDC during unwrap
        vm.prank(address(waUsdc));
        usdc.approve(address(waUsdc), type(uint256).max);

        // Test borrow
        vm.startPrank(user);
        (uint256 borrowedAssets, uint256 borrowShares) = helper.borrow(marketParams, BORROW_AMOUNT);
        vm.stopPrank();

        // Should receive USDC amount
        assertEq(borrowedAssets, BORROW_AMOUNT);
        assertEq(borrowShares, 0); // Mock returns 0 shares
        assertEq(usdc.balanceOf(user), initialUSDCBalance + BORROW_AMOUNT);

        // Test repay
        bytes memory data = "";
        vm.startPrank(user);
        (uint256 repaidAssets, uint256 repaidShares) = helper.repay(marketParams, BORROW_AMOUNT, user, data);
        vm.stopPrank();

        // Should have repaid the USDC amount
        assertEq(repaidAssets, BORROW_AMOUNT);
        assertEq(repaidShares, 0); // Mock returns 0 shares
        assertEq(usdc.balanceOf(user), initialUSDCBalance);

        // Helper should have no tokens
        assertEq(waUsdc.balanceOf(address(helper)), 0);
        assertEq(usdc.balanceOf(address(helper)), 0);
    }

    function testFuzz_DepositRedeemCycle(uint256 amount) public {
        // Bound the amount to reasonable values
        amount = bound(amount, 1e6, 100_000e6); // Between 1 and 100,000 USDC

        // Give user sufficient balance
        usdc.setBalance(user, amount * 2);

        // Give mocks sufficient balances
        waUsdc.setBalance(address(usd3), amount * 10);
        usd3.setBalance(address(sUsd3), amount * 10);
        usdc.setBalance(address(waUsdc), amount * 10);

        uint256 initialBalance = usdc.balanceOf(user);

        // Test deposit without hop
        vm.startPrank(user);
        uint256 usd3Shares = helper.deposit(amount, user, false);
        vm.stopPrank();

        assertEq(usd3Shares, amount); // 1:1 ratio
        assertEq(usd3.balanceOf(user), amount);
        assertEq(usdc.balanceOf(user), initialBalance - amount);

        // Test redeem
        vm.startPrank(user);
        uint256 redeemedAmount = helper.redeem(usd3Shares, user);
        vm.stopPrank();

        assertEq(redeemedAmount, amount);
        assertEq(usdc.balanceOf(user), initialBalance);
        assertEq(usd3.balanceOf(user), 0);
    }

    // ============ Full Repayment Tests with Real MorphoCredit ============
    // These tests validate the Helper's full repayment functionality using
    // real MorphoCredit instead of mocks to ensure proper premium accrual handling

    // State variables for real MorphoCredit tests
    IMorpho morphoCreditReal;
    SimpleERC4626 simpleWaUsdc;
    CreditLineMock creditLineReal;
    address testBorrower = makeAddr("TestBorrower");

    function setupRealMorphoCredit() internal {
        // Deploy real MorphoCredit for full repayment tests
        MorphoCredit morphoCreditImpl = new MorphoCredit(address(protocolConfig));
        ProxyAdmin proxyAdminNew = new ProxyAdmin(PROXY_ADMIN_OWNER);
        TransparentUpgradeableProxy morphoCreditProxy = new TransparentUpgradeableProxy(
            address(morphoCreditImpl),
            address(proxyAdminNew),
            abi.encodeWithSelector(MorphoCredit.initialize.selector, OWNER)
        );
        morphoCreditReal = IMorpho(address(morphoCreditProxy));

        // Deploy SimpleERC4626 for waUsdc
        ERC20Mock newUsdc = new ERC20Mock();
        simpleWaUsdc = new SimpleERC4626(address(newUsdc));

        // Deploy credit line mock
        creditLineReal = new CreditLineMock(address(morphoCreditReal));

        // Deploy new helper with real MorphoCredit
        Helper realHelper = new Helper(
            address(morphoCreditReal), address(usd3), address(sUsd3), address(newUsdc), address(simpleWaUsdc)
        );

        // Setup market params with SimpleERC4626 as loan token
        MarketParams memory realMarketParams = MarketParams({
            loanToken: address(simpleWaUsdc),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(irm),
            lltv: 0,
            creditLine: address(creditLineReal)
        });
        Id realId = realMarketParams.id();

        // Enable IRM, LLTV and create market
        vm.startPrank(OWNER);
        morphoCreditReal.enableIrm(address(irm));
        morphoCreditReal.enableLltv(0);
        morphoCreditReal.createMarket(realMarketParams);
        MorphoCredit(address(morphoCreditReal)).setHelper(address(realHelper));
        MorphoCredit(address(morphoCreditReal)).setUsd3(address(usd3));
        vm.stopPrank();

        // Initialize first cycle to unfreeze the market
        vm.warp(block.timestamp + CYCLE_DURATION);
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);
        vm.prank(address(creditLineReal));
        MorphoCredit(address(morphoCreditReal)).closeCycleAndPostObligations(
            realId, block.timestamp, borrowers, repaymentBps, endingBalances
        );

        // Supply liquidity
        simpleWaUsdc.setBalance(address(usd3), DEPOSIT_AMOUNT * 2);
        vm.startPrank(address(usd3));
        simpleWaUsdc.approve(address(morphoCreditReal), DEPOSIT_AMOUNT * 2);
        morphoCreditReal.supply(realMarketParams, DEPOSIT_AMOUNT * 2, 0, address(usd3), hex"");
        vm.stopPrank();

        // Set up credit line for test borrower
        vm.prank(address(creditLineReal));
        MorphoCredit(address(morphoCreditReal)).setCreditLine(
            realId, testBorrower, BORROW_AMOUNT * 2, uint128(PREMIUM_RATE_PER_SECOND)
        );

        // Borrower borrows through helper
        simpleWaUsdc.setBalance(address(realHelper), BORROW_AMOUNT);
        vm.prank(address(realHelper));
        morphoCreditReal.borrow(realMarketParams, BORROW_AMOUNT, 0, testBorrower, address(realHelper));

        // Setup USDC for repayments
        newUsdc.setBalance(testBorrower, BORROW_AMOUNT * 3);
        vm.prank(testBorrower);
        newUsdc.approve(address(realHelper), type(uint256).max);

        // Give waUsdc some USDC for unwrapping
        newUsdc.setBalance(address(simpleWaUsdc), BORROW_AMOUNT * 3);
        simpleWaUsdc.setBalance(address(realHelper), BORROW_AMOUNT * 3);

        // Store helper reference for tests
        helper = realHelper;
        marketParams = realMarketParams;
        id = realId;
    }

    function test_FullRepaymentWithSentinel() public {
        setupRealMorphoCredit();

        // Test repaying with type(uint256).max sentinel value
        vm.prank(testBorrower);
        (uint256 repaidAssets, uint256 repaidShares) =
            helper.repay(marketParams, type(uint256).max, testBorrower, hex"");

        // Check that some amount was repaid
        assertGt(repaidAssets, 0, "Should have repaid some assets");
        assertGt(repaidShares, 0, "Should have repaid some shares");

        // Verify position is cleared
        Position memory finalPos = morphoCreditReal.position(id, testBorrower);
        assertEq(finalPos.borrowShares, 0, "Borrow shares should be zero after full repayment");
    }

    function test_FullRepaymentWithPremiumAccrual() public {
        setupRealMorphoCredit();

        // Simulate time passing to accrue premium
        vm.warp(block.timestamp + 30 days);

        // Get position before repayment
        Position memory positionBefore = morphoCreditReal.position(id, testBorrower);
        assertGt(positionBefore.borrowShares, 0, "Should have outstanding debt");

        // Give borrower extra USDC to cover accrued interest
        ERC20Mock(helper.USDC()).setBalance(testBorrower, BORROW_AMOUNT * 5);

        // Repay with sentinel value
        vm.prank(testBorrower);
        (uint256 repaidAssets, uint256 repaidShares) =
            helper.repay(marketParams, type(uint256).max, testBorrower, hex"");

        // After time passing, debt should have increased due to interest
        assertGt(repaidAssets, BORROW_AMOUNT, "Should have repaid more than initial borrow due to interest");
        assertGt(repaidShares, 0, "Should have repaid shares");

        // Verify no dust remains
        Position memory finalPos = morphoCreditReal.position(id, testBorrower);
        assertEq(finalPos.borrowShares, 0, "No dust should remain after full repayment");
    }

    function test_FullRepaymentWhenNoDebt() public {
        setupRealMorphoCredit();

        // First fully repay the debt
        vm.prank(testBorrower);
        helper.repay(marketParams, type(uint256).max, testBorrower, hex"");

        // Verify debt is cleared
        Position memory clearedPos = morphoCreditReal.position(id, testBorrower);
        assertEq(clearedPos.borrowShares, 0, "Debt should be cleared");

        // Try to repay again with sentinel value when no debt
        vm.prank(testBorrower);
        (uint256 repaidAssets, uint256 repaidShares) =
            helper.repay(marketParams, type(uint256).max, testBorrower, hex"");

        // Should return zero for both
        assertEq(repaidAssets, 0, "Should repay zero assets when no debt");
        assertEq(repaidShares, 0, "Should repay zero shares when no debt");
    }

    function test_PartialRepaymentNotAffectedWithRealMorpho() public {
        setupRealMorphoCredit();

        // Test that normal partial repayment still works
        uint256 partialAmount = BORROW_AMOUNT / 2;

        // Get initial position
        Position memory initialPos = morphoCreditReal.position(id, testBorrower);

        vm.prank(testBorrower);
        (uint256 repaidAssets, uint256 repaidShares) = helper.repay(marketParams, partialAmount, testBorrower, hex"");

        assertEq(repaidAssets, partialAmount, "Should repay exact partial amount");

        // Check that debt is reduced but not zero
        Position memory pos = morphoCreditReal.position(id, testBorrower);
        assertGt(pos.borrowShares, 0, "Should still have some debt");
        assertLt(pos.borrowShares, initialPos.borrowShares, "Debt should be reduced");
    }
}
