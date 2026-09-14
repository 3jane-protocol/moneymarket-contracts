// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "../../../lib/openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {LCCBase, LCCMockToken} from "./LCCBase.t.sol";
import {LCCMarginDepositHelper} from "../../../src/lcc/LCCMarginDepositHelper.sol";
import {ILCCMarginDepositHelper} from "../../../src/lcc/interfaces/ILCCMarginDepositHelper.sol";
import {ILCCAdmissionsModule} from "../../../src/lcc/interfaces/ILCCAdmissionsModule.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCMockStataToken is ERC20 {
    using SafeERC20 for IERC20;

    address public immutable asset;
    address public immutable aToken;
    uint256 public depositLimit = type(uint256).max;
    address public reentryTarget;
    bytes public reentryData;
    bytes4 public reentryError;

    constructor(address asset_, address aToken_, string memory symbol_) ERC20(symbol_, symbol_) {
        asset = asset_;
        aToken = aToken_;
    }

    function setMaxDeposit(uint256 limit) external {
        depositLimit = limit;
    }

    function armReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function maxDeposit(address) external view returns (uint256) {
        return depositLimit;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        if (reentryTarget != address(0)) {
            address target = reentryTarget;
            reentryTarget = address(0);
            (bool ok, bytes memory result) = target.call(reentryData);
            require(!ok, "REENTRY_SUCCEEDED");
            if (result.length >= 4) reentryError = bytes4(result);
        }
        _mint(receiver, assets);
        return assets;
    }

    function depositATokens(uint256 assets, address receiver) external returns (uint256 shares) {
        IERC20(aToken).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, assets);
        return assets;
    }

    function mint(address receiver, uint256 shares) external {
        _mint(receiver, shares);
    }
}

contract LCCNoReturnToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract LCCRoundedAToken {
    string public constant name = "Rounded aToken";
    string public constant symbol = "raToken";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) internal scaledBalance;
    mapping(address => mapping(address => uint256)) public allowance;

    function balanceOf(address account) external view returns (uint256) {
        return (scaledBalance[account] * 11) / 10;
    }

    function mint(address to, uint256 scaledAmount) external {
        scaledBalance[to] += scaledAmount;
        totalSupply += (scaledAmount * 11) / 10;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function previewReceived(uint256 amount) external pure returns (uint256) {
        return ((_scaledAmount(amount)) * 11) / 10;
    }

    function _transfer(address from, address to, uint256 amount) private {
        uint256 scaledAmount = _scaledAmount(amount);
        require(scaledBalance[from] >= scaledAmount, "BALANCE");
        scaledBalance[from] -= scaledAmount;
        scaledBalance[to] += scaledAmount;
    }

    function _scaledAmount(uint256 amount) private pure returns (uint256) {
        return (amount * 10 + 10) / 11;
    }
}

contract LCCBadStataWiring {
    address internal immutable asset_;
    address internal immutable aToken_;

    constructor(address asset__, address aToken__) {
        asset_ = asset__;
        aToken_ = aToken__;
    }

    function asset() external view returns (address) {
        return asset_;
    }

    function aToken() external view returns (address) {
        return aToken_;
    }
}

contract LCCHelperAdmissionsMock is ILCCAdmissionsModule {
    address public allowed;

    function setAllowed(address allowed_) external {
        allowed = allowed_;
    }

    function canDeposit(address beneficiary, address) external view returns (bool) {
        return beneficiary == allowed;
    }
}

