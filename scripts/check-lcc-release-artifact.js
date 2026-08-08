const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const EXPECTED_COMPILER = "0.8.35+commit.47b9dedd";
const EXPECTED_OPTIMIZER_RUNS = 150;
const EXPECTED_NOTIFICATION_VAULT_OPTIMIZER_RUNS = 999999;
const MAX_RUNTIME_BYTES = 24_276;
const EIP_170_LIMIT = 24_576;
const AUCTION_LIBRARY_SOURCE = "src/lcc/libraries/LCCAuctionLib.sol";
const CONFIG_LIBRARY_SOURCE = "src/lcc/libraries/LCCConfigLib.sol";
const EXPECTED_LINKED_LIBRARIES = new Map([
  [AUCTION_LIBRARY_SOURCE, "LCCAuctionLib"],
  [CONFIG_LIBRARY_SOURCE, "LCCConfigLib"],
]);
const STORAGE_LAYOUT_BASELINE = "docs/lcc-vault-storage-layout.json";
const ABI_BASELINE = "docs/lcc-vault-abi-baseline.json";
const NEGATIVE_FIXTURE_DIRECTORY = "scripts/fixtures/lcc-storage-layout";
const ARTIFACT_RESOLUTION_FIXTURE_DIRECTORY = "scripts/fixtures/lcc-artifact-resolution";
const EXPECTED_NEGATIVE_FIXTURES = [
  "base-storage-insertion.json",
  "gap-shrinkage.json",
  "packed-member-reorder.json",
  "width-change.json",
];
const EXPECTED_ARTIFACT_RESOLUTION_FIXTURES = [
  "ambiguous-matches.json",
  "canonical-tiebreak.json",
  "noncanonical-via-ir.json",
];
const LCC_VAULT_SETTINGS = {
  compiler: EXPECTED_COMPILER,
  evmVersion: "cancun",
  viaIR: true,
  optimizerEnabled: true,
  optimizerRuns: EXPECTED_OPTIMIZER_RUNS,
  bytecodeHash: "none",
};
const NOTIFICATION_VAULT_SETTINGS = {
  compiler: EXPECTED_COMPILER,
  evmVersion: "shanghai",
  viaIR: true,
  optimizerEnabled: true,
  optimizerRuns: EXPECTED_NOTIFICATION_VAULT_OPTIMIZER_RUNS,
  bytecodeHash: "none",
};

class ReleaseArtifactCheckError extends Error {}

function fail(message) {
  throw new ReleaseArtifactCheckError(message);
}

function forge(args) {
  return execFileSync("forge", args, {
    cwd: process.cwd(),
    encoding: "utf8",
    env: { ...process.env, FOUNDRY_PROFILE: "build" },
  });
}

function forgeOutputDirectory() {
  try {
    const config = JSON.parse(forge(["config", "--json"]));
    if (typeof config.out !== "string" || config.out.length === 0) fail("build profile has no Forge output directory");
    return path.resolve(process.cwd(), config.out);
  } catch (error) {
    fail(`could not read the Forge build-profile configuration: ${error.message}`);
  }
}

function readJson(relativePath) {
  const absolutePath = path.resolve(process.cwd(), relativePath);
  if (!fs.existsSync(absolutePath)) fail(`missing ${absolutePath}`);
  try {
    return JSON.parse(fs.readFileSync(absolutePath, "utf8"));
  } catch (error) {
    fail(`could not parse ${absolutePath}: ${error.message}`);
  }
}

function artifactSettingsDifferences(metadata, expected) {
  const settings = metadata?.settings;
  const differences = [];
  if (metadata?.compiler?.version !== expected.compiler) {
    differences.push(`solc expected ${expected.compiler}, found ${metadata?.compiler?.version}`);
  }
  if (settings?.evmVersion !== expected.evmVersion) {
    differences.push(`EVM expected ${expected.evmVersion}, found ${settings?.evmVersion}`);
  }
  if (settings?.viaIR !== expected.viaIR) {
    differences.push(`viaIR expected ${expected.viaIR}, found ${settings?.viaIR}`);
  }
  if (settings?.optimizer?.enabled !== expected.optimizerEnabled) {
    differences.push(`optimizer enabled expected ${expected.optimizerEnabled}, found ${settings?.optimizer?.enabled}`);
  }
  if (settings?.optimizer?.runs !== expected.optimizerRuns) {
    differences.push(`optimizer runs expected ${expected.optimizerRuns}, found ${settings?.optimizer?.runs}`);
  }
  const expectedMetadata = JSON.stringify({ bytecodeHash: expected.bytecodeHash });
  const foundMetadata = JSON.stringify(settings?.metadata);
  if (foundMetadata !== expectedMetadata) {
    differences.push(`metadata expected ${expectedMetadata}, found ${foundMetadata ?? "undefined"}`);
  }
  return differences;
}

