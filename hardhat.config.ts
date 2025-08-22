import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-foundry";
import "@nomicfoundation/hardhat-network-helpers";
import "@typechain/hardhat";
import * as dotenv from "dotenv";
import "ethers-maths";
import "hardhat-gas-reporter";
import "hardhat-tracer";
import { HardhatUserConfig } from "hardhat/config";

dotenv.config();

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
                optimizerSteps: "dhfoDgvulfnTUtnIf[lpf]"
              }
            }
          },
          viaIR: true,
          outputSelection: {
            "*": {
              "*": ["metadata", "evm.bytecode", "evm.deployedBytecode"],
              "": ["ast"]
            }
          }
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