contract LCCMarginDepositHelperTest is LCCBase {
    LCCMockToken internal underlyingUSDC;
    LCCMockToken internal aTokenUSDC;
    LCCNoReturnToken internal underlyingUSDT;
    LCCMockToken internal aTokenUSDT;
    LCCMockStataToken internal waEthUSDC;
    LCCMockStataToken internal waEthUSDT;
    LCCMarginDepositHelper internal helper;
    ILCCVault internal usdcVault;
    ILCCVault internal usdtVault;

    function setUp() public override {
        super.setUp();
        underlyingUSDC = new LCCMockToken("USDC input", "USDCi");
        aTokenUSDC = new LCCMockToken("Aave USDC", "aUSDC");
        underlyingUSDT = new LCCNoReturnToken("USDT input", "USDTi");
        aTokenUSDT = new LCCMockToken("Aave USDT", "aUSDT");
        waEthUSDC = new LCCMockStataToken(address(underlyingUSDC), address(aTokenUSDC), "waUSDC");
        waEthUSDT = new LCCMockStataToken(address(underlyingUSDT), address(aTokenUSDT), "waUSDT");
        helper = new LCCMarginDepositHelper(address(factory), address(waEthUSDC), address(waEthUSDT));
        factory.grantRole(factory.DEPOSIT_OPERATOR_ROLE(), address(helper));

        ILCCVault.VaultParams memory usdcParams = _params(CAP, CAP);
        usdcParams.marginAsset = address(waEthUSDC);
        usdcVault = _newVault(usdcParams);
        ILCCVault.VaultParams memory usdtParams = _params(CAP, CAP);
        usdtParams.marginAsset = address(waEthUSDT);
        usdtVault = _newVault(usdtParams);

        underlyingUSDC.mint(alice, 1_000e18);
        aTokenUSDC.mint(alice, 1_000e18);
        underlyingUSDT.mint(alice, 1_000e18);
        aTokenUSDT.mint(alice, 1_000e18);
        vm.startPrank(alice);
        underlyingUSDC.approve(address(helper), type(uint256).max);
        aTokenUSDC.approve(address(helper), type(uint256).max);
        underlyingUSDT.approve(address(helper), type(uint256).max);
        aTokenUSDT.approve(address(helper), type(uint256).max);
        vm.stopPrank();
    }

    function testAllFourPathsCreditOnlyMsgSenderAndForwardParameters() public {
        factory.setOneVaultPolicyEnabled(false);
        _assertPath(0, usdcVault, 10e18);
        _assertPath(1, usdcVault, 11e18);
        _assertPath(2, usdtVault, 12e18);
        _assertPath(3, usdtVault, 13e18);
        assertEq(usdcVault.getAccount(alice).activeMargin, 21e18);
        assertEq(usdtVault.getAccount(alice).activeMargin, 25e18);
        assertEq(usdcVault.getAccount(address(helper)).activeMargin, 0);
        assertEq(usdtVault.getAccount(address(helper)).activeMargin, 0);
    }

    function testMinMarginSharesRevertsAtomically() public {
        ILCCMarginDepositHelper.DepositParams memory params = _paramsFor(usdcVault, 10e18);
        params.minMarginShares = 10e18 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ILCCMarginDepositHelper.InsufficientMarginShares.selector, 10e18, 10e18 + 1)
        );
        vm.prank(alice);
        helper.depositUSDC(params);
        assertEq(underlyingUSDC.balanceOf(alice), 1_000e18);
        assertEq(waEthUSDC.balanceOf(address(helper)), 0);
    }

    function testMissingOperatorRoleRevertsEntireWrap() public {
        factory.revokeRole(factory.DEPOSIT_OPERATOR_ROLE(), address(helper));
        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.UnauthorizedDepositOperator.selector, address(helper)));
        vm.prank(alice);
        helper.depositUSDC(_paramsFor(usdcVault, 10e18));
        assertEq(underlyingUSDC.balanceOf(alice), 1_000e18);
        assertEq(waEthUSDC.totalSupply(), 0);
    }

    function testBeneficiaryCapAppliesAndHelperNeedsNoCap() public {
        (bool helperCapSet,) = factory.depositorCap(address(helper));
        assertFalse(helperCapSet);
        vm.prank(alice);
        helper.depositUSDC(_paramsFor(usdcVault, 10e18));

        _setDepositorCap(bob, 0);
        underlyingUSDC.mint(bob, 10e18);
        vm.prank(bob);
        underlyingUSDC.approve(address(helper), 10e18);
        vm.expectRevert(LCCErrorsLib.CapExceeded.selector);
        vm.prank(bob);
        helper.depositUSDC(_paramsFor(usdcVault, 10e18));
    }

    function testOneVaultPolicyAndAdmissionsApplyToBeneficiary() public {
        vm.prank(alice);
        helper.depositUSDC(_paramsFor(usdcVault, 10e18));
        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.RegisteredElsewhere.selector, address(usdcVault)));
        vm.prank(alice);
        helper.depositUSDT(_paramsFor(usdtVault, 10e18));

        LCCHelperAdmissionsMock module = new LCCHelperAdmissionsMock();
        module.setAllowed(alice);
        factory.setAdmissionsModule(address(module));
        underlyingUSDC.mint(bob, 10e18);
        vm.prank(bob);
        underlyingUSDC.approve(address(helper), 10e18);
        vm.expectRevert(abi.encodeWithSelector(LCCErrorsLib.AdmissionsModuleRejected.selector, bob, address(usdcVault)));
        vm.prank(bob);
        helper.depositUSDC(_paramsFor(usdcVault, 10e18));
    }

    function testUnregisteredOrWrongMarginVaultRevertsBeforePull() public {
        uint256 allowanceBefore = underlyingUSDC.allowance(alice, address(helper));
        ILCCMarginDepositHelper.DepositParams memory params = _paramsFor(ILCCVault(address(vault)), 10e18);
        vm.expectRevert(ILCCMarginDepositHelper.WrongMarginAsset.selector);
        vm.prank(alice);
        helper.depositUSDC(params);
        assertEq(underlyingUSDC.allowance(alice, address(helper)), allowanceBefore);
        assertEq(underlyingUSDC.balanceOf(alice), 1_000e18);

        params.vault = makeAddr("notVault");
        vm.expectRevert(ILCCMarginDepositHelper.UnregisteredVault.selector);
        vm.prank(alice);
        helper.depositUSDC(params);
        assertEq(underlyingUSDC.balanceOf(alice), 1_000e18);
    }

    function testUSDTNoReturnAndAllowancesAreZeroAfterCompletion() public {
        vm.prank(alice);
        helper.depositUSDT(_paramsFor(usdtVault, 10e18));
        assertEq(underlyingUSDT.allowance(address(helper), address(waEthUSDT)), 0);
        assertEq(waEthUSDT.allowance(address(helper), address(usdtVault)), 0);
        assertEq(usdtVault.getAccount(alice).activeMargin, 10e18);
    }

    function testUnderlyingRespectsMaxDepositButATokenBypassesIt() public {
        waEthUSDC.setMaxDeposit(0);
        vm.expectRevert(abi.encodeWithSelector(ILCCMarginDepositHelper.MaxDepositExceeded.selector, 10e18, 0));
        vm.prank(alice);
        helper.depositUSDC(_paramsFor(usdcVault, 10e18));

        vm.prank(alice);
        helper.depositAethUSDC(_paramsFor(usdcVault, 10e18));
        assertEq(usdcVault.getAccount(alice).activeMargin, 10e18);
    }

    function testATokenIngressAllowsValidScaledBalanceRounding() public {
        LCCRoundedAToken roundedAToken = new LCCRoundedAToken();
        LCCMockStataToken roundedStata =
            new LCCMockStataToken(address(underlyingUSDC), address(roundedAToken), "rounded-waUSDC");
        LCCMarginDepositHelper roundedHelper =
            new LCCMarginDepositHelper(address(factory), address(roundedStata), address(waEthUSDT));
        factory.grantRole(factory.DEPOSIT_OPERATOR_ROLE(), address(roundedHelper));

        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.marginAsset = address(roundedStata);
        ILCCVault roundedVault = _newVault(params);

        roundedAToken.mint(alice, 100);
        vm.prank(alice);
        roundedAToken.approve(address(roundedHelper), 10);
        assertEq(roundedAToken.previewReceived(10), 11, "mock must reproduce adjacent balance rounding");

        vm.prank(alice);
        uint256 commitment = roundedHelper.depositAethUSDC(_paramsFor(roundedVault, 10));
        assertEq(commitment, 20);
        assertEq(roundedAToken.balanceOf(address(roundedHelper)), 0);
        assertEq(roundedVault.getAccount(alice).activeMargin, 10);
    }

    function testReentrancyIsRejected() public {
        ILCCMarginDepositHelper.DepositParams memory params = _paramsFor(usdcVault, 10e18);
        waEthUSDC.armReentry(address(helper), abi.encodeCall(helper.depositUSDC, (params)));
        vm.prank(alice);
        helper.depositUSDC(params);
        assertEq(waEthUSDC.reentryError(), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    }

    function testPreExistingBalancesCannotSubsidizeCaller() public {
        underlyingUSDC.mint(address(helper), 100e18);
        waEthUSDC.mint(address(helper), 50e18);
        address fresh = makeAddr("fresh");
        _setDepositorCap(fresh, type(uint128).max);
        underlyingUSDC.mint(fresh, 10e18);
        vm.prank(fresh);
        underlyingUSDC.approve(address(helper), 10e18);
        vm.prank(fresh);
        uint256 commitment = helper.depositUSDC(_paramsFor(usdcVault, 10e18));
        assertEq(commitment, 20e18);
        assertEq(underlyingUSDC.balanceOf(address(helper)), 100e18);
        assertEq(waEthUSDC.balanceOf(address(helper)), 50e18);
        assertEq(usdcVault.getAccount(fresh).activeMargin, 10e18);
    }

    function testConstructorRejectsBadAssetOrATokenWiring() public {
        LCCBadStataWiring zeroAsset = new LCCBadStataWiring(address(0), address(aTokenUSDC));
        vm.expectRevert(ILCCMarginDepositHelper.InvalidStataToken.selector);
        new LCCMarginDepositHelper(address(factory), address(zeroAsset), address(waEthUSDT));

        LCCBadStataWiring zeroAToken = new LCCBadStataWiring(address(underlyingUSDC), address(0));
        vm.expectRevert(ILCCMarginDepositHelper.InvalidStataToken.selector);
        new LCCMarginDepositHelper(address(factory), address(waEthUSDC), address(zeroAToken));
    }

    function _assertPath(uint256 path, ILCCVault target, uint256 amount) private {
        ILCCMarginDepositHelper.DepositParams memory params = _paramsFor(target, amount);
        vm.prank(alice);
        uint256 commitment;
        if (path == 0) commitment = helper.depositUSDC(params);
        else if (path == 1) commitment = helper.depositAethUSDC(params);
        else if (path == 2) commitment = helper.depositUSDT(params);
        else commitment = helper.depositAethUSDT(params);
        assertEq(commitment, amount * 2);
    }

    function _paramsFor(ILCCVault target, uint256 amount)
        private
        view
        returns (ILCCMarginDepositHelper.DepositParams memory)
    {
        return ILCCMarginDepositHelper.DepositParams({
            vault: address(target),
            amountIn: amount,
            minMarginShares: amount,
            minCommitment: amount * 2,
            maxCommitment: amount * 2,
            allowPendingActivation: false,
            deadline: block.timestamp
        });
    }
}
