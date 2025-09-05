// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";
import {UtilsLib} from "../../../src/libraries/UtilsLib.sol";
import {MorphoCreditMock} from "../../../src/mocks/MorphoCreditMock.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {ProtocolConfig} from "../../../src/ProtocolConfig.sol";
import {TransparentUpgradeableProxy} from
    "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {IrmMock} from "../../../src/mocks/IrmMock.sol";

// Mock contract that bypasses credit line checks for testing virtual shares attack
contract MorphoVirtualSharesTestMock is MorphoCreditMock {
    using MathLib for uint256;
    using UtilsLib for uint256;

    constructor(address _protocolConfig) MorphoCreditMock(_protocolConfig) {}

    // Override _beforeBorrow to skip all credit line checks
    function _beforeBorrow(MarketParams memory, Id, address, uint256, uint256) internal virtual override {
        // Skip all checks for testing virtual shares attack prevention
        // This allows us to test the InsufficientBorrowAmount check in isolation
    }

    // Allow setting credit lines directly for testing (bypass creditLine authorization)
    function setCreditLineForTest(Id id, address borrower, uint256 credit) external {
        position[id][borrower].collateral = credit.toUint128();
    }
}

contract BorrowGriefingAttackTest is BaseTest {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;

    address attacker = makeAddr("Attacker");
    address victim = makeAddr("Victim");

    function setUp() public override {
        // Skip parent setUp to use our custom mock
        SUPPLIER = makeAddr("Supplier");
        BORROWER = makeAddr("Borrower");
        OWNER = makeAddr("Owner");
        FEE_RECIPIENT = makeAddr("FeeRecipient");

        // Deploy protocol config
        ProtocolConfig protocolConfigImpl = new ProtocolConfig();
        TransparentUpgradeableProxy protocolConfigProxy = new TransparentUpgradeableProxy(
            address(protocolConfigImpl),
            address(this),
            abi.encodeWithSelector(ProtocolConfig.initialize.selector, OWNER)
        );
        protocolConfig = ProtocolConfig(address(protocolConfigProxy));

        // Deploy our test mock that bypasses health checks
        MorphoVirtualSharesTestMock morphoImpl = new MorphoVirtualSharesTestMock(address(protocolConfig));

        // Deploy proxy admin
        ProxyAdmin proxyAdmin = new ProxyAdmin(OWNER);

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(MorphoCredit.initialize.selector, OWNER);
        TransparentUpgradeableProxy morphoProxy =
            new TransparentUpgradeableProxy(address(morphoImpl), address(proxyAdmin), initData);

        morpho = IMorpho(address(morphoProxy));

        // Setup tokens and oracle
        loanToken = new ERC20Mock();
        collateralToken = new ERC20Mock();
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);
        irm = new IrmMock();

        // Enable IRM and create market
        vm.startPrank(OWNER);
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0);
        morpho.setFeeRecipient(FEE_RECIPIENT);
        vm.stopPrank();

        // Create market with credit line for testing virtual shares
        // Set this test contract as the credit line provider
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(0),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0,
            creditLine: address(this)
        });

        vm.prank(OWNER);
        morpho.createMarket(marketParams);
        id = marketParams.id();

        // Approve tokens
        loanToken.approve(address(morpho), type(uint256).max);

        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();
    }

    function testBorrowGriefingAttack_SingleAttackPrevented() public {
        // Setup: Supply liquidity to the market
        uint256 supplyAmount = 1000e18;
        _supply(supplyAmount);

        // Set credit line for attacker using our test mock
        MorphoVirtualSharesTestMock(address(morpho)).setCreditLineForTest(id, attacker, 100e18);

        // Attack: Try to borrow VIRTUAL_SHARES - 1 shares when market has no borrows
        uint256 attackShares = SharesMathLib.VIRTUAL_SHARES - 1;

        // This should now revert with InsufficientBorrowAmount error
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        morpho.borrow(
            marketParams,
            0, // assets
            attackShares, // shares
            attacker,
            attacker
        );

        // Verify market state remains clean
        assertEq(morpho.totalBorrowAssets(id), 0, "Total borrow assets should remain 0");
        assertEq(morpho.totalBorrowShares(id), 0, "Total borrow shares should remain 0");
        assertEq(morpho.borrowShares(id, attacker), 0, "Attacker should have 0 shares");
    }

    function testBorrowGriefingAttack_RepeatedAttacksPrevented() public {
        // Setup: Supply liquidity to the market
        uint256 supplyAmount = 1000e18;
        _supply(supplyAmount);

        // Set credit line for attacker using our test mock
        MorphoVirtualSharesTestMock(address(morpho)).setCreditLineForTest(id, attacker, 1e30);

        // First attack attempt: Try to borrow VIRTUAL_SHARES - 1 shares (would result in 0 assets)
        uint256 firstAttackShares = SharesMathLib.VIRTUAL_SHARES - 1;
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        morpho.borrow(marketParams, 0, firstAttackShares, attacker, attacker);

        // Verify market remains clean after first attempt
        assertEq(morpho.totalBorrowAssets(id), 0, "Total borrow assets should remain 0");
        assertEq(morpho.totalBorrowShares(id), 0, "Total borrow shares should remain 0");

        // Even smaller attacks that would result in 0 assets are prevented
        uint256 smallAttackShares = SharesMathLib.VIRTUAL_SHARES / 2;
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        morpho.borrow(marketParams, 0, smallAttackShares, attacker, attacker);

        // Market should still be clean
        assertEq(morpho.totalBorrowAssets(id), 0, "Total borrow assets should still be 0");
        assertEq(morpho.totalBorrowShares(id), 0, "Total borrow shares should still be 0");

        // The fix ensures the griefing attack vector is closed - borrowing shares must result in at least 1 asset
    }

    function testBorrowGriefingAttack_LegitimateUsersProtected() public {
        // Setup: Supply liquidity to the market
        uint256 supplyAmount = 1000e18;
        _supply(supplyAmount);

        // Set credit line for attacker using our test mock
        MorphoVirtualSharesTestMock(address(morpho)).setCreditLineForTest(id, attacker, 1e30);

        // Attack attempts should fail
        uint256 attackShares = SharesMathLib.VIRTUAL_SHARES - 1;

        // Attack attempts that would result in 0 assets are prevented
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        morpho.borrow(marketParams, 0, attackShares, attacker, attacker);

        // Verify market is still clean
        assertEq(morpho.totalBorrowAssets(id), 0, "Market should have no borrows");
        assertEq(morpho.totalBorrowShares(id), 0, "Market should have no shares");

        // Set credit line for victim using our test mock
        MorphoVirtualSharesTestMock(address(morpho)).setCreditLineForTest(id, victim, 1000e18);

        // Legitimate user borrows a normal amount
        uint256 legitimateBorrowAmount = 10e18;
        vm.prank(victim);
        (uint256 assets, uint256 shares) = morpho.borrow(marketParams, legitimateBorrowAmount, 0, victim, victim);

        // Verify legitimate borrow worked correctly
        assertEq(assets, legitimateBorrowAmount, "Should borrow requested amount");
        assertGt(shares, 0, "Should receive shares");
        assertEq(morpho.totalBorrowAssets(id), legitimateBorrowAmount, "Market should track borrowed assets");
    }

    function testBorrowGriefingAttack_OverflowPrevented() public {
        // Setup: Supply liquidity to the market
        uint256 supplyAmount = 1000e18;
        _supply(supplyAmount);

        // Set credit line for attacker using our test mock
        MorphoVirtualSharesTestMock(address(morpho)).setCreditLineForTest(id, attacker, 1e30);

        // Try various attack patterns - all should fail
        uint256 baseShares = SharesMathLib.VIRTUAL_SHARES;

        // Try attack that would result in 0 assets
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        morpho.borrow(marketParams, 0, baseShares - 1, attacker, attacker);

        // Try another attack that would result in 0 assets
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        morpho.borrow(marketParams, 0, baseShares / 2, attacker, attacker);

        // Verify market remains clean
        assertEq(morpho.totalBorrowAssets(id), 0, "Total assets should be 0");
        assertEq(morpho.totalBorrowShares(id), 0, "Total shares should be 0");

        // Set credit line for victim using our test mock
        MorphoVirtualSharesTestMock(address(morpho)).setCreditLineForTest(id, victim, 1000e18);

        vm.prank(victim);
        (uint256 assets,) = morpho.borrow(marketParams, 10e18, 0, victim, victim);
        assertEq(assets, 10e18, "Legitimate borrow should work");
    }
}
