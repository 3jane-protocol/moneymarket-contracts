// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {Helper} from "../../../src/Helper.sol";
import {IHelper} from "../../../src/interfaces/IHelper.sol";
import {IMorpho, IMorphoCredit, Id, Market, Position} from "../../../src/interfaces/IMorpho.sol";
import {MarketParams} from "../../../src/interfaces/IMorpho.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {IUSD3} from "../../../src/interfaces/IUSD3.sol";
import {IERC20} from "../../../src/interfaces/IERC20.sol";
import {IERC4626} from "../../../lib/forge-std/src/interfaces/IERC4626.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {TransparentUpgradeableProxy} from
    "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";

// Simple ERC4626 wrapper for testing
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

contract HelperFullRepaymentTest is BaseTest {
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;

    Helper helper;
    IMorpho morphoCredit;
    ERC20Mock usdc;
    SimpleERC4626 waUsdc;
    ERC20Mock usd3Token;
    ERC20Mock susd3Token;
    CreditLineMock creditLine;

    address constant TEST_BORROWER = address(0x1234);
    address constant TEST_SUPPLIER = address(0x5678);
    uint256 constant BORROW_AMOUNT = 500_000_000; // 500 USDC (6 decimals)
    uint256 constant SUPPLY_AMOUNT = 1_000_000_000; // 1000 USDC

    function setUp() public override {
        super.setUp();

        // Deploy token mocks
        usdc = new ERC20Mock();
        waUsdc = new SimpleERC4626(address(usdc));
        usd3Token = new ERC20Mock();
        susd3Token = new ERC20Mock();

        // Deploy real MorphoCredit
        MorphoCredit morphoCreditImpl = new MorphoCredit(address(protocolConfig));
        ProxyAdmin proxyAdminNew = new ProxyAdmin(PROXY_ADMIN_OWNER);
        TransparentUpgradeableProxy morphoCreditProxy = new TransparentUpgradeableProxy(
            address(morphoCreditImpl),
            address(proxyAdminNew),
            abi.encodeWithSelector(MorphoCredit.initialize.selector, OWNER)
        );
        morphoCredit = IMorpho(address(morphoCreditProxy));

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morphoCredit));

        // Deploy helper with real MorphoCredit
        helper =
            new Helper(address(morphoCredit), address(usd3Token), address(susd3Token), address(usdc), address(waUsdc));

        // Setup market params with waUsdc as loan token
        marketParams = MarketParams({
            loanToken: address(waUsdc),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(irm),
            lltv: 0,
            creditLine: address(creditLine)
        });
        id = marketParams.id();

        // Enable IRM, LLTV and create market
        vm.startPrank(OWNER);
        morphoCredit.enableIrm(address(irm));
        morphoCredit.enableLltv(0);
        morphoCredit.createMarket(marketParams);

        // Set helper and USD3 addresses
        IMorphoCredit(address(morphoCredit)).setHelper(address(helper));
        IMorphoCredit(address(morphoCredit)).setUsd3(address(usd3Token));
        vm.stopPrank();

        // Initialize first cycle to unfreeze the market
        vm.warp(block.timestamp + CYCLE_DURATION);
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morphoCredit)).closeCycleAndPostObligations(
            id, block.timestamp, borrowers, repaymentBps, endingBalances
        );

        // Supply liquidity to the market
        waUsdc.setBalance(address(usd3Token), SUPPLY_AMOUNT);
        vm.startPrank(address(usd3Token));
        waUsdc.approve(address(morphoCredit), SUPPLY_AMOUNT);
        morphoCredit.supply(marketParams, SUPPLY_AMOUNT, 0, TEST_SUPPLIER, hex"");
        vm.stopPrank();

        // Set up credit line and let borrower borrow
        vm.prank(address(creditLine));
        IMorphoCredit(address(morphoCredit)).setCreditLine(
            id, TEST_BORROWER, BORROW_AMOUNT * 2, uint128(PREMIUM_RATE_PER_SECOND)
        );

        // Borrower borrows through helper
        waUsdc.setBalance(address(helper), BORROW_AMOUNT);
        vm.prank(address(helper));
        morphoCredit.borrow(marketParams, BORROW_AMOUNT, 0, TEST_BORROWER, address(helper));

        // Setup USDC for repayments
        usdc.setBalance(TEST_BORROWER, BORROW_AMOUNT * 2);
        vm.prank(TEST_BORROWER);
        usdc.approve(address(helper), type(uint256).max);

        // Give waUsdc some USDC for unwrapping during repayments
        usdc.setBalance(address(waUsdc), BORROW_AMOUNT * 2);

        // Give helper some balance for conversions
        waUsdc.setBalance(address(helper), BORROW_AMOUNT * 2);
    }

    function test_FullRepaymentWithSentinel() public {
        // Test repaying with type(uint256).max sentinel value
        vm.prank(TEST_BORROWER);
        (uint256 repaidAssets, uint256 repaidShares) =
            helper.repay(marketParams, type(uint256).max, TEST_BORROWER, hex"");

        // Check that some amount was repaid
        assertGt(repaidAssets, 0, "Should have repaid some assets");
        assertGt(repaidShares, 0, "Should have repaid some shares");

        // Verify position is cleared
        Position memory finalPos = morphoCredit.position(id, TEST_BORROWER);
        assertEq(finalPos.borrowShares, 0, "Borrow shares should be zero after full repayment");
    }

    function test_FullRepaymentWithPremiumAccrual() public {
        // Simulate time passing to accrue premium (this will accrue interest)
        vm.warp(block.timestamp + 30 days);

        // Get position before repayment to see accrued debt
        Position memory positionBefore = morphoCredit.position(id, TEST_BORROWER);
        assertGt(positionBefore.borrowShares, 0, "Should have outstanding debt");

        // Give borrower enough USDC to cover accrued interest
        usdc.setBalance(TEST_BORROWER, BORROW_AMOUNT * 3);

        // Repay with sentinel value
        vm.prank(TEST_BORROWER);
        (uint256 repaidAssets, uint256 repaidShares) =
            helper.repay(marketParams, type(uint256).max, TEST_BORROWER, hex"");

        // After time passing, debt should have increased due to interest
        assertGt(repaidAssets, BORROW_AMOUNT, "Should have repaid more than initial borrow due to interest");
        assertGt(repaidShares, BORROW_AMOUNT, "Should have repaid more shares than initially borrowed due to interest");

        // Verify no dust remains
        Position memory finalPos = morphoCredit.position(id, TEST_BORROWER);
        assertEq(finalPos.borrowShares, 0, "No dust should remain after full repayment");
    }

    function test_FullRepaymentWhenNoDebt() public {
        // First fully repay the debt
        vm.prank(TEST_BORROWER);
        helper.repay(marketParams, type(uint256).max, TEST_BORROWER, hex"");

        // Verify debt is cleared
        Position memory clearedPos = morphoCredit.position(id, TEST_BORROWER);
        assertEq(clearedPos.borrowShares, 0, "Debt should be cleared");

        // Try to repay again with sentinel value when no debt
        vm.prank(TEST_BORROWER);
        (uint256 repaidAssets, uint256 repaidShares) =
            helper.repay(marketParams, type(uint256).max, TEST_BORROWER, hex"");

        // Should return zero for both
        assertEq(repaidAssets, 0, "Should repay zero assets when no debt");
        assertEq(repaidShares, 0, "Should repay zero shares when no debt");
    }

    function test_PartialRepaymentNotAffected() public {
        // Test that normal partial repayment still works
        uint256 partialAmount = BORROW_AMOUNT / 2;

        // Get initial position
        Position memory initialPos = morphoCredit.position(id, TEST_BORROWER);

        vm.prank(TEST_BORROWER);
        (uint256 repaidAssets, uint256 repaidShares) = helper.repay(marketParams, partialAmount, TEST_BORROWER, hex"");

        assertEq(repaidAssets, partialAmount, "Should repay exact partial amount");

        // Check that debt is reduced but not zero
        Position memory pos = morphoCredit.position(id, TEST_BORROWER);
        assertGt(pos.borrowShares, 0, "Should still have some debt");
        assertLt(pos.borrowShares, initialPos.borrowShares, "Debt should be reduced");
    }
}
