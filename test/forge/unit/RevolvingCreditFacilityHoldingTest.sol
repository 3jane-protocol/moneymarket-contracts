// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.22;

import {stdError} from "forge-std/StdError.sol";

import {ERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "../../../lib/openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "../../../lib/openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {RevolvingCreditFacilityHolding} from "../../../src/RevolvingCreditFacilityHolding.sol";
import {Helper} from "../../../src/Helper.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {Id, MarketParams} from "../../../src/interfaces/IMorpho.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {USD3} from "../../../src/usd3/USD3.sol";
import {MockWaUSDC} from "../usd3/mocks/MockWaUSDC.sol";
import {Setup} from "../usd3/utils/Setup.sol";

contract SimpleERC20 is ERC20 {
    constructor() ERC20("Simple Token", "SIMPLE") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract MaliciousVault is ERC20 {
    IERC20 public immutable underlying;
    address public reserve;
    bool public attackEnabled;

    constructor(address asset_) ERC20("Malicious Vault", "mVAULT") {
        underlying = IERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function setReserve(address reserve_) external {
        reserve = reserve_;
    }

    function setAttackEnabled(bool attackEnabled_) external {
        attackEnabled = attackEnabled_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, assets);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = assets;

        if (attackEnabled) {
            RevolvingCreditFacilityHolding(reserve).executeScheduledRepayment();
        }

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        _burn(owner, shares);
        underlying.transfer(receiver, assets);
    }
}

contract RevolvingCreditFacilityHoldingTest is Setup {
    address internal admin = makeAddr("admin");
    address internal proposer = makeAddr("proposer");
    address internal offRampRecipient = makeAddr("offRampRecipient");
    address internal lender = makeAddr("lender");

    uint256 internal constant LIQUIDITY = 1_000_000e6;
    uint256 internal constant CREDIT = 500_000e6;
    uint256 internal constant DRAW = 100_000e6;

    Helper internal realHelper;
    MorphoCredit internal morpho;
    MarketParams internal reserveMarketParams;
    Id internal reserveMarketId;
    MockWaUSDC internal vault;
    RevolvingCreditFacilityHolding internal reserve;

    function setUp() public override {
        super.setUp();

        morpho = MorphoCredit(address(USD3(address(strategy)).morphoCredit()));
        reserveMarketParams = USD3(address(strategy)).marketParams();
        reserveMarketId = USD3(address(strategy)).marketId();

        realHelper = new Helper(
            address(morpho), address(strategy), makeAddr("sUSD3"), address(underlyingAsset), address(waUSDC)
        );

        // The reserve tests exercise the production Helper, so the protocol-wide helper is swapped from Setup's mock.
        vm.prank(morpho.owner());
        morpho.setHelper(address(realHelper));

        setMaxOnCredit(10_000);
        mintAndDepositIntoStrategy(strategy, lender, LIQUIDITY);

        vault = new MockWaUSDC(address(underlyingAsset));
        reserve = _deployReserve(address(vault));
        _setReserveCredit(address(reserve), CREDIT);
        _postEmptyCycle();
    }

    function test_constructorRejectsLoanTokenWithDifferentAsset() public {
        SimpleERC20 otherAsset = new SimpleERC20();
        MockWaUSDC badLoanToken = new MockWaUSDC(address(otherAsset));
        MarketParams memory badMarketParams = reserveMarketParams;
        badMarketParams.loanToken = address(badLoanToken);

        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        new RevolvingCreditFacilityHolding(
            admin, proposer, offRampRecipient, address(realHelper), address(vault), badMarketParams
        );
    }

    function test_adminDrawsAndInvestsInVault() public {
        _draw(DRAW);

        assertEq(underlyingAsset.balanceOf(address(reserve)), 0, "reserve should not keep idle USDC");
        assertEq(vault.balanceOf(address(reserve)), DRAW, "reserve should hold vault shares");
        assertEq(reserve.outstandingDebtAssets(), DRAW, "reserve debt should match draw");
    }

    function test_adminReleasesToProtocolByRepayingReserveDebt() public {
        _draw(DRAW);

        vm.prank(admin);
        reserve.releaseToProtocol(40_000e6);

        assertEq(reserve.outstandingDebtAssets(), 60_000e6, "debt should be partially repaid");
        assertEq(vault.balanceOf(address(reserve)), 60_000e6, "vault shares should be withdrawn");
    }

    function test_adminReleasesAllToProtocol() public {
        _draw(DRAW);

        vm.prank(admin);
        reserve.releaseAllToProtocol();

        assertEq(reserve.outstandingDebtAssets(), 0, "debt should be fully repaid");
        assertEq(vault.balanceOf(address(reserve)), 0, "vault shares should be fully withdrawn");
    }

    function test_emergencyRepayBypassesHelperForExistingDebt() public {
        _draw(DRAW);

        vm.prank(morpho.owner());
        morpho.setHelper(makeAddr("rotatedHelper"));

        vm.expectRevert(ErrorsLib.NotHelper.selector);
        vm.prank(admin);
        reserve.drawAndInvest(1e6);

        vm.prank(admin);
        reserve.emergencyRepay(40_000e6);

        assertEq(reserve.outstandingDebtAssets(), 60_000e6, "emergency repay should reduce debt");
        assertEq(vault.balanceOf(address(reserve)), 60_000e6, "vault shares should be withdrawn");
    }

    function test_emergencyRepayAllBypassesHelper() public {
        _draw(DRAW);

        vm.prank(morpho.owner());
        morpho.setHelper(makeAddr("rotatedHelper"));

        vm.prank(admin);
        reserve.emergencyRepay(type(uint256).max);

        assertEq(reserve.outstandingDebtAssets(), 0, "emergency repay should clear debt");
        assertEq(vault.balanceOf(address(reserve)), 0, "vault shares should be fully withdrawn");
    }

    function test_adminReleasesOnlyToFixedOffRampRecipient() public {
        _draw(DRAW);

        vm.prank(admin);
        reserve.releaseToOfframp(25_000e6);

        assertEq(underlyingAsset.balanceOf(offRampRecipient), 25_000e6, "off-ramp should receive USDC");
        assertEq(underlyingAsset.balanceOf(address(this)), 0, "arbitrary recipient should not receive funds");
        assertEq(reserve.outstandingDebtAssets(), DRAW, "off-ramp release should not repay protocol debt");
    }

    function test_vaultRejectsThirdPartyWithdrawWithoutAllowance() public {
        _draw(DRAW);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(address(strategy));
        vault.withdraw(1e6, address(strategy), address(reserve));
    }

    function test_proposerRepaymentExecutesAfterDelay() public {
        _draw(DRAW);

        skip(180 days);

        vm.prank(proposer);
        reserve.scheduleProtocolRepayment(10_000e6);

        vm.expectRevert(RevolvingCreditFacilityHolding.OperationNotReady.selector);
        reserve.executeScheduledRepayment();

        skip(7 days);

        _postEmptyCycle();
        morpho.accrueInterest(reserveMarketParams);
        uint256 debtBefore = reserve.outstandingDebtAssets();

        reserve.executeScheduledRepayment();

        assertEq(reserve.outstandingDebtAssets(), debtBefore - 10_000e6, "scheduled repayment should reduce debt");
    }

    function test_adminCanVetoProposerRepayment() public {
        _draw(DRAW);

        skip(180 days);

        vm.prank(proposer);
        reserve.scheduleProtocolRepayment(10_000e6);

        vm.prank(admin);
        reserve.vetoScheduledRepayment();

        skip(7 days);

        vm.expectRevert(RevolvingCreditFacilityHolding.InvalidOperation.selector);
        reserve.executeScheduledRepayment();
    }

    function test_proposerCanOverwriteScheduledRepayment() public {
        _draw(DRAW);

        skip(180 days);

        vm.prank(proposer);
        reserve.scheduleProtocolRepayment(10_000e6);
        (uint256 firstAmount, uint256 firstEta) = reserve.scheduledRepayment();

        skip(1 days);

        vm.prank(proposer);
        reserve.scheduleProtocolRepayment(15_000e6);
        (uint256 secondAmount, uint256 secondEta) = reserve.scheduledRepayment();

        assertEq(firstAmount, 10_000e6, "first scheduled amount");
        assertEq(secondAmount, 15_000e6, "overwritten scheduled amount");
        assertEq(secondEta, block.timestamp + reserve.PROPOSER_DELAY(), "overwrite should reset eta");
        assertGt(secondEta, firstEta, "new eta should be later");
    }

    function test_overwrittenRepaymentUsesLatestAmountAndTimer() public {
        _draw(DRAW);

        skip(180 days);

        vm.prank(proposer);
        reserve.scheduleProtocolRepayment(10_000e6);

        skip(6 days);

        vm.prank(proposer);
        reserve.scheduleProtocolRepayment(15_000e6);

        skip(1 days);

        vm.expectRevert(RevolvingCreditFacilityHolding.OperationNotReady.selector);
        reserve.executeScheduledRepayment();

        skip(6 days);

        _postEmptyCycle();
        morpho.accrueInterest(reserveMarketParams);
        uint256 debtBefore = reserve.outstandingDebtAssets();

        reserve.executeScheduledRepayment();

        assertEq(reserve.outstandingDebtAssets(), debtBefore - 15_000e6, "latest repayment amount should execute");
    }

    function test_proposerCannotReleaseToOfframp() public {
        _draw(DRAW);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, proposer));
        vm.prank(proposer);
        reserve.releaseToOfframp(10_000e6);
    }

    function test_adminSetterRefreshesFallbackScheduleDelay() public {
        _draw(DRAW);

        skip(100 days);

        address newProposer = makeAddr("newProposer");
        vm.prank(admin);
        reserve.setProposer(newProposer);
        skip(100 days);

        vm.expectRevert(RevolvingCreditFacilityHolding.FallbackNotReady.selector);
        vm.prank(newProposer);
        reserve.scheduleProtocolRepayment(10_000e6);
    }

    function test_proposerCannotScheduleBeforeFallbackDelay() public {
        _draw(DRAW);

        skip(180 days - 1);

        vm.expectRevert(RevolvingCreditFacilityHolding.FallbackNotReady.selector);
        vm.prank(proposer);
        reserve.scheduleProtocolRepayment(10_000e6);
    }

    function test_adminPingResetsFallbackScheduleDelay() public {
        _draw(DRAW);

        skip(100 days);

        vm.prank(admin);
        reserve.adminPing();
        skip(100 days);

        vm.expectRevert(RevolvingCreditFacilityHolding.FallbackNotReady.selector);
        vm.prank(proposer);
        reserve.scheduleProtocolRepayment(10_000e6);
    }

    function test_proposerCanScheduleAfterFallbackDelay() public {
        _draw(DRAW);

        skip(180 days);

        vm.prank(proposer);
        reserve.scheduleProtocolRepayment(10_000e6);

        (uint256 amount, uint256 eta) = reserve.scheduledRepayment();
        assertEq(amount, 10_000e6, "fallback amount should be scheduled");
        assertEq(eta, block.timestamp + reserve.PROPOSER_DELAY(), "scheduled repayment should retain veto window");
    }

    function test_transferOwnershipRefreshesFallbackScheduleDelay() public {
        address newAdmin = makeAddr("newAdmin");

        _draw(DRAW);
        skip(180 days);

        vm.prank(admin);
        reserve.transferOwnership(newAdmin);

        vm.expectRevert(RevolvingCreditFacilityHolding.FallbackNotReady.selector);
        vm.prank(proposer);
        reserve.scheduleProtocolRepayment(10_000e6);
    }

    function test_renounceOwnershipIsDisabled() public {
        _draw(DRAW);

        vm.expectRevert(RevolvingCreditFacilityHolding.RenounceOwnershipDisabled.selector);
        vm.prank(admin);
        reserve.renounceOwnership();
    }

    function test_repayCannotExceedOutstandingDebt() public {
        _draw(DRAW);

        vm.expectRevert(RevolvingCreditFacilityHolding.RepayAmountExceedsDebt.selector);
        vm.prank(admin);
        reserve.releaseToProtocol(DRAW + 1);
    }

    function test_setProposerRejectsZeroAddressAndSameValue() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(admin);
        reserve.setProposer(address(0));

        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        vm.prank(admin);
        reserve.setProposer(proposer);
    }

    function test_setOffRampRecipientRejectsZeroAddressAndSameValue() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(admin);
        reserve.setOffRampRecipient(address(0));

        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        vm.prank(admin);
        reserve.setOffRampRecipient(offRampRecipient);
    }

    function test_rescueCannotRecoverProtectedAssets() public {
        _draw(DRAW);

        vm.expectRevert(RevolvingCreditFacilityHolding.ProtectedToken.selector);
        vm.prank(admin);
        reserve.rescueToken(address(vault), admin, 1);

        vm.expectRevert(RevolvingCreditFacilityHolding.ProtectedToken.selector);
        vm.prank(admin);
        reserve.rescueToken(reserveMarketParams.loanToken, admin, 1);

        deal(address(underlyingAsset), address(reserve), 1e6);

        vm.expectRevert(RevolvingCreditFacilityHolding.ProtectedToken.selector);
        vm.prank(admin);
        reserve.rescueToken(address(underlyingAsset), admin, 1e6);
    }

    function test_rescueTokenTransfersUnrelatedErc20() public {
        SimpleERC20 token = new SimpleERC20();
        token.mint(address(reserve), 100e18);

        vm.prank(admin);
        reserve.rescueToken(address(token), admin, 40e18);

        assertEq(token.balanceOf(admin), 40e18, "admin should receive rescued token");
        assertEq(token.balanceOf(address(reserve)), 60e18, "reserve should keep unrescued balance");
    }

    function test_investIdleRevertsWhenVaultMintsZeroShares() public {
        MockWaUSDC zeroShareVault = new MockWaUSDC(address(underlyingAsset));
        zeroShareVault.setSharePrice(2e6);
        RevolvingCreditFacilityHolding zeroShareReserve = _deployReserve(address(zeroShareVault));
        deal(address(underlyingAsset), address(zeroShareReserve), 1);

        vm.expectRevert(ErrorsLib.ZeroAssets.selector);
        vm.prank(admin);
        zeroShareReserve.investIdle(1);
    }

    function test_drawAndInvestRevertsWhenVaultMintsZeroShares() public {
        MockWaUSDC zeroShareVault = new MockWaUSDC(address(underlyingAsset));
        zeroShareVault.setSharePrice(DRAW * 1e6 + 1);
        RevolvingCreditFacilityHolding zeroShareReserve = _deployReserve(address(zeroShareVault));
        _setReserveCredit(address(zeroShareReserve), CREDIT);

        vm.expectRevert(ErrorsLib.ZeroAssets.selector);
        vm.prank(admin);
        zeroShareReserve.drawAndInvest(DRAW);
    }

    function test_reentrantWrapperCannotReenterScheduledRepayment() public {
        MaliciousVault maliciousVault = new MaliciousVault(address(underlyingAsset));
        RevolvingCreditFacilityHolding maliciousReserve = _deployReserve(address(maliciousVault));
        maliciousVault.setReserve(address(maliciousReserve));
        _setReserveCredit(address(maliciousReserve), CREDIT);

        vm.prank(admin);
        maliciousReserve.drawAndInvest(DRAW);

        skip(181 days);
        vm.prank(proposer);
        maliciousReserve.scheduleProtocolRepayment(10_000e6);
        skip(7 days);
        _postEmptyCycle();

        maliciousVault.setAttackEnabled(true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        maliciousReserve.executeScheduledRepayment();
    }

    function _deployReserve(address vault_) internal returns (RevolvingCreditFacilityHolding deployedReserve) {
        deployedReserve = new RevolvingCreditFacilityHolding(
            admin, proposer, offRampRecipient, address(realHelper), vault_, reserveMarketParams
        );
    }

    function _setReserveCredit(address borrower, uint256 credit) internal {
        vm.prank(reserveMarketParams.creditLine);
        morpho.setCreditLine(reserveMarketId, borrower, credit, 0);
    }

    function _postEmptyCycle() internal {
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        vm.prank(reserveMarketParams.creditLine);
        morpho.closeCycleAndPostObligations(reserveMarketId, block.timestamp, borrowers, repaymentBps, endingBalances);
    }

    function _draw(uint256 amount) internal {
        vm.prank(admin);
        reserve.drawAndInvest(amount);
    }
}