function artifactSettingsSummary(metadata) {
  const settings = metadata?.settings;
  return (
    `solc=${metadata?.compiler?.version}, EVM=${settings?.evmVersion}, viaIR=${settings?.viaIR}, ` +
    `optimizer.enabled=${settings?.optimizer?.enabled}, optimizer.runs=${settings?.optimizer?.runs}, ` +
    `metadata=${JSON.stringify(settings?.metadata) ?? "undefined"}`
  );
}

function selectCanonicalArtifact(candidates, contractName, expected) {
  const matchingCandidates = candidates.filter(
    (candidate) => artifactSettingsDifferences(candidate.artifact.metadata, expected).length === 0,
  );
  if (matchingCandidates.length === 1) return matchingCandidates[0];
  if (matchingCandidates.length > 1) {
    const canonicalFilename = `${contractName}.json`;
    const canonicalCandidates = matchingCandidates.filter((candidate) => candidate.file === canonicalFilename);
    if (canonicalCandidates.length === 1) return canonicalCandidates[0];
  }

  const found = candidates
    .map((candidate) => `${candidate.file} (${artifactSettingsSummary(candidate.artifact.metadata)})`)
    .join("; ");
  const reason = matchingCandidates.length === 0 ? "could not resolve" : "resolved more than one";
  throw new Error(
    `${reason} canonical ${contractName} artifact; expected ${artifactSettingsSummary({
      compiler: { version: expected.compiler },
      settings: {
        evmVersion: expected.evmVersion,
        viaIR: expected.viaIR,
        optimizer: { enabled: expected.optimizerEnabled, runs: expected.optimizerRuns },
        metadata: { bytecodeHash: expected.bytecodeHash },
      },
    })}; found ${found || "none"}`,
  );
}

function resolveArtifactBySettings(outputDirectory, sourceName, contractName, expected) {
  const artifactDirectory = path.join(outputDirectory, sourceName);
  const candidates = fs.existsSync(artifactDirectory)
    ? fs
        .readdirSync(artifactDirectory)
        .filter((file) => file.endsWith(".json"))
        .sort()
        .map((file) => ({ file, artifact: readJson(path.join(artifactDirectory, file)) }))
    : [];
  try {
    const selected = selectCanonicalArtifact(candidates, contractName, expected);
    return { ...selected, artifactPath: path.join(artifactDirectory, selected.file) };
  } catch (error) {
    const message = `${error.message}; artifact directory ${artifactDirectory}; run yarn build:forge first`;
    fail(message);
    throw new ReleaseArtifactCheckError(message);
  }
}

function assertArtifactSettings(contractName, metadata, expected) {
  const differences = artifactSettingsDifferences(metadata, expected);
  if (differences.length !== 0) fail(`${contractName}: ${differences.join("; ")}`);
}

function canonicalType(typeId, types, ancestry = new Set()) {
  const type = types[typeId];
  if (!type) throw new Error(`unknown storage type ${typeId}`);
  if (ancestry.has(typeId)) throw new Error(`recursive storage type ${typeId}`);

  const nextAncestry = new Set(ancestry);
  nextAncestry.add(typeId);
  const canonical = {
    encoding: type.encoding,
    numberOfBytes: type.numberOfBytes,
    label: type.label,
  };

  if (type.key !== undefined) canonical.key = canonicalType(type.key, types, nextAncestry);
  if (type.value !== undefined) canonical.value = canonicalType(type.value, types, nextAncestry);
  if (type.base !== undefined) {
    canonical.base = canonicalType(type.base, types, nextAncestry);
  }
  if (type.members !== undefined) {
    canonical.members = type.members.map((member) => ({
      label: member.label,
      slot: member.slot,
      offset: member.offset,
      type: canonicalType(member.type, types, nextAncestry),
    }));
  }

  return canonical;
}

function canonicalLayout(layout) {
  if (!Array.isArray(layout?.storage) || typeof layout?.types !== "object") {
    throw new Error("malformed storage layout");
  }
  return layout.storage.map((entry) => ({
    label: entry.label,
    slot: entry.slot,
    offset: entry.offset,
    type: canonicalType(entry.type, layout.types),
  }));
}

