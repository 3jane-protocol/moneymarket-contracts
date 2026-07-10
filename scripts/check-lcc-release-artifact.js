const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const EXPECTED_COMPILER = "0.8.35+commit.47b9dedd";
const EXPECTED_OPTIMIZER_RUNS = 300;
const MAX_RUNTIME_BYTES = 24_076;
const EIP_170_LIMIT = 24_576;
const AUCTION_LIBRARY_SOURCE = "src/lcc/libraries/LCCAuctionLib.sol";

function fail(message) {
  console.error(`LCC release artifact check failed: ${message}`);
  process.exit(1);
}

function forgeOutputDirectory() {
  try {
    const config = JSON.parse(
      execFileSync("forge", ["config", "--json"], {
        cwd: process.cwd(),
        encoding: "utf8",
        env: { ...process.env, FOUNDRY_PROFILE: "build" },
      }),
    );
    if (typeof config.out !== "string" || config.out.length === 0) fail("build profile has no Forge output directory");
    return path.resolve(process.cwd(), config.out);
  } catch (error) {
    fail(`could not read the Forge build-profile configuration: ${error.message}`);
  }
}

const ARTIFACT_PATH = path.join(forgeOutputDirectory(), "LCCVault.sol", "LCCVault.json");

if (!fs.existsSync(ARTIFACT_PATH)) fail(`missing ${ARTIFACT_PATH}; run yarn build:forge first`);

const artifact = JSON.parse(fs.readFileSync(ARTIFACT_PATH, "utf8"));
const metadata = artifact.metadata;
const settings = metadata?.settings;
const bytecode = artifact.deployedBytecode?.object;

if (metadata?.compiler?.version !== EXPECTED_COMPILER) {
  fail(`expected solc ${EXPECTED_COMPILER}, found ${metadata?.compiler?.version}`);
}
if (settings?.evmVersion !== "cancun") fail(`expected Cancun, found ${settings?.evmVersion}`);
if (settings?.viaIR !== true) fail("via IR must be enabled");
if (settings?.optimizer?.enabled !== true) fail("optimizer must be enabled");
if (settings?.optimizer?.runs !== EXPECTED_OPTIMIZER_RUNS) {
  fail(`expected ${EXPECTED_OPTIMIZER_RUNS} optimizer runs, found ${settings?.optimizer?.runs}`);
}
if (settings?.metadata?.bytecodeHash !== "none") fail("metadata bytecode hash must be disabled");
if (typeof bytecode !== "string" || !bytecode.startsWith("0x") || bytecode.length % 2 !== 0) {
  fail("deployed bytecode is malformed");
}

const runtimeBytes = (bytecode.length - 2) / 2;
if (runtimeBytes > MAX_RUNTIME_BYTES) {
  fail(`runtime is ${runtimeBytes} bytes; maximum is ${MAX_RUNTIME_BYTES}`);
}

const linkReferences = artifact.deployedBytecode?.linkReferences ?? {};
const linkedSources = Object.keys(linkReferences);
if (
  linkedSources.length !== 1 ||
  linkedSources[0] !== AUCTION_LIBRARY_SOURCE ||
  Object.keys(linkReferences[AUCTION_LIBRARY_SOURCE]).join(",") !== "LCCAuctionLib"
) {
  fail(`expected LCCAuctionLib as the sole link reference, found ${linkedSources.join(", ") || "none"}`);
}

console.log(
  `LCCVault release artifact: ${runtimeBytes} bytes, ${EIP_170_LIMIT - runtimeBytes} bytes below EIP-170, ` +
    `${EXPECTED_OPTIMIZER_RUNS} runs`,
);
