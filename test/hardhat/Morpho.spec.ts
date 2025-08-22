import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { setNextBlockTimestamp } from "@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time";
import { expect } from "chai";
import { AbiCoder, MaxUint256, ZeroAddress, keccak256, toBigInt } from "ethers";
import hre from "hardhat";
import {
  Morpho,
  MorphoCredit,
  OracleMock,
  ERC20Mock,
  IrmMock,
  ProxyAdmin,
  TransparentUpgradeableProxy,
  ProtocolConfig,
  USD3Mock,
  HelperMock,
} from "types";
import { MarketParamsStruct } from "types/src/Morpho";
import { CreditLineMock } from "types/src/mocks/CreditLineMock";
import { FlashBorrowerMock } from "types/src/mocks/FlashBorrowerMock";

// Cycle duration for credit line markets (30 days)
const CYCLE_DURATION = 30 * 24 * 60 * 60;

const closePositions = false;
// Without the division it overflows.
const initBalance = MaxUint256 / 10000000000000000n;
const oraclePriceScale = 1000000000000000000000000000000000000n;

let seed = 42;
const random = () => {
  seed = (seed * 16807) % 2147483647;

  return (seed - 1) / 2147483646;
};

const identifier = (marketParams: MarketParamsStruct) => {
  const encodedMarket = AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "address", "address", "uint256", "address"],
    Object.values(marketParams),
  );

  return Buffer.from(keccak256(encodedMarket).slice(2), "hex");
};

const logProgress = (name: string, i: number, max: number) => {
  if (i % 10 == 0) console.log("[" + name + "]", Math.floor((100 * i) / max), "%");
};

const randomForwardTimestamp = async () => {
  const block = await hre.ethers.provider.getBlock("latest");
  const elapsed = random() < 1 / 2 ? 0 : (1 + Math.floor(random() * 100)) * 12; // 50% of the time, don't go forward in time.

  await setNextBlockTimestamp(block!.timestamp + elapsed);
};

// Helper function to ensure market with credit line has active cycles
// Required after market freeze refactor - markets without active cycles are frozen
const ensureMarketActive = async (
  morpho: MorphoCredit,
  creditLineAddress: string,
  marketId: Buffer,
  cycleDuration: number,
) => {
  const block = await hre.ethers.provider.getBlock("latest");
  const cycleEnd = block!.timestamp + cycleDuration;
  await setNextBlockTimestamp(cycleEnd);

  // Impersonate the credit line contract to call closeCycleAndPostObligations
  await hre.network.provider.request({
    method: "hardhat_impersonateAccount",
    params: [creditLineAddress],
  });

  // Fund the credit line with some ETH for gas
  await hre.network.provider.send("hardhat_setBalance", [
    creditLineAddress,
    "0x1000000000000000000", // 1 ETH
  ]);

  const creditLineSigner = await hre.ethers.getSigner(creditLineAddress);

  // Call closeCycleAndPostObligations as the credit line contract
  await morpho.connect(creditLineSigner).closeCycleAndPostObligations(
    marketId,
    cycleEnd,
    [], // no borrowers
    [], // no repayment percentages
    [], // no ending balances
  );

  // Stop impersonating
  await hre.network.provider.request({
    method: "hardhat_stopImpersonatingAccount",
    params: [creditLineAddress],
  });
};

