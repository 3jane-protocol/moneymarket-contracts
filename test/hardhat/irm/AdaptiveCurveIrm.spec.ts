import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { setNextBlockTimestamp } from "@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time";
import { AbiCoder, keccak256, toBigInt } from "ethers";
import hre from "hardhat";
import _range from "lodash/range";
import {
  AdaptiveCurveIrm,
  MorphoCredit,
  ProtocolConfig,
  ProxyAdmin,
  TransparentUpgradeableProxy,
  USD3Mock,
} from "types";
import { MarketParamsStruct } from "types/lib/morpho-blue/src/interfaces/IIrm";

let seed = 42;
const random = () => {
  seed = (seed * 16807) % 2147483647;

  return (seed - 1) / 2147483646;
};

const identifier = (marketParams: MarketParamsStruct) => {
  const encodedMarket = AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "address", "address", "uint256"],
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

  const newTimestamp = block!.timestamp + elapsed;

  await setNextBlockTimestamp(block!.timestamp + elapsed);

  return newTimestamp;
};

describe("irm", () => {
  let admin: SignerWithAddress;

  let irm: AdaptiveCurveIrm;
  let morphoCredit: MorphoCredit;

  let marketParams: MarketParamsStruct;

  beforeEach(async () => {
    [admin] = await hre.ethers.getSigners();

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

    // Set up IRM configuration values in ProtocolConfig
    await protocolConfig.setConfig(keccak256(Buffer.from("CURVE_STEEPNESS")), 4000000000000000000n); // 4 curve steepness
    await protocolConfig.setConfig(keccak256(Buffer.from("ADJUSTMENT_SPEED")), 13700000000000n); // ~50/365
    await protocolConfig.setConfig(keccak256(Buffer.from("TARGET_UTILIZATION")), 900000000000000000n); // 90% target utilization
    await protocolConfig.setConfig(keccak256(Buffer.from("INITIAL_RATE_AT_TARGET")), 1099511627776n); // 4% initial rate
    await protocolConfig.setConfig(keccak256(Buffer.from("MIN_RATE_AT_TARGET")), 27917066610n); // 0.1% minimum rate
    await protocolConfig.setConfig(keccak256(Buffer.from("MAX_RATE_AT_TARGET")), 50803951983740194816n); // 200% maximum rate

    // Deploy MorphoCredit implementation with ProtocolConfig
    const MorphoCreditFactory = await hre.ethers.getContractFactory("MorphoCredit", admin);
    const morphoCreditImpl = await MorphoCreditFactory.deploy(await protocolConfig.getAddress());

    // Deploy TransparentUpgradeableProxy for MorphoCredit with initialization
    const morphoInitData = MorphoCreditFactory.interface.encodeFunctionData("initialize", [admin.address]);
    const morphoProxy = await TransparentUpgradeableProxyFactory.deploy(
      await morphoCreditImpl.getAddress(),
      await proxyAdmin.getAddress(),
      morphoInitData,
    );

    // Connect to proxy as MorphoCredit interface
    morphoCredit = MorphoCreditFactory.attach(await morphoProxy.getAddress()) as MorphoCredit;

    // Deploy AdaptiveCurveIrm with MorphoCredit address
    const AdaptiveCurveIrmFactory = await hre.ethers.getContractFactory("AdaptiveCurveIrm", admin);

    irm = await AdaptiveCurveIrmFactory.deploy(await morphoCredit.getAddress());

    const irmAddress = await irm.getAddress();

    // Enable IRM in MorphoCredit for later use
    await morphoCredit.enableIrm(irmAddress);
    await morphoCredit.enableLltv(0);

    // Deploy mock tokens and oracle for creating a real market
    const ERC20MockFactory = await hre.ethers.getContractFactory("ERC20Mock", admin);
    const loanToken = await ERC20MockFactory.deploy();
    const collateralToken = await ERC20MockFactory.deploy();

    const OracleMockFactory = await hre.ethers.getContractFactory("OracleMock", admin);
    const oracle = await OracleMockFactory.deploy();

    // Deploy credit line mock
    const CreditLineMockFactory = await hre.ethers.getContractFactory("CreditLineMock", admin);
    const creditLine = await CreditLineMockFactory.deploy(await morphoCredit.getAddress());

    marketParams = {
      collateralToken: await collateralToken.getAddress(),
      loanToken: await loanToken.getAddress(),
      oracle: await oracle.getAddress(),
      irm: irmAddress,
      lltv: 0,
      creditLine: await creditLine.getAddress(),
    };

    // Create the market
    await morphoCredit.createMarket(marketParams);

    hre.tracer.nameTags[irmAddress] = "IRM";
  });

  it("should simulate gas cost [main]", async () => {
    for (let i = 0; i < 200; ++i) {
      logProgress("main", i, 200);

      const lastUpdate = await randomForwardTimestamp();

      const totalSupplyAssets = BigInt.WAD * toBigInt(1 + Math.floor(random() * 100));
      const totalBorrowAssets = totalSupplyAssets.percentMul(toBigInt(Math.floor(random() * BigInt.PERCENT.toFloat())));

      // The IRM can only be called by MorphoCredit, so we need to trigger it indirectly
      // We'll supply some assets and then trigger interest accrual which calls the IRM
      const loanTokenAddress = marketParams.loanToken;
      const ERC20MockFactory = await hre.ethers.getContractFactory("ERC20Mock", admin);
      const loanToken = ERC20MockFactory.attach(loanTokenAddress);

      // Deploy USD3Mock
      const USD3MockFactory = await hre.ethers.getContractFactory("USD3Mock", admin);
      const usd3 = await USD3MockFactory.deploy(await morphoCredit.getAddress());

      // Set USD3 to enable supply operations
      await morphoCredit.setUsd3(await usd3.getAddress());

      // Mint tokens and approve USD3 (not morphoCredit)
      await loanToken.setBalance(admin.address, totalSupplyAssets);
      await loanToken.connect(admin).approve(await usd3.getAddress(), totalSupplyAssets);

      // Supply to trigger market creation and IRM usage
      await usd3.connect(admin).supply(marketParams, totalSupplyAssets, 0, admin.address, "0x");
    }
  });
});
