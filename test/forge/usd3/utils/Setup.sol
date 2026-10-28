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
import {USD3_old} from "../../../../src/usd3/USD3_old.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {IMorpho, MarketParams, Id} from "../../../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {IrmMock} from "../../../../src/mocks/IrmMock.sol";
import {HelperMock} from "../../../../src/mocks/HelperMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "../../../../lib/openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStrategyFactory} from "../mocks/MockStrategyFactory.sol";
import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";
import {MockWaUSDC} from "../mocks/MockWaUSDC.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is Test, IEvents {
    bytes32 internal constant INITIALIZABLE_STORAGE_SLOT =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    ERC20 public underlyingAsset;
    MockWaUSDC public waUSDC;
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

    // ProtocolConfig for managing protocol parameters (internal to avoid conflicts)
    MockProtocolConfig internal testProtocolConfig;

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

        // Deploy and etch MockWaUSDC at the expected address
        _deployWaUSDC();

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
        vm.label(address(waUSDC), "waUSDC");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        // Deploy MockProtocolConfig for testing
        testProtocolConfig = new MockProtocolConfig();

        // Set a high default debt cap to allow sUSD3 deposits in tests
        // Tests that need specific debt cap scenarios can override this
        testProtocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, 100_000_000e6); // 100M USDC default

        // Deploy real MorphoCredit with proxy pattern
        MorphoCredit morphoImpl = new MorphoCredit(address(testProtocolConfig));

        // Deploy proxy admin
        address morphoOwner = makeAddr("MorphoOwner");
        address proxyAdminOwner = makeAddr("ProxyAdminOwner");
        ProxyAdmin proxyAdmin = new ProxyAdmin(proxyAdminOwner);

        // Deploy proxy with initialization
        bytes memory morphoInitData = abi.encodeWithSelector(MorphoCredit.initialize.selector, morphoOwner);
        TransparentUpgradeableProxy morphoProxy =
            new TransparentUpgradeableProxy(address(morphoImpl), address(proxyAdmin), morphoInitData);

        IMorpho morpho = IMorpho(address(morphoProxy));

        // Use USDC as the asset (USD3 now accepts USDC)
        asset = underlyingAsset;

        // Deploy IRM mock for interest accrual
        IrmMock irm = new IrmMock();

        // Deploy CreditLineMock for the market
        CreditLineMock creditLineMock = new CreditLineMock(address(morpho));

        // Set up market params for credit-based lending
        // MorphoCredit uses waUSDC as loanToken
        MarketParams memory marketParams = MarketParams({
            loanToken: address(waUSDC),
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

        // Bootstrap the proxy the way mainnet reached the current state: deploy the frozen prior implementation,
        // walk it through the waUSDC->USDC asset migration, then upgrade to the current USD3 logic.
        (USD3_old oldUsd3, ProxyAdmin usd3ProxyAdmin) =
            _deployFrozenUsd3Proxy(address(morpho), MarketParamsLib.id(marketParams), proxyAdminOwner);
        _forceMainnetInitializerVersion(address(oldUsd3));
        USD3 newImpl = new USD3();
        vm.prank(proxyAdminOwner);
        usd3ProxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(oldUsd3)), address(newImpl), "");

        // Set emergency admin
        vm.prank(management);
        IUSD3(address(oldUsd3)).setEmergencyAdmin(emergencyAdmin);

        // Set USD3 address on MorphoCredit for access control
        vm.prank(morphoOwner);
        MorphoCredit(address(morpho)).setUsd3(address(oldUsd3));

        // Deploy and set helper for borrowing operations
        helper = new HelperMock(address(morpho));
        vm.prank(morphoOwner);
        MorphoCredit(address(morpho)).setHelper(address(helper));

        return address(oldUsd3);
    }

    /// @dev Deploys a frozen USD3_old proxy and walks it through the mainnet asset migration: initialize
    /// (asset = waUSDC) then reinitialize (asset = USDC). Returns the proxy typed as USD3_old and the
    /// ProxyAdmin the transparent proxy generated for `proxyOwner`. Shared by the base strategy setup and the
    /// upgrade regression test so the bootstrap idiom lives in one place.
    function _deployFrozenUsd3Proxy(address morphoCredit_, Id marketId_, address proxyOwner)
        internal
        returns (USD3_old oldUsd3, ProxyAdmin proxyAdmin)
    {
        USD3_old oldImpl = new USD3_old();
        bytes memory initData =
            abi.encodeWithSelector(USD3_old.initialize.selector, morphoCredit_, marketId_, management, keeper);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(oldImpl), proxyOwner, initData);
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.ADMIN_SLOT)))));
        oldUsd3 = USD3_old(address(proxy));
        oldUsd3.reinitialize();
    }

    function _forceMainnetInitializerVersion(address proxy) internal {
        // Models mainnet's consumed reinitializer(3): the current upgrade-from logic carries no restart hook, so
        // the initializer version is set directly rather than by calling one.
        vm.store(proxy, INITIALIZABLE_STORAGE_SLOT, bytes32(uint256(3)));
    }

    function setUpSUSD3() internal returns (sUSD3 susd3Strategy) {
        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);
        TransparentUpgradeableProxy susd3Proxy = new TransparentUpgradeableProxy(
            address(susd3Implementation),
            address(susd3ProxyAdmin),
            abi.encodeCall(sUSD3.initialize, (address(strategy), management, keeper))
        );
        susd3Strategy = sUSD3(address(susd3Proxy));

        vm.prank(management);
        USD3(address(strategy)).setSUSD3(address(susd3Strategy));
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
    function checkStrategyTotals(IUSD3 _strategy, uint256 _totalAssets, uint256 _totalDebt, uint256 _totalIdle) public {
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

    function setMaxOnCredit(uint256 _maxOnCredit) public {
        // Set maxOnCredit through ProtocolConfig
        bytes32 MAX_ON_CREDIT_KEY = keccak256("MAX_ON_CREDIT");
        testProtocolConfig.setConfig(MAX_ON_CREDIT_KEY, _maxOnCredit);
    }

    function setMorphoDebtCap(uint256 _debtCap) public {
        // Set DEBT_CAP through ProtocolConfig
        testProtocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, _debtCap);
    }

    /**
     * @notice Create market debt by setting up a borrower with a credit line and borrowing
     * @param borrower Address that will borrow
     * @param borrowAmountUSDC Amount to borrow in USDC terms
     */
    function createMarketDebt(address borrower, uint256 borrowAmountUSDC) public {
        // Get the market ID from USD3 strategy
        Id marketId = USD3(address(strategy)).marketId();
        MarketParams memory marketParams = USD3(address(strategy)).marketParams();
        IMorpho morpho = USD3(address(strategy)).morphoCredit();

        // First ensure USD3 has deployed funds to the market by calling report
        // This moves idle USDC to the lending market
        vm.prank(keeper);
        strategy.report();

        // Create a payment cycle to allow borrowing
        // CreditLineMock can call closeCycleAndPostObligations
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        // Set cycle end date to current timestamp (closing the cycle "now")
        uint256 cycleEndDate = block.timestamp;
        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho))
            .closeCycleAndPostObligations(marketId, cycleEndDate, borrowers, repaymentBps, endingBalances);

        // Use USDC amount directly as waUSDC amount (they're 1:1 initially)
        uint256 borrowAmountWaUSDC = borrowAmountUSDC;

        // Set credit line for borrower (double the borrow amount for safety)
        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho)).setCreditLine(marketId, borrower, borrowAmountWaUSDC * 2, 0);

        // Execute borrow through helper - only helper is authorized to borrow
        vm.prank(borrower);
        helper.borrow(marketParams, borrowAmountWaUSDC, 0, borrower, borrower);
    }

    function _setTokenAddrs() internal {
        // Deploy mock USDC at the mainnet address; the frozen USD3_old reinitialize() hardcodes it.
        address expectedUsdcAddress = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // Deploy the mock USDC
        MockERC20 mockUsdc = new MockERC20("USD Coin", "USDC", 6);

        // Etch it at the expected address
        vm.etch(expectedUsdcAddress, address(mockUsdc).code);

        // Store decimals in storage slot 5 (after ERC20's slots 0-4)
        vm.store(expectedUsdcAddress, bytes32(uint256(5)), bytes32(uint256(6)));

        tokenAddrs["USDC"] = expectedUsdcAddress;
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

    function _deployWaUSDC() internal {
        // Deploy MockWaUSDC with USDC as underlying
        address usdcAddress = tokenAddrs["USDC"];

        // Deploy at the expected mainnet address
        address expectedWaUSDCAddress = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;

        // Deploy the mock contract
        MockWaUSDC mockWaUSDC = new MockWaUSDC(usdcAddress);

        // Etch the bytecode at the expected address
        vm.etch(expectedWaUSDCAddress, address(mockWaUSDC).code);

        // Store the USDC address in storage slot 5 (where _asset is stored after ERC20 storage)
        // ERC20 uses slots 0-4 for: _balances(0), _allowances(1), _totalSupply(2), _name(3), _symbol(4)
        vm.store(expectedWaUSDCAddress, bytes32(uint256(5)), bytes32(uint256(uint160(usdcAddress))));

        // Store the sharePrice in storage slot 6 (initialized to 1e6)
        vm.store(expectedWaUSDCAddress, bytes32(uint256(6)), bytes32(uint256(1e6)));

        // Store the reference
        waUSDC = MockWaUSDC(expectedWaUSDCAddress);

        // Label for debugging
        vm.label(expectedWaUSDCAddress, "MockWaUSDC");
    }
}
