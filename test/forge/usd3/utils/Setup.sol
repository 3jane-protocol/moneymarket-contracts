// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUSD3} from "../../../../src/usd3/interfaces/IUSD3.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

// Add imports for USD3 testing
import {USD3} from "../../../../src/usd3/USD3.sol";
import {IMorpho, MarketParams, Id} from "../../../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {IrmMock} from "../../../../src/mocks/IrmMock.sol";
import {HelperMock} from "../../../../src/mocks/HelperMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from
    "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStrategyFactory} from "../mocks/MockStrategyFactory.sol";
import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is Test, IEvents {
    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    ERC20 public underlyingAsset;
    IUSD3 public strategy;

    // StrategyFactory not used in this test setup

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Address of the real deployed Factory
    address public factory;

    // Helper contract for MorphoCredit operations
    HelperMock public helper;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    uint256 public maxFuzzAmount = 1_000_000_000e6;
    uint256 public minFuzzAmount = 0.01e6;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        _setTokenAddrs();

        // Set underlying asset (USDC)
        underlyingAsset = ERC20(tokenAddrs["USDC"]);

        // Deploy and etch TokenizedStrategy at the expected address
        _deployTokenizedStrategy();

        // Deploy strategy and set variables
        strategy = IUSD3(setUpStrategy());

        factory = strategy.FACTORY();

        // Set decimals after asset is set in setUpStrategy
        decimals = asset.decimals();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(address(underlyingAsset), "underlyingAsset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        // Deploy MockProtocolConfig for testing
        MockProtocolConfig protocolConfig = new MockProtocolConfig();

        // Deploy real MorphoCredit with proxy pattern
        MorphoCredit morphoImpl = new MorphoCredit(address(protocolConfig));

        // Deploy proxy admin
        address morphoOwner = makeAddr("MorphoOwner");
        address proxyAdminOwner = makeAddr("ProxyAdminOwner");
        ProxyAdmin proxyAdmin = new ProxyAdmin(proxyAdminOwner);

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(MorphoCredit.initialize.selector, morphoOwner);
        TransparentUpgradeableProxy morphoProxy =
            new TransparentUpgradeableProxy(address(morphoImpl), address(proxyAdmin), initData);

        IMorpho morpho = IMorpho(address(morphoProxy));

        // Use USDC directly as the asset
        asset = underlyingAsset;

        // Deploy IRM mock for interest accrual
        IrmMock irm = new IrmMock();

        // Deploy CreditLineMock for the market
        CreditLineMock creditLineMock = new CreditLineMock(address(morpho));

        // Set up market params for credit-based lending
        MarketParams memory marketParams = MarketParams({
            loanToken: address(asset),
            collateralToken: address(underlyingAsset), // Use USDC as collateral token
            oracle: address(0), // Not needed for credit
            irm: address(irm), // Use the IRM mock
            lltv: 0, // Credit-based lending
            creditLine: address(creditLineMock)
        });

        // Enable market parameters
        vm.startPrank(morphoOwner);
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0);
        morpho.createMarket(marketParams);
        vm.stopPrank();

        // Deploy USD3 implementation
        USD3 usd3Implementation = new USD3();

        // Deploy proxy admin
        ProxyAdmin usd3ProxyAdmin = new ProxyAdmin(proxyAdminOwner);

        // Deploy proxy with initialization
        bytes memory usd3InitData = abi.encodeWithSelector(
            USD3.initialize.selector, address(morpho), MarketParamsLib.id(marketParams), management, keeper
        );

        TransparentUpgradeableProxy usd3Proxy =
            new TransparentUpgradeableProxy(address(usd3Implementation), address(usd3ProxyAdmin), usd3InitData);

        // Set emergency admin
        vm.prank(management);
        IUSD3(address(usd3Proxy)).setEmergencyAdmin(emergencyAdmin);

        // Set USD3 address on MorphoCredit for access control
        vm.prank(morphoOwner);
        MorphoCredit(address(morpho)).setUsd3(address(usd3Proxy));

        // Deploy and set helper for borrowing operations
        helper = new HelperMock(address(morpho));
        vm.prank(morphoOwner);
        MorphoCredit(address(morpho)).setHelper(address(helper));

        return address(usd3Proxy);
    }

    function depositIntoStrategy(IUSD3 _strategy, address _user, uint256 _amount) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(IUSD3 _strategy, address _user, uint256 _amount) public {
        // Mint asset (USDC) to user
        airdrop(asset, _user, _amount);

        // Approve and deposit to strategy
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(IUSD3 _strategy, uint256 _totalAssets, uint256 _totalDebt, uint256 _totalIdle)
        public
    {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        // Use a mock ERC20 for testing instead of real USDC
        // Real USDC has proxy implementation that causes issues in tests
        MockERC20 mockUsdc = new MockERC20("USD Coin", "USDC", 6);
        tokenAddrs["USDC"] = address(mockUsdc);
    }

    function _deployTokenizedStrategy() internal {
        // Deploy a mock factory for the TokenizedStrategy
        MockStrategyFactory mockFactory = new MockStrategyFactory();

        // Deploy the TokenizedStrategy implementation
        TokenizedStrategy tokenizedStrategyImpl = new TokenizedStrategy(address(mockFactory));

        // Etch the TokenizedStrategy bytecode at the expected hardcoded address
        // This address is used by BaseStrategyUpgradeable for delegate calls
        address expectedAddress = 0xD377919FA87120584B21279a491F82D5265A139c;
        vm.etch(expectedAddress, address(tokenizedStrategyImpl).code);

        // Also set the storage slot for the immutable FACTORY variable
        // The FACTORY immutable is stored at the address itself in bytecode
        // We need to ensure it's properly set in the etched code

        // Label for debugging
        vm.label(expectedAddress, "TokenizedStrategy");
        vm.label(address(mockFactory), "MockStrategyFactory");
    }
}