function canonicalAbiType(parameter) {
  if (typeof parameter?.type !== "string") throw new Error("ABI parameter is missing its type");
  if (!parameter.type.startsWith("tuple")) return parameter.type;
  if (!Array.isArray(parameter.components)) throw new Error(`ABI ${parameter.type} parameter is missing components`);

  const tupleSuffix = parameter.type.slice("tuple".length);
  return `(${parameter.components.map(canonicalAbiType).join(",")})${tupleSuffix}`;
}

function canonicalAbiParameter(parameter, includeIndexed = false) {
  const canonical = {
    name: parameter.name ?? "",
    type: parameter.type,
  };
  if (parameter.type.startsWith("tuple")) {
    if (!Array.isArray(parameter.components)) throw new Error(`ABI ${parameter.type} parameter is missing components`);
    canonical.components = parameter.components.map((component) => canonicalAbiParameter(component));
  }
  if (includeIndexed) canonical.indexed = parameter.indexed === true;
  return canonical;
}

function canonicalAbiEntry(entry, methodIdentifiers) {
  if (typeof entry?.name !== "string" || !Array.isArray(entry.inputs)) {
    throw new Error(`malformed ${entry?.type ?? "unknown"} ABI entry`);
  }

  const signature = `${entry.name}(${entry.inputs.map(canonicalAbiType).join(",")})`;
  if (entry.type === "function") {
    if (!Array.isArray(entry.outputs) || typeof entry.stateMutability !== "string") {
      throw new Error(`malformed function ABI entry ${signature}`);
    }
    const selector = methodIdentifiers[signature];
    if (typeof selector !== "string" || !/^[0-9a-f]{8}$/.test(selector)) {
      throw new Error(`artifact method identifiers are missing a selector for ${signature}`);
    }
    return {
      name: entry.name,
      signature,
      selector: `0x${selector}`,
      stateMutability: entry.stateMutability,
      inputs: entry.inputs.map((parameter) => canonicalAbiParameter(parameter)),
      outputs: entry.outputs.map((parameter) => canonicalAbiParameter(parameter)),
    };
  }
  if (entry.type === "event") {
    return {
      name: entry.name,
      signature,
      anonymous: entry.anonymous === true,
      inputs: entry.inputs.map((parameter) => canonicalAbiParameter(parameter, true)),
    };
  }
  if (entry.type === "error") {
    return {
      name: entry.name,
      signature,
      inputs: entry.inputs.map((parameter) => canonicalAbiParameter(parameter)),
    };
  }
  throw new Error(`unsupported ABI entry type ${entry.type}`);
}

function canonicalAbi(abi, methodIdentifiers) {
  if (!Array.isArray(abi) || typeof methodIdentifiers !== "object" || methodIdentifiers === null) {
    throw new Error("malformed artifact ABI or method identifiers");
  }

  const canonical = { functions: [], events: [], errors: [] };
  for (const entry of abi) {
    if (entry.type === "constructor") continue;
    if (entry.type === "function") canonical.functions.push(canonicalAbiEntry(entry, methodIdentifiers));
    else if (entry.type === "event") canonical.events.push(canonicalAbiEntry(entry, methodIdentifiers));
    else if (entry.type === "error") canonical.errors.push(canonicalAbiEntry(entry, methodIdentifiers));
    else throw new Error(`unsupported external ABI entry type ${entry.type}`);
  }

  for (const entries of Object.values(canonical)) {
    entries.sort((left, right) => (left.signature < right.signature ? -1 : left.signature > right.signature ? 1 : 0));
  }

  const artifactSignatures = Object.keys(methodIdentifiers).sort();
  const abiSignatures = canonical.functions.map((entry) => entry.signature).sort();
  if (artifactSignatures.join("\n") !== abiSignatures.join("\n")) {
    throw new Error("function ABI signatures do not match the artifact method identifiers");
  }

  return canonical;
}

function firstDifference(expected, actual, location = "layout") {
  if (typeof expected !== typeof actual) return `${location}: expected ${typeof expected}, found ${typeof actual}`;
  if (expected === null || actual === null || typeof expected !== "object") {
    return expected === actual
      ? undefined
      : `${location}: expected ${JSON.stringify(expected)}, found ${JSON.stringify(actual)}`;
  }
  if (Array.isArray(expected) !== Array.isArray(actual)) return `${location}: array/object mismatch`;

  const expectedKeys = Object.keys(expected);
  const actualKeys = Object.keys(actual);
  if (expectedKeys.join(",") !== actualKeys.join(",")) {
    return `${location}: expected keys [${expectedKeys.join(", ")}], found [${actualKeys.join(", ")}]`;
  }
  for (const key of expectedKeys) {
    const difference = firstDifference(expected[key], actual[key], `${location}.${key}`);
    if (difference) return difference;
  }
  return undefined;
}

