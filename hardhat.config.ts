import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-foundry";
import "@nomicfoundation/hardhat-network-helpers";
import "@typechain/hardhat";
import * as dotenv from "dotenv";
import "ethers-maths";
import "hardhat-gas-reporter";
import "hardhat-tracer";
import { TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD } from "hardhat/builtin-tasks/task-names";
import { HardhatUserConfig } from "hardhat/config";
import { subtask } from "hardhat/config";

dotenv.config();

const LCC_SOLC_VERSION = "0.8.35";
const LCC_SOLC_LONG_VERSION = "0.8.35+commit.47b9dedd";

subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD).setAction(async ({ solcVersion }, _, runSuper) => {
  if (solcVersion !== LCC_SOLC_VERSION) return runSuper();

  const compiler = require("solc-0.8.35");
  const compilerLongVersion = compiler.version();
  if (!compilerLongVersion.startsWith(LCC_SOLC_LONG_VERSION)) {
    throw new Error(`Expected ${LCC_SOLC_LONG_VERSION}, found ${compiler.version()}`);
  }

  return {
    compilerPath: require.resolve("solc-0.8.35/soljson.js"),
    isSolcJs: true,
    version: LCC_SOLC_VERSION,
    longVersion: compilerLongVersion,
  };
});

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  paths: {
    sources: "./src",
    tests: "./test/hardhat",
    artifacts: "./artifacts",
    cache: "./cache_hardhat",
  },
  networks: {
    hardhat: {
      chainId: 1,
      gasPrice: 1000000000, // 1 gwei
      initialBaseFeePerGas: 1,
      allowBlocksWithSameTimestamp: true,
      allowUnlimitedContractSize: true, // Allow contracts larger than 24KB for testing
      accounts: {
        count: 202, // must be even
      },
    },
  },
  solidity: {
    compilers: [
      {
        version: "0.8.19",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1, // Minimize size at the cost of gas efficiency
            details: {
              yul: true,
              yulDetails: {
                stackAllocation: true,
                optimizerSteps: "dhfoDgvulfnTUtnIf[lpf]",
              },
            },
          },
          viaIR: true,
          outputSelection: {
            "*": {
              "*": ["metadata", "evm.bytecode", "evm.deployedBytecode"],
              "": ["ast"],
            },
          },
        },
      },
      {
        version: "0.8.22",
        settings: {
          optimizer: {
            enabled: true,
            runs: 4294967295,
          },
          viaIR: true,
        },
      },
      {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 4294967295,
          },
          viaIR: true,
        },
      },
    ],
    // Mirrors the Foundry per-file optimizer and EVM settings for compilation and tests. Forge remains the sole
    // canonical LCC deployment artifact. USD3.sol pins the measured 999999 runs explicitly
    // because non-overridden 0.8.22 sources compile under the compilers-block entry above at 4294967295
    // runs, an unmeasured artifact for USD3) without letting 0.8.35 capture every other ^0.8.x source.
    overrides: Object.fromEntries(
      (
        [
          ["src/usd3/USD3.sol", "0.8.22", 999999, "shanghai"],
          ["src/usd3/USD3_old.sol", "0.8.22", 200, "shanghai"],
          ["src/lcc/LCCVault.sol", "0.8.35", 300, "cancun"],
          ["src/lcc/LCCVaultFactory.sol", "0.8.35", 999999, "cancun"],
          ["src/lcc/interfaces/ILCCVault.sol", "0.8.35", 999999, "cancun"],
          ["src/lcc/libraries/LCCAccountLib.sol", "0.8.35", 999999, "cancun"],
          ["src/lcc/libraries/LCCAuctionLib.sol", "0.8.35", 999999, "cancun"],
          ["src/lcc/libraries/LCCBucketListLib.sol", "0.8.35", 999999, "cancun"],
          ["src/lcc/libraries/LCCConfigLib.sol", "0.8.35", 999999, "cancun"],
          ["src/lcc/libraries/LCCErrorsLib.sol", "0.8.35", 999999, "cancun"],
          ["src/lcc/libraries/LCCEventsLib.sol", "0.8.35", 999999, "cancun"],
          ["src/lcc/libraries/LCCTypesLib.sol", "0.8.35", 999999, "cancun"],
          ["lib/openzeppelin/contracts/utils/ReentrancyGuardTransient.sol", "0.8.35", 999999, "cancun"],
          ["lib/openzeppelin/contracts/utils/TransientSlot.sol", "0.8.35", 999999, "cancun"],
        ] as const
      ).map(([path, version, runs, evmVersion]) => {
        return [
          path,
          {
            version,
            settings: {
              optimizer: {
                enabled: true,
                runs,
              },
              viaIR: true,
              evmVersion,
            },
          },
        ];
      }),
    ),
  },
  mocha: {
    timeout: 3000000,
  },
  typechain: {
    target: "ethers-v6",
    outDir: "types/",
    externalArtifacts: ["deps/**/*.json"],
  },
};

export default config;
