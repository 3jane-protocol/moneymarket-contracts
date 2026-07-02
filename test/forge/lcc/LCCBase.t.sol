// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {ERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "../../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LeveragedCallableCreditVault} from "../../../src/lcc/LeveragedCallableCreditVault.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";

contract LCCMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract LCCMockUSD3 is ERC4626 {
    uint256 internal depositLimit = type(uint256).max;
    uint256 internal minDeposit;
    bool internal depositHookReverts;
    mapping(address => bool) internal supplyCapExempt;

    constructor(IERC20 asset_) ERC20("Mock USD3", "mUSD3") ERC4626(asset_) {}

    function setDepositLimit(uint256 limit) external {
        depositLimit = limit;
    }

    function setDepositHookReverts(bool reverts) external {
        depositHookReverts = reverts;
    }

    function setMinDeposit(uint256 minDeposit_) external {
        minDeposit = minDeposit_;
    }

    function setSupplyCapExempt(address account, bool exempt) external {
        supplyCapExempt[account] = exempt;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return depositLimit;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        require(!depositHookReverts, "!allowed");
        if (balanceOf(receiver) == 0 && !supplyCapExempt[receiver]) require(assets >= minDeposit, "<min");
        return super.deposit(assets, receiver);
    }
}

contract LCCMockNotificationVault is ERC4626 {
    bool internal depositHookReverts;

    constructor(IERC20 asset_) ERC20("Mock Notification USD3", "mnUSD3") ERC4626(asset_) {}

    function setDepositHookReverts(bool reverts) external {
        depositHookReverts = reverts;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        require(!depositHookReverts, "!notification");
        return super.deposit(assets, receiver);
    }
}

contract LCCRevertingOracle is IOracle {
    function price() external pure returns (uint256) {
        revert("ORACLE_DOWN");
    }
}

contract LCCBase is Test {
    uint256 internal constant START = 1_000;
    uint256 internal constant EPOCH = 100;
    uint256 internal constant NORMAL = 40;
    uint256 internal constant PRE_CALL = 20;
    uint256 internal constant FUNDING = 20;
    uint256 internal constant CAP = 10_000_000e18;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    LCCMockToken internal margin;
    LCCMockToken internal usdc;
    LCCMockUSD3 internal usd3;
    LCCMockNotificationVault internal notificationVault;
    OracleMock internal oracle;
    LeveragedCallableCreditVault internal vault;

    function setUp() public virtual {
        vm.warp(START);
        margin = new LCCMockToken("Margin", "MRG");
        usdc = new LCCMockToken("USD Coin", "USDC");
        usd3 = new LCCMockUSD3(IERC20(address(usdc)));
        notificationVault = new LCCMockNotificationVault(IERC20(address(usd3)));
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);

        vault = new LeveragedCallableCreditVault(_params(address(oracle), CAP, CAP, 2_000));

        _mintAndApprove(alice, 1_000_000e18, 1_000_000e18);
        _mintAndApprove(bob, 1_000_000e18, 1_000_000e18);
        _mintAndApprove(carol, 1_000_000e18, 1_000_000e18);
    }

    function _params(uint256 protocolCap, uint256 userCap)
        internal
        view
        returns (ILeveragedCallableCreditVault.VaultParams memory)
    {
        return _params(address(oracle), protocolCap, userCap, 2_000);
    }

    function _params(address oracle_, uint256 protocolCap, uint256 userCap, uint256 exitCapBps)
        internal
        view
        returns (ILeveragedCallableCreditVault.VaultParams memory)
    {
        return ILeveragedCallableCreditVault.VaultParams({
            owner: owner,
            marginAsset: address(margin),
            fundingAsset: address(usdc),
            notificationVault: address(notificationVault),
            marginOracle: oracle_,
            treasury: treasury,
            startTimestamp: START,
            epochLength: EPOCH,
            normalDuration: NORMAL,
            preCallDuration: PRE_CALL,
            fundingDuration: FUNDING,
            marginRatioBps: 5_000,
            protocolCommitmentCap: protocolCap,
            userCommitmentCap: userCap,
            exitCapBps: exitCapBps,
            exitDelayEpochs: 1,
            minDepositAssets: 0,
            auctionStepCount: 0,
            auctionStepDecayRateBps: 0,
            maxAuctionAwardBps: 0,
            slashFeeBps: 1_000
        });
    }

    function _auctionParams() internal view returns (ILeveragedCallableCreditVault.VaultParams memory params) {
        params = _params(CAP, CAP);
        // 20s Closed window split into 4 steps of 5s, halving the retained share each step.
        params.auctionStepCount = 4;
        params.auctionStepDecayRateBps = 5_000;
        params.maxAuctionAwardBps = 10_000;
    }

    function _deployAuctionVault() internal {
        _deployVaultWithParams(_auctionParams());
    }

    function _deployVaultWithParams(ILeveragedCallableCreditVault.VaultParams memory params) internal {
        vault = new LeveragedCallableCreditVault(params);
        _mintAndApprove(alice, 0, 0);
        _mintAndApprove(bob, 0, 0);
        _mintAndApprove(carol, 0, 0);
    }

    function _mintAndApprove(address user, uint256 marginAmount, uint256 usdcAmount) internal {
        margin.mint(user, marginAmount);
        usdc.mint(user, usdcAmount);

        vm.startPrank(user);
        margin.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 commitment) {
        vm.prank(user);
        commitment = vault.deposit(assets, user);
    }

    function _openCall(uint256 amount) internal {
        vm.warp(START + NORMAL);
        vm.prank(owner);
        vault.openEpochCall(0, amount);
    }

    function _fund(address user) internal returns (uint256 obligation) {
        vm.warp(START + NORMAL + PRE_CALL);
        vm.prank(user);
        obligation = vault.fundCall();
    }

    function _fundFor(address payer, address user) internal returns (uint256 obligation) {
        vm.warp(START + NORMAL + PRE_CALL);
        vm.prank(payer);
        obligation = vault.fundCall(user);
    }

    function _finishFunding() internal {
        vm.warp(START + NORMAL + PRE_CALL + FUNDING);
    }

    function _syncAs(address user) internal {
        vm.prank(user);
        vault.materializeAccount(user);
    }
}