function layoutDifference(expected, actual) {
  return { difference: firstDifference(canonicalLayout(expected), canonicalLayout(actual)) };
}

function verifyNegativeFixtures() {
  const directory = path.resolve(process.cwd(), NEGATIVE_FIXTURE_DIRECTORY);
  if (!fs.existsSync(directory)) fail(`missing ${directory}`);
  const fixtureFiles = new Set(fs.readdirSync(directory).filter((file) => file.endsWith(".json")));
  const missingFixtures = EXPECTED_NEGATIVE_FIXTURES.filter((fixtureFile) => !fixtureFiles.has(fixtureFile));
  if (missingFixtures.length !== 0) fail(`missing storage-layout negative fixtures: ${missingFixtures.join(", ")}`);

  for (const fixtureFile of EXPECTED_NEGATIVE_FIXTURES) {
    const fixture = readJson(path.join(NEGATIVE_FIXTURE_DIRECTORY, fixtureFile));
    if (
      fixture === null ||
      typeof fixture !== "object" ||
      !Object.hasOwn(fixture, "baseline") ||
      !Object.hasOwn(fixture, "candidate")
    ) {
      fail(`negative fixture ${fixtureFile} must contain baseline and candidate layouts`);
    }

    let result;
    try {
      result = layoutDifference(fixture.baseline, fixture.candidate);
    } catch (error) {
      fail(`negative fixture ${fixtureFile} could not be evaluated: ${error.message}`);
    }
    if (!result.difference) {
      fail(`negative fixture ${fixtureFile} was not rejected`);
    }
  }
}

function verifyArtifactResolutionNegativeFixtures() {
  const directory = path.resolve(process.cwd(), ARTIFACT_RESOLUTION_FIXTURE_DIRECTORY);
  if (!fs.existsSync(directory)) fail(`missing ${directory}`);
  const fixtureFiles = new Set(fs.readdirSync(directory).filter((file) => file.endsWith(".json")));
  const missingFixtures = EXPECTED_ARTIFACT_RESOLUTION_FIXTURES.filter((file) => !fixtureFiles.has(file));
  if (missingFixtures.length !== 0)
    fail(`missing artifact-resolution negative fixtures: ${missingFixtures.join(", ")}`);

  for (const fixtureFile of EXPECTED_ARTIFACT_RESOLUTION_FIXTURES) {
    const fixture = readJson(path.join(ARTIFACT_RESOLUTION_FIXTURE_DIRECTORY, fixtureFile));
    if (
      typeof fixture?.contractName !== "string" ||
      typeof fixture?.expected !== "object" ||
      !Array.isArray(fixture?.candidates) ||
      (fixture?.expectedFile === undefined && !Array.isArray(fixture?.expectedErrorFragments)) ||
      (fixture?.expectedFile !== undefined && typeof fixture.expectedFile !== "string")
    ) {
      fail(`artifact-resolution negative fixture ${fixtureFile} is malformed`);
    }

    const fixtureOutputDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "lcc-artifact-resolution-"));
    const sourceName = `${fixture.contractName}.sol`;
    const artifactDirectory = path.join(fixtureOutputDirectory, sourceName);
    fs.mkdirSync(artifactDirectory);
    for (const candidate of fixture.candidates) {
      if (typeof candidate?.file !== "string" || typeof candidate?.metadata !== "object") {
        fail(`artifact-resolution negative fixture ${fixtureFile} has a malformed candidate`);
      }
      fs.writeFileSync(
        path.join(artifactDirectory, candidate.file),
        `${JSON.stringify({ metadata: candidate.metadata }, null, 2)}\n`,
      );
    }

    let resolved;
    let resolutionError;
    try {
      resolved = resolveArtifactBySettings(
        fixtureOutputDirectory,
        sourceName,
        fixture.contractName,
        fixture.expected,
      );
    } catch (error) {
      resolutionError = error.message;
    } finally {
      fs.rmSync(fixtureOutputDirectory, { recursive: true, force: true });
    }

    if (fixture.expectedFile !== undefined) {
      if (resolutionError !== undefined) {
        fail(`artifact-resolution fixture ${fixtureFile} unexpectedly failed: ${resolutionError}`);
      }
      if (resolved.file !== fixture.expectedFile) {
        fail(
          `artifact-resolution fixture ${fixtureFile} selected ${resolved.file}, expected ${fixture.expectedFile}`,
        );
      }
    } else {
      if (resolutionError === undefined) fail(`artifact-resolution negative fixture ${fixtureFile} was not rejected`);
      const missingFragments = fixture.expectedErrorFragments.filter((fragment) => !resolutionError.includes(fragment));
      if (missingFragments.length !== 0) {
        fail(
          `artifact-resolution negative fixture ${fixtureFile} error omitted: ${missingFragments.join(", ")}; ` +
            `found ${resolutionError}`,
        );
      }
    }
  }
}