describe("Morpho", () => {
  let admin: SignerWithAddress;
  let liquidator: SignerWithAddress;
  let suppliers: SignerWithAddress[];
  let borrowers: SignerWithAddress[];

  let morpho: Morpho;
  let loanToken: ERC20Mock;
  let collateralToken: ERC20Mock;
  let oracle: OracleMock;
  let irm: IrmMock;
  let creditLine: CreditLineMock;
  let flashBorrower: FlashBorrowerMock;
  let usd3: USD3Mock;
  let helper: HelperMock;

  let marketParams: MarketParamsStruct;
  let id: Buffer;

  const updateMarket = (newMarket: Partial<MarketParamsStruct>) => {
    marketParams = { ...marketParams, ...newMarket };
    id = identifier(marketParams);
  };

  beforeEach(async () => {
    const allSigners = await hre.ethers.getSigners();

    const users = allSigners.slice(0, -2);

    [admin, liquidator] = allSigners.slice(-2);
    suppliers = users.slice(0, users.length / 2);
    borrowers = users.slice(users.length / 2);

    const ERC20MockFactory = await hre.ethers.getContractFactory("ERC20Mock", admin);

    loanToken = await ERC20MockFactory.deploy();
    collateralToken = await ERC20MockFactory.deploy();

    const OracleMockFactory = await hre.ethers.getContractFactory("OracleMock", admin);

    oracle = await OracleMockFactory.deploy();

    await oracle.setPrice(oraclePriceScale);

    // Deploy ProtocolConfig implementation
    const ProtocolConfigFactory = await hre.ethers.getContractFactory("ProtocolConfig", admin);
    const protocolConfigImpl = await ProtocolConfigFactory.deploy();

    // Deploy ProxyAdmin
    const ProxyAdminFactory = await hre.ethers.getContractFactory("ProxyAdmin", admin);
    const proxyAdmin = await ProxyAdminFactory.deploy(admin.address);

    // Deploy TransparentUpgradeableProxy for ProtocolConfig with initialization
    const TransparentUpgradeableProxyFactory = await hre.ethers.getContractFactory(
      "TransparentUpgradeableProxy",
      admin,
    );
    const protocolConfigInitData = ProtocolConfigFactory.interface.encodeFunctionData("initialize", [admin.address]);
    const protocolConfigProxy = await TransparentUpgradeableProxyFactory.deploy(
      await protocolConfigImpl.getAddress(),
      await proxyAdmin.getAddress(),
      protocolConfigInitData,
    );

    const protocolConfig = ProtocolConfigFactory.attach(await protocolConfigProxy.getAddress()) as ProtocolConfig;

    // Set cycle duration in ProtocolConfig (required for credit line markets)
    await protocolConfig
      .connect(admin)
      .setConfig(hre.ethers.keccak256(hre.ethers.toUtf8Bytes("CYCLE_DURATION")), CYCLE_DURATION);

    // Deploy MorphoCredit implementation with ProtocolConfig
    const MorphoCreditFactory = await hre.ethers.getContractFactory("MorphoCredit", admin);
    const morphoImpl = await MorphoCreditFactory.deploy(await protocolConfig.getAddress());

    // Deploy TransparentUpgradeableProxy for MorphoCredit with initialization
    const morphoInitData = MorphoCreditFactory.interface.encodeFunctionData("initialize", [admin.address]);
    const morphoProxy = await TransparentUpgradeableProxyFactory.deploy(
      await morphoImpl.getAddress(),
      await proxyAdmin.getAddress(),
      morphoInitData,
    );

    // Connect to proxy as MorphoCredit interface
    morpho = MorphoCreditFactory.attach(await morphoProxy.getAddress()) as MorphoCredit;

    // Deploy USD3Mock
    const USD3MockFactory = await hre.ethers.getContractFactory("USD3Mock", admin);
    usd3 = await USD3MockFactory.deploy(await morpho.getAddress());

    // Deploy HelperMock
    const HelperMockFactory = await hre.ethers.getContractFactory("HelperMock", admin);
    helper = await HelperMockFactory.deploy(await morpho.getAddress());

    // Set USD3 and Helper to enable operations
    await morpho.setUsd3(await usd3.getAddress());
    await morpho.setHelper(await helper.getAddress());

    const IrmMockFactory = await hre.ethers.getContractFactory("IrmMock", admin);

    irm = await IrmMockFactory.deploy();

    const CreditLineMockFactory = await hre.ethers.getContractFactory("CreditLineMock", admin);
    creditLine = await CreditLineMockFactory.deploy(await morpho.getAddress());

    updateMarket({
      loanToken: await loanToken.getAddress(),
      collateralToken: await collateralToken.getAddress(),
      oracle: await oracle.getAddress(),
      irm: await irm.getAddress(),
      lltv: BigInt.WAD / 2n + 1n,
      creditLine: await creditLine.getAddress(),
    });

    await morpho.enableLltv(marketParams.lltv);
    await morpho.enableIrm(marketParams.irm);
    await morpho.createMarket(marketParams);

    // Initialize first payment cycle to unfreeze the market
    // Required for credit line markets after the market freeze refactor
    await ensureMarketActive(morpho as MorphoCredit, await creditLine.getAddress(), id, CYCLE_DURATION);

    const morphoAddress = await morpho.getAddress();
    const usd3Address = await usd3.getAddress();
    const helperAddress = await helper.getAddress();

    for (const user of users) {
      await loanToken.setBalance(user.address, initBalance);
      await loanToken.connect(user).approve(usd3Address, MaxUint256); // Approve USD3 for supply/withdraw
      await loanToken.connect(user).approve(helperAddress, MaxUint256); // Approve Helper for repay
      await collateralToken.setBalance(user.address, initBalance);
      await collateralToken.connect(user).approve(morphoAddress, MaxUint256);
    }

    await loanToken.setBalance(admin.address, initBalance);
    await loanToken.connect(admin).approve(usd3Address, MaxUint256); // Approve USD3
    await loanToken.connect(admin).approve(helperAddress, MaxUint256); // Approve Helper

    await loanToken.setBalance(liquidator.address, initBalance);
    await loanToken.connect(liquidator).approve(usd3Address, MaxUint256); // Approve USD3
    await loanToken.connect(liquidator).approve(helperAddress, MaxUint256); // Approve Helper

    const FlashBorrowerFactory = await hre.ethers.getContractFactory("FlashBorrowerMock", admin);

    flashBorrower = await FlashBorrowerFactory.deploy(morphoAddress);
  });

  it("should simulate gas cost [main]", async () => {
    for (let i = 0; i < suppliers.length; ++i) {
      logProgress("main", i, suppliers.length);

      const supplier = suppliers[i];

      let assets = BigInt.WAD * toBigInt(1 + Math.floor(random() * 100));

      await randomForwardTimestamp();

      await usd3.connect(supplier).supply(marketParams, assets, 0, supplier.address, "0x");

      await randomForwardTimestamp();

      await usd3.connect(supplier).withdraw(marketParams, assets / 2n, 0, supplier.address, supplier.address);

      const borrower = borrowers[i];

      const market = await morpho.market(id);
      const liquidity = market.totalSupplyAssets - market.totalBorrowAssets;

      assets = assets.min(liquidity / 2n);

      await randomForwardTimestamp();

      await creditLine.setCreditLine(id, borrower.address, assets * 2n, 0);

      await randomForwardTimestamp();

      await helper.connect(borrower).borrow(marketParams, assets / 2n, 0, borrower.address, borrower.address);

      await randomForwardTimestamp();

      await helper.connect(borrower).repay(marketParams, assets / 4n, 0, borrower.address, "0x");

      await randomForwardTimestamp();
    }
  });

  it("should simulate gas cost [idle]", async () => {
    updateMarket({
      loanToken: await loanToken.getAddress(),
      collateralToken: ZeroAddress,
      oracle: ZeroAddress,
      irm: ZeroAddress,
      lltv: 0,
    });

    await morpho.enableLltv(0);
    await morpho.enableIrm(ZeroAddress);
    await morpho.createMarket(marketParams);

    for (let i = 0; i < suppliers.length; ++i) {
      logProgress("idle", i, suppliers.length);

      const supplier = suppliers[i];

      let assets = BigInt.WAD * toBigInt(1 + Math.floor(random() * 100));

      await randomForwardTimestamp();

      await usd3.connect(supplier).supply(marketParams, assets, 0, supplier.address, "0x");

      await randomForwardTimestamp();

      await usd3.connect(supplier).withdraw(marketParams, assets / 2n, 0, supplier.address, supplier.address);
    }
  });

  it("should simuate gas cost [flashLoans]", async () => {
    const user = borrowers[0];
    const assets = BigInt.WAD;

    await usd3.connect(user).supply(marketParams, assets, 0, user.address, "0x");

    const loanAddress = await loanToken.getAddress();

    const data = AbiCoder.defaultAbiCoder().encode(["address"], [loanAddress]);
    await flashBorrower.flashLoan(loanAddress, assets / 2n, data);
  });
});