function main() {
  const outputDirectory = forgeOutputDirectory();
  const lccVaultResolution = resolveArtifactBySettings(
    outputDirectory,
    "LCCVault.sol",
    "LCCVault",
    LCC_VAULT_SETTINGS,
  );
  const artifactPath = lccVaultResolution.artifactPath;
  const artifact = lccVaultResolution.artifact;
  const metadata = artifact.metadata;
  const bytecode = artifact.deployedBytecode?.object;

  assertArtifactSettings("LCCVault", metadata, LCC_VAULT_SETTINGS);
  if (typeof bytecode !== "string" || !bytecode.startsWith("0x") || bytecode.length % 2 !== 0) {
    fail("deployed bytecode is malformed");
  }

  const runtimeBytes = (bytecode.length - 2) / 2;
  if (runtimeBytes > MAX_RUNTIME_BYTES) {
    fail(`runtime is ${runtimeBytes} bytes; maximum is ${MAX_RUNTIME_BYTES}`);
  }

  const linkReferences = artifact.deployedBytecode?.linkReferences ?? {};
  const linkedSources = Object.keys(linkReferences);
  const hasExpectedLinkReferences =
    linkedSources.length === EXPECTED_LINKED_LIBRARIES.size &&
    [...EXPECTED_LINKED_LIBRARIES].every(
      ([source, library]) =>
        Object.hasOwn(linkReferences, source) && Object.keys(linkReferences[source]).join(",") === library,
    );
  if (!hasExpectedLinkReferences) {
    fail(`expected exactly LCCAuctionLib and LCCConfigLib link references, found ${linkedSources.join(", ") || "none"}`);
  }

  let layoutResult;
  try {
    layoutResult = layoutDifference(readJson(STORAGE_LAYOUT_BASELINE), artifact.storageLayout);
  } catch (error) {
    fail(`could not compare the artifact storage layout: ${error.message}`);
  }
  if (layoutResult.difference) {
    fail(`storage layout differs from reviewer-controlled baseline: ${layoutResult.difference}`);
  }
  verifyNegativeFixtures();
  verifyArtifactResolutionNegativeFixtures();

  let canonicalArtifactAbi;
  let abiDifference;
  try {
    canonicalArtifactAbi = canonicalAbi(artifact.abi, artifact.methodIdentifiers);
    abiDifference = firstDifference(readJson(ABI_BASELINE), canonicalArtifactAbi, "abi");
  } catch (error) {
    fail(`could not compare the artifact external ABI: ${error.message}`);
  }
  if (abiDifference) {
    fail(
      `external ABI differs from reviewer-controlled baseline:\n` +
        `--- ${ABI_BASELINE}\n` +
        `+++ ${path.relative(process.cwd(), artifactPath)}\n` +
        `@@ ${abiDifference} @@`,
    );
  }

  const notificationVaultResolution = resolveArtifactBySettings(
    outputDirectory,
    "NotificationVault.sol",
    "NotificationVault",
    NOTIFICATION_VAULT_SETTINGS,
  );
  assertArtifactSettings(
    "NotificationVault",
    notificationVaultResolution.artifact.metadata,
    NOTIFICATION_VAULT_SETTINGS,
  );

  console.log(
    `LCCVault release artifact: ${runtimeBytes} bytes, ${EIP_170_LIMIT - runtimeBytes} bytes below EIP-170, ` +
      `${EXPECTED_OPTIMIZER_RUNS} runs; LCCAuctionLib and LCCConfigLib link references present; ` +
      `storage layout and external ABI match reviewer-controlled baselines; ` +
      `LCCVault and NotificationVault artifacts match their canonical compiler, EVM, via-IR, optimizer, and metadata settings`,
  );
}

try {
  main();
} catch (error) {
  console.error(`LCC release artifact check failed: ${error.message}`);
  process.exit(1);
}
