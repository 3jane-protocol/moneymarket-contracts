#!/usr/bin/env node

const { Interface, formatUnits, getAddress, id } = require("ethers");

const DEFAULT_MORPHO_CREDIT = "0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc";
const DEFAULT_MARKET_ID = "0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75";
const DEFAULT_BORROWER = "0x3Ff3ff33D20a086834A095ed6ed562c9e189291b";
const DEFAULT_WAUSDC = "0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E";
const DEFAULT_USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const DEFAULT_HELPERS = ["0x82736F81A56935c8429ADdbDa4aEBec737444505", "0x2A66F992bF227D2e50eF19EDD21503C3c4F3f682"];
const DEFAULT_FROM_BLOCK = 23_214_677n;
const DEFAULT_LOG_CHUNK_BLOCKS = 20_000n;
const DEFAULT_DECIMALS = 6;
const DEFAULT_RPC_CONCURRENCY = 12;

const VIRTUAL_SHARES = 1_000_000n;
const VIRTUAL_ASSETS = 1n;

const BORROW_TOPIC = id("Borrow(bytes32,address,address,address,uint256,uint256)");
const REPAY_TOPIC = id("Repay(bytes32,address,address,uint256,uint256)");
const ACCRUE_INTEREST_TOPIC = id("AccrueInterest(bytes32,uint256,uint256,uint256)");
const PREMIUM_ACCRUED_TOPIC = id("PremiumAccrued(bytes32,address,uint256,uint256)");
const ACCOUNT_SETTLED_TOPIC = id("AccountSettled(bytes32,address,address,uint256,uint256)");
const BORROW_REFERRED_TOPIC = id("BorrowReferred(address,uint256,bytes32)");
const TRANSFER_TOPIC = id("Transfer(address,address,uint256)");

const MORPHO_INTERFACE = new Interface([
  "function market(bytes32) view returns (uint128 totalSupplyAssets,uint128 totalSupplyShares,uint128 totalBorrowAssets,uint128 totalBorrowShares,uint128 lastUpdate,uint128 fee,uint128 totalMarkdownAmount)",
  "function position(bytes32,address) view returns (uint256 supplyShares,uint128 borrowShares,uint128 collateral)",
]);

const WAUSDC_INTERFACE = new Interface(["function convertToAssets(uint256 shares) view returns (uint256 assets)"]);

main().catch((err) => {
  console.error(err.stack || err.message || String(err));
  process.exit(1);
});

async function main() {
  const rpcUrl = mustEnv("ETH_RPC_URL");
  const morphoCredit = getAddress(process.env.MORPHO_CREDIT_ADDRESS || DEFAULT_MORPHO_CREDIT);
  const marketId = process.env.MORPHO_MARKET_ID || DEFAULT_MARKET_ID;
  const borrower = getAddress(process.env.MORPHO_BORROWER_REPORT_BORROWER || DEFAULT_BORROWER);
  const waUsdc = getAddress(process.env.MORPHO_BORROWER_REPORT_WAUSDC || DEFAULT_WAUSDC);
  const usdc = getAddress(process.env.MORPHO_BORROWER_REPORT_USDC || DEFAULT_USDC);
  const helpers = parseAddressListEnv("MORPHO_BORROWER_REPORT_HELPERS", DEFAULT_HELPERS);
  const latestBlock = fromQuantity(await rpc(rpcUrl, "eth_blockNumber", []));
  const fromBlock = parseBigIntEnv("MORPHO_BORROWER_REPORT_FROM_BLOCK", DEFAULT_FROM_BLOCK);
  const toBlock = parseBlockEnv(process.env.MORPHO_BORROWER_REPORT_TO_BLOCK, latestBlock);
  const chunkBlocks = parseBigIntEnv("MORPHO_BORROWER_REPORT_LOG_CHUNK_BLOCKS", DEFAULT_LOG_CHUNK_BLOCKS);
  const decimals = Number(parseBigIntEnv("MORPHO_BORROWER_REPORT_DECIMALS", BigInt(DEFAULT_DECIMALS)));
  const rpcConcurrency = Number(
    parseBigIntEnv("MORPHO_BORROWER_REPORT_RPC_CONCURRENCY", BigInt(DEFAULT_RPC_CONCURRENCY)),
  );

  if (fromBlock > toBlock) throw new Error("MORPHO_BORROWER_REPORT_FROM_BLOCK is after to block");

  const logs = await getLogsChunked(
    rpcUrl,
    morphoCredit,
    fromBlock,
    toBlock,
    [[BORROW_TOPIC, REPAY_TOPIC, ACCRUE_INTEREST_TOPIC, PREMIUM_ACCRUED_TOPIC, ACCOUNT_SETTLED_TOPIC], marketId],
    chunkBlocks,
  );

  const replay = replayLogs(logs, borrower, marketId, decimals);
  await validateReplay(rpcUrl, morphoCredit, marketId, borrower, toBlock, replay.state);

  const rows = replay.rows;
  rows.push(buildSnapshotRow(toBlock, borrower, marketId, decimals, replay.state));

  const [timestampByBlock] = await Promise.all([
    loadBlockTimestamps(
      rpcUrl,
      rows.map((row) => row.block),
    ),
    enrichBorrowProceeds(rpcUrl, rows, borrower, waUsdc, usdc, helpers, rpcConcurrency),
    enrichRowsWithUsdc(rpcUrl, rows, waUsdc, decimals, rpcConcurrency),
  ]);

  applyPrincipalAccounting(rows, decimals);
  await enrichPrincipalValues(rpcUrl, rows, waUsdc, decimals, rpcConcurrency);

  for (const row of rows) {
    row.timestamp = timestampByBlock.get(row.block.toString()) || "";
    row.datetime_utc = row.timestamp === "" ? "" : formatTimestamp(row.timestamp);
  }

  process.stdout.write(toCsv(rows, borrower, marketId, decimals));
}

function replayLogs(logs, borrower, marketId, decimals) {
  const borrowerLower = borrower.toLowerCase();
  const rows = [];

  let totalBorrowAssets = 0n;
  let totalBorrowShares = 0n;
  let borrowerShares = 0n;

  for (const log of logs.sort(compareLogPosition)) {
    const eventTopic = log.topics[0].toLowerCase();
    const debtBefore = borrowerDebt(totalBorrowAssets, totalBorrowShares, borrowerShares);
    const borrowerSharesBefore = borrowerShares;

    if (eventTopic === BORROW_TOPIC) {
      const onBehalf = addressFromTopic(log.topics[2]);
      const receiver = addressFromTopic(log.topics[3]);
      const caller = addressFromWord(log.data, 0);
      const assets = wordAt(log.data, 1);
      const shares = wordAt(log.data, 2);
      const isTarget = onBehalf.toLowerCase() === borrowerLower;

      totalBorrowAssets += assets;
      totalBorrowShares += shares;
      if (isTarget) borrowerShares += shares;

      if (isTarget) {
        rows.push(
          buildRow(log, "borrow", borrower, marketId, decimals, {
            caller,
            receiver,
            assets,
            shares,
            debtBefore,
            debtAfter: borrowerDebt(totalBorrowAssets, totalBorrowShares, borrowerShares),
            borrowerSharesBefore,
            borrowerShares,
            totalBorrowAssets,
            totalBorrowShares,
          }),
        );
      }
    } else if (eventTopic === REPAY_TOPIC) {
      const caller = addressFromTopic(log.topics[2]);
      const onBehalf = addressFromTopic(log.topics[3]);
      const assets = wordAt(log.data, 0);
      const shares = wordAt(log.data, 1);
      const isTarget = onBehalf.toLowerCase() === borrowerLower;

      totalBorrowShares -= shares;
      totalBorrowAssets = zeroFloorSub(totalBorrowAssets, assets);
      if (isTarget) borrowerShares -= shares;

      if (isTarget) {
        rows.push(
          buildRow(log, "repay", borrower, marketId, decimals, {
            caller,
            assets,
            shares,
            debtBefore,
            debtAfter: borrowerDebt(totalBorrowAssets, totalBorrowShares, borrowerShares),
            borrowerSharesBefore,
            borrowerShares,
            totalBorrowAssets,
            totalBorrowShares,
          }),
        );
      }
    } else if (eventTopic === ACCRUE_INTEREST_TOPIC) {
      const prevBorrowRate = wordAt(log.data, 0);
      const marketInterest = wordAt(log.data, 1);
      const debtAfter = borrowerDebt(totalBorrowAssets + marketInterest, totalBorrowShares, borrowerShares);
      const borrowerInterest = debtAfter - debtBefore;

      totalBorrowAssets += marketInterest;

      if (borrowerInterest > 0n) {
        rows.push(
          buildRow(log, "base_interest_accrued", borrower, marketId, decimals, {
            baseInterestAssets: borrowerInterest,
            debtBefore,
            debtAfter,
            borrowerSharesBefore,
            borrowerShares,
            totalBorrowAssets,
            totalBorrowShares,
            prevBorrowRate,
            marketInterestAssets: marketInterest,
          }),
        );
      }
    } else if (eventTopic === PREMIUM_ACCRUED_TOPIC) {
      const premiumBorrower = addressFromTopic(log.topics[2]);
      const premiumAmount = wordAt(log.data, 0);
      const premiumFeeAmount = wordAt(log.data, 1);
      const premiumShares = toSharesUp(premiumAmount, totalBorrowAssets, totalBorrowShares);
      const isTarget = premiumBorrower.toLowerCase() === borrowerLower;

      totalBorrowAssets += premiumAmount;
      totalBorrowShares += premiumShares;
      if (isTarget) borrowerShares += premiumShares;

      if (isTarget) {
        rows.push(
          buildRow(log, "premium_accrued", borrower, marketId, decimals, {
            shares: premiumShares,
            premiumAssets: premiumAmount,
            premiumFeeAssets: premiumFeeAmount,
            debtBefore,
            debtAfter: borrowerDebt(totalBorrowAssets, totalBorrowShares, borrowerShares),
            borrowerSharesBefore,
            borrowerShares,
            totalBorrowAssets,
            totalBorrowShares,
          }),
        );
      }
    } else if (eventTopic === ACCOUNT_SETTLED_TOPIC) {
      const caller = addressFromTopic(log.topics[2]);
      const settledBorrower = addressFromTopic(log.topics[3]);
      const writtenOffAssets = wordAt(log.data, 0);
      const writtenOffShares = wordAt(log.data, 1);
      const isTarget = settledBorrower.toLowerCase() === borrowerLower;

      totalBorrowAssets -= writtenOffAssets;
      totalBorrowShares -= writtenOffShares;
      if (isTarget) borrowerShares = 0n;

      if (isTarget) {
        rows.push(
          buildRow(log, "account_settled", borrower, marketId, decimals, {
            caller,
            writtenOffAssets,
            writtenOffShares,
            debtBefore,
            debtAfter: borrowerDebt(totalBorrowAssets, totalBorrowShares, borrowerShares),
            borrowerSharesBefore,
            borrowerShares,
            totalBorrowAssets,
            totalBorrowShares,
          }),
        );
      }
    }
  }

  return {
    rows,
    state: {
      totalBorrowAssets,
      totalBorrowShares,
      borrowerShares,
    },
  };
}

function buildRow(log, eventType, borrower, marketId, decimals, values) {
  return {
    block: fromQuantity(log.blockNumber),
    timestamp: "",
    datetime_utc: "",
    tx_hash: log.transactionHash,
    log_index: fromQuantity(log.logIndex),
    event_type: eventType,
    borrower,
    market_id: marketId,
    caller: values.caller || "",
    receiver: values.receiver || "",
    assets: values.assets ?? "",
    assets_decimal: maybeFormat(values.assets, decimals),
    shares: values.shares ?? "",
    base_interest_assets: values.baseInterestAssets ?? "",
    base_interest_decimal: maybeFormat(values.baseInterestAssets, decimals),
    premium_assets: values.premiumAssets ?? "",
    premium_decimal: maybeFormat(values.premiumAssets, decimals),
    premium_fee_assets: values.premiumFeeAssets ?? "",
    written_off_assets: values.writtenOffAssets ?? "",
    written_off_shares: values.writtenOffShares ?? "",
    debt_before_assets: values.debtBefore,
    debt_before_decimal: formatUnits(values.debtBefore, decimals),
    debt_after_assets: values.debtAfter,
    debt_after_decimal: formatUnits(values.debtAfter, decimals),
    borrower_borrow_shares_before: values.borrowerSharesBefore,
    borrower_borrow_shares_after: values.borrowerShares,
    market_total_borrow_assets_after: values.totalBorrowAssets,
    market_total_borrow_shares_after: values.totalBorrowShares,
    prev_borrow_rate: values.prevBorrowRate ?? "",
    market_interest_assets: values.marketInterestAssets ?? "",
  };
}

function buildSnapshotRow(block, borrower, marketId, decimals, state) {
  const debt = borrowerDebt(state.totalBorrowAssets, state.totalBorrowShares, state.borrowerShares);

  return {
    block,
    timestamp: "",
    datetime_utc: "",
    tx_hash: "",
    log_index: "",
    event_type: "snapshot",
    borrower,
    market_id: marketId,
    caller: "",
    receiver: "",
    assets: "",
    assets_decimal: "",
    shares: "",
    base_interest_assets: "",
    base_interest_decimal: "",
    premium_assets: "",
    premium_decimal: "",
    premium_fee_assets: "",
    written_off_assets: "",
    written_off_shares: "",
    debt_before_assets: debt,
    debt_before_decimal: formatUnits(debt, decimals),
    debt_after_assets: debt,
    debt_after_decimal: formatUnits(debt, decimals),
    borrower_borrow_shares_before: state.borrowerShares,
    borrower_borrow_shares_after: state.borrowerShares,
    market_total_borrow_assets_after: state.totalBorrowAssets,
    market_total_borrow_shares_after: state.totalBorrowShares,
    prev_borrow_rate: "",
    market_interest_assets: "",
  };
}

async function enrichBorrowProceeds(rpcUrl, rows, borrower, waUsdc, usdc, helpers, concurrency) {
  const borrowerLower = borrower.toLowerCase();
  const waUsdcLower = waUsdc.toLowerCase();
  const usdcLower = usdc.toLowerCase();
  const helperSet = new Set(helpers.map((helper) => helper.toLowerCase()));
  const borrowRows = rows.filter((row) => row.event_type === "borrow");

  await mapLimit(borrowRows, concurrency, async (row) => {
    const receipt = await rpc(rpcUrl, "eth_getTransactionReceipt", [row.tx_hash]);
    if (!receipt) throw new Error(`Missing transaction receipt ${row.tx_hash}`);

    const referralLog = receipt.logs.find(
      (log) =>
        log.address.toLowerCase() === row.caller.toLowerCase() &&
        log.topics[0]?.toLowerCase() === BORROW_REFERRED_TOPIC &&
        addressFromTopic(log.topics[1]).toLowerCase() === borrowerLower,
    );

    const transferLogs = receipt.logs.filter(
      (log) =>
        log.address.toLowerCase() === usdcLower &&
        log.topics[0]?.toLowerCase() === TRANSFER_TOPIC &&
        addressFromTopic(log.topics[1]).toLowerCase() === waUsdcLower &&
        addressFromTopic(log.topics[2]).toLowerCase() === borrowerLower,
    );

    const callerIsConfiguredHelper = helperSet.has(row.caller.toLowerCase());
    const hasHelperFlowEvidence = referralLog !== undefined || transferLogs.length > 0;
    const isHelperBorrow =
      row.caller.toLowerCase() === row.receiver.toLowerCase() && (callerIsConfiguredHelper || hasHelperFlowEvidence);

    row.borrow_via_helper = isHelperBorrow;
    row.helper_address = isHelperBorrow ? row.caller : "";

    if (referralLog) {
      row.helper_usdc_received_raw = wordAt(referralLog.data, 0);
      row.helper_proceeds_source = "BorrowReferred";
    } else if (transferLogs.length > 0) {
      row.helper_usdc_received_raw = transferLogs.reduce((sum, log) => sum + wordAt(log.data, 0), 0n);
      row.helper_proceeds_source = "USDC Transfer";
    } else if (isHelperBorrow) {
      row.helper_usdc_received_raw = "";
      row.helper_proceeds_source = "historical convertToAssets";
    } else {
      row.helper_usdc_received_raw = "";
      row.helper_proceeds_source = "";
    }
  });
}

async function enrichRowsWithUsdc(rpcUrl, rows, waUsdc, decimals, concurrency) {
  const amountMappings = [
    ["assets", "assets_usdc_raw", "assets_usdc"],
    ["base_interest_assets", "base_interest_usdc_raw", "base_interest_usdc"],
    ["premium_assets", "premium_usdc_raw", "premium_usdc"],
    ["premium_fee_assets", "premium_fee_usdc_raw", "premium_fee_usdc"],
    ["written_off_assets", "written_off_usdc_raw", "written_off_usdc"],
    ["debt_before_assets", "debt_before_usdc_raw", "debt_before_usdc"],
    ["debt_after_assets", "debt_after_usdc_raw", "debt_after_usdc"],
    ["market_total_borrow_assets_after", "market_total_borrow_usdc_raw", "market_total_borrow_usdc"],
    ["market_interest_assets", "market_interest_usdc_raw", "market_interest_usdc"],
  ];
  const oneWaUsdc = 10n ** BigInt(decimals);
  const requests = [];

  for (const row of rows) {
    requests.push({ block: row.block, amount: oneWaUsdc });
    for (const [source] of amountMappings) {
      if (hasAmount(row[source])) requests.push({ block: row.block, amount: BigInt(row[source]) });
    }
  }

  const converted = await convertWaUsdcRequests(rpcUrl, waUsdc, requests, concurrency);

  for (const row of rows) {
    const exchangeRate = converted.get(conversionKey(row.block, oneWaUsdc));
    row.wausdc_usdc_exchange_rate_raw = exchangeRate;
    row.wausdc_usdc_exchange_rate = formatUnits(exchangeRate, decimals);

    for (const [source, rawTarget, decimalTarget] of amountMappings) {
      if (!hasAmount(row[source])) {
        row[rawTarget] = "";
        row[decimalTarget] = "";
        continue;
      }

      const usdcAmount = converted.get(conversionKey(row.block, BigInt(row[source])));
      row[rawTarget] = usdcAmount;
      row[decimalTarget] = formatUnits(usdcAmount, decimals);
    }

    if (hasAmount(row.helper_usdc_received_raw)) {
      row.helper_usdc_received = formatUnits(row.helper_usdc_received_raw, decimals);
    } else {
      row.helper_usdc_received = "";
    }
  }
}

function applyPrincipalAccounting(rows, decimals) {
  let outstandingPrincipalWaUsdc = 0n;
  let outstandingPrincipalUsdcCost = 0n;
  let cumulativePrincipalBorrowedUsdc = 0n;
  let cumulativeBaseInterestUsdc = 0n;
  let cumulativePremiumUsdc = 0n;

  for (const row of rows) {
    row.principal_borrowed_usdc_raw = "";
    row.principal_borrowed_usdc = "";
    row.principal_repaid_wausdc_raw = "";
    row.principal_repaid_wausdc = "";
    row.principal_cost_basis_repaid_usdc_raw = "";
    row.principal_cost_basis_repaid_usdc = "";
    if (hasAmount(row.helper_usdc_received_raw)) {
      row.helper_usdc_received = formatUnits(row.helper_usdc_received_raw, decimals);
    }

    if (row.event_type === "borrow") {
      const borrowedUsdc = hasAmount(row.helper_usdc_received_raw)
        ? BigInt(row.helper_usdc_received_raw)
        : BigInt(row.assets_usdc_raw);

      if (row.borrow_via_helper && !hasAmount(row.helper_usdc_received_raw)) {
        row.helper_usdc_received_raw = borrowedUsdc;
        row.helper_usdc_received = formatUnits(borrowedUsdc, decimals);
      }

      outstandingPrincipalWaUsdc += BigInt(row.assets);
      outstandingPrincipalUsdcCost += borrowedUsdc;
      cumulativePrincipalBorrowedUsdc += borrowedUsdc;
      row.principal_borrowed_usdc_raw = borrowedUsdc;
      row.principal_borrowed_usdc = formatUnits(borrowedUsdc, decimals);
    } else if (row.event_type === "repay") {
      const sharesRepaid = BigInt(row.shares);
      const sharesBefore = BigInt(row.borrower_borrow_shares_before);
      const principalReduction = proportionalReduction(outstandingPrincipalWaUsdc, sharesRepaid, sharesBefore);
      const costReduction = proportionalReduction(outstandingPrincipalUsdcCost, sharesRepaid, sharesBefore);

      outstandingPrincipalWaUsdc -= principalReduction;
      outstandingPrincipalUsdcCost -= costReduction;
      row.principal_repaid_wausdc_raw = principalReduction;
      row.principal_repaid_wausdc = formatUnits(principalReduction, decimals);
      row.principal_cost_basis_repaid_usdc_raw = costReduction;
      row.principal_cost_basis_repaid_usdc = formatUnits(costReduction, decimals);
    } else if (row.event_type === "account_settled") {
      row.principal_repaid_wausdc_raw = outstandingPrincipalWaUsdc;
      row.principal_repaid_wausdc = formatUnits(outstandingPrincipalWaUsdc, decimals);
      row.principal_cost_basis_repaid_usdc_raw = outstandingPrincipalUsdcCost;
      row.principal_cost_basis_repaid_usdc = formatUnits(outstandingPrincipalUsdcCost, decimals);
      outstandingPrincipalWaUsdc = 0n;
      outstandingPrincipalUsdcCost = 0n;
    }

    if (hasAmount(row.base_interest_usdc_raw)) cumulativeBaseInterestUsdc += BigInt(row.base_interest_usdc_raw);
    if (hasAmount(row.premium_usdc_raw)) cumulativePremiumUsdc += BigInt(row.premium_usdc_raw);

    row.principal_outstanding_wausdc_raw = outstandingPrincipalWaUsdc;
    row.principal_outstanding_wausdc = formatUnits(outstandingPrincipalWaUsdc, decimals);
    row.principal_cost_basis_usdc_raw = outstandingPrincipalUsdcCost;
    row.principal_cost_basis_usdc = formatUnits(outstandingPrincipalUsdcCost, decimals);
    row.cumulative_principal_borrowed_usdc_raw = cumulativePrincipalBorrowedUsdc;
    row.cumulative_principal_borrowed_usdc = formatUnits(cumulativePrincipalBorrowedUsdc, decimals);
    row.cumulative_base_interest_usdc_raw = cumulativeBaseInterestUsdc;
    row.cumulative_base_interest_usdc = formatUnits(cumulativeBaseInterestUsdc, decimals);
    row.cumulative_premium_usdc_raw = cumulativePremiumUsdc;
    row.cumulative_premium_usdc = formatUnits(cumulativePremiumUsdc, decimals);
  }
}

async function enrichPrincipalValues(rpcUrl, rows, waUsdc, decimals, concurrency) {
  const requests = rows.map((row) => ({ block: row.block, amount: BigInt(row.principal_outstanding_wausdc_raw) }));
  const converted = await convertWaUsdcRequests(rpcUrl, waUsdc, requests, concurrency);

  for (const row of rows) {
    const principalValue = converted.get(conversionKey(row.block, BigInt(row.principal_outstanding_wausdc_raw)));
    const principalCost = BigInt(row.principal_cost_basis_usdc_raw);
    const principalGrowth = principalValue - principalCost;
    const debtAfterUsdc = BigInt(row.debt_after_usdc_raw);
    const nonPrincipalDebt = debtAfterUsdc - principalValue;

    row.principal_value_usdc_raw = principalValue;
    row.principal_value_usdc = formatUnits(principalValue, decimals);
    row.principal_wausdc_growth_usdc_raw = principalGrowth;
    row.principal_wausdc_growth_usdc = formatUnits(principalGrowth, decimals);
    row.principal_wausdc_growth_pct = formatPercent(principalGrowth, principalCost);
    row.non_principal_debt_usdc_raw = nonPrincipalDebt;
    row.non_principal_debt_usdc = formatUnits(nonPrincipalDebt, decimals);
  }
}

async function convertWaUsdcRequests(rpcUrl, waUsdc, requests, concurrency) {
  const uniqueRequests = new Map();
  for (const request of requests) uniqueRequests.set(conversionKey(request.block, request.amount), request);

  const converted = new Map();
  await mapLimit([...uniqueRequests.values()], concurrency, async ({ block, amount }) => {
    const data = WAUSDC_INTERFACE.encodeFunctionData("convertToAssets", [amount]);
    const result = await call(rpcUrl, waUsdc, data, block);
    const [assets] = WAUSDC_INTERFACE.decodeFunctionResult("convertToAssets", result);
    converted.set(conversionKey(block, amount), assets);
  });

  return converted;
}

function proportionalReduction(amount, sharesRepaid, sharesBefore) {
  if (amount === 0n || sharesRepaid === 0n) return 0n;
  if (sharesBefore === 0n || sharesRepaid >= sharesBefore) return amount;
  return (amount * sharesRepaid) / sharesBefore;
}

function conversionKey(block, amount) {
  return `${block}:${amount}`;
}

function hasAmount(value) {
  return value !== undefined && value !== null && value !== "";
}

function formatPercent(numerator, denominator) {
  if (denominator === 0n) return "";
  const scaledPercentage = (numerator * 100n * 1_000_000n) / denominator;
  return formatUnits(scaledPercentage, 6);
}

function toCsv(rows) {
  const headers = [
    "datetime_utc",
    "timestamp",
    "block",
    "tx_hash",
    "log_index",
    "event_type",
    "borrower",
    "market_id",
    "caller",
    "receiver",
    "borrow_via_helper",
    "helper_address",
    "helper_proceeds_source",
    "helper_usdc_received_raw",
    "helper_usdc_received",
    "wausdc_usdc_exchange_rate_raw",
    "wausdc_usdc_exchange_rate",
    "assets",
    "assets_decimal",
    "assets_usdc_raw",
    "assets_usdc",
    "shares",
    "base_interest_assets",
    "base_interest_decimal",
    "base_interest_usdc_raw",
    "base_interest_usdc",
    "premium_assets",
    "premium_decimal",
    "premium_usdc_raw",
    "premium_usdc",
    "premium_fee_assets",
    "premium_fee_usdc_raw",
    "premium_fee_usdc",
    "written_off_assets",
    "written_off_usdc_raw",
    "written_off_usdc",
    "written_off_shares",
    "debt_before_assets",
    "debt_before_decimal",
    "debt_before_usdc_raw",
    "debt_before_usdc",
    "debt_after_assets",
    "debt_after_decimal",
    "debt_after_usdc_raw",
    "debt_after_usdc",
    "principal_borrowed_usdc_raw",
    "principal_borrowed_usdc",
    "principal_repaid_wausdc_raw",
    "principal_repaid_wausdc",
    "principal_cost_basis_repaid_usdc_raw",
    "principal_cost_basis_repaid_usdc",
    "principal_outstanding_wausdc_raw",
    "principal_outstanding_wausdc",
    "principal_cost_basis_usdc_raw",
    "principal_cost_basis_usdc",
    "principal_value_usdc_raw",
    "principal_value_usdc",
    "principal_wausdc_growth_usdc_raw",
    "principal_wausdc_growth_usdc",
    "principal_wausdc_growth_pct",
    "non_principal_debt_usdc_raw",
    "non_principal_debt_usdc",
    "cumulative_principal_borrowed_usdc_raw",
    "cumulative_principal_borrowed_usdc",
    "cumulative_base_interest_usdc_raw",
    "cumulative_base_interest_usdc",
    "cumulative_premium_usdc_raw",
    "cumulative_premium_usdc",
    "borrower_borrow_shares_before",
    "borrower_borrow_shares_after",
    "market_total_borrow_assets_after",
    "market_total_borrow_usdc_raw",
    "market_total_borrow_usdc",
    "market_total_borrow_shares_after",
    "prev_borrow_rate",
    "market_interest_assets",
    "market_interest_usdc_raw",
    "market_interest_usdc",
  ];

  return `${[headers.join(","), ...rows.map((row) => headers.map((header) => csvEscape(row[header])).join(","))].join(
    "\n",
  )}\n`;
}

async function loadBlockTimestamps(rpcUrl, blocks) {
  const timestamps = new Map();

  for (const block of blocks) {
    const key = block.toString();
    if (timestamps.has(key)) continue;

    const data = await rpc(rpcUrl, "eth_getBlockByNumber", [toQuantity(block), false]);
    if (!data) throw new Error(`Missing block ${block}`);
    timestamps.set(key, fromQuantity(data.timestamp));
  }

  return timestamps;
}

async function validateReplay(rpcUrl, morphoCredit, marketId, borrower, blockNumber, state) {
  const marketData = MORPHO_INTERFACE.encodeFunctionData("market", [marketId]);
  const positionData = MORPHO_INTERFACE.encodeFunctionData("position", [marketId, borrower]);
  const marketResult = await call(rpcUrl, morphoCredit, marketData, blockNumber);
  const positionResult = await call(rpcUrl, morphoCredit, positionData, blockNumber);
  const market = MORPHO_INTERFACE.decodeFunctionResult("market", marketResult);
  const position = MORPHO_INTERFACE.decodeFunctionResult("position", positionResult);
  const mismatches = [];

  if (state.totalBorrowAssets !== market.totalBorrowAssets) {
    mismatches.push(`totalBorrowAssets replay=${state.totalBorrowAssets} onchain=${market.totalBorrowAssets}`);
  }
  if (state.totalBorrowShares !== market.totalBorrowShares) {
    mismatches.push(`totalBorrowShares replay=${state.totalBorrowShares} onchain=${market.totalBorrowShares}`);
  }
  if (state.borrowerShares !== position.borrowShares) {
    mismatches.push(`borrowerBorrowShares replay=${state.borrowerShares} onchain=${position.borrowShares}`);
  }

  if (mismatches.length !== 0) {
    throw new Error(`Replay validation failed at block ${blockNumber}: ${mismatches.join("; ")}`);
  }
}

async function getLogsChunked(rpcUrl, address, fromBlock, toBlock, topics, chunkBlocks) {
  const logs = [];
  let start = fromBlock;

  while (start <= toBlock) {
    const end = start + chunkBlocks - 1n > toBlock ? toBlock : start + chunkBlocks - 1n;
    const chunkLogs = await rpc(rpcUrl, "eth_getLogs", [
      {
        address,
        fromBlock: toQuantity(start),
        toBlock: toQuantity(end),
        topics,
      },
    ]);
    logs.push(...chunkLogs);
    start = end + 1n;
  }

  return logs;
}

async function call(rpcUrl, to, data, blockNumber) {
  return rpc(rpcUrl, "eth_call", [{ to, data }, toQuantity(blockNumber)]);
}

async function rpc(rpcUrl, method, params) {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const body = await response.json();
  if (body.error) throw new Error(`${method}: ${body.error.message}`);
  return body.result;
}

async function mapLimit(items, concurrency, worker) {
  if (!Number.isInteger(concurrency) || concurrency < 1) throw new Error("RPC concurrency must be at least 1");

  let nextIndex = 0;
  const workers = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (nextIndex < items.length) {
      const index = nextIndex;
      nextIndex += 1;
      await worker(items[index], index);
    }
  });

  await Promise.all(workers);
}

function borrowerDebt(totalBorrowAssets, totalBorrowShares, borrowerShares) {
  if (borrowerShares === 0n) return 0n;
  return toAssetsUp(borrowerShares, totalBorrowAssets, totalBorrowShares);
}

function toAssetsUp(shares, totalAssets, totalShares) {
  return mulDivUp(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
}

function toSharesUp(assets, totalAssets, totalShares) {
  return mulDivUp(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
}

function mulDivUp(x, y, d) {
  if (x === 0n || y === 0n) return 0n;
  return (x * y - 1n) / d + 1n;
}

function zeroFloorSub(x, y) {
  return x > y ? x - y : 0n;
}

function wordAt(data, index) {
  const hex = data.startsWith("0x") ? data.slice(2) : data;
  return BigInt(`0x${hex.slice(index * 64, (index + 1) * 64) || "0"}`);
}

function addressFromTopic(topic) {
  return getAddress(`0x${topic.slice(-40)}`);
}

function addressFromWord(data, index) {
  const hex = data.startsWith("0x") ? data.slice(2) : data;
  return getAddress(`0x${hex.slice(index * 64 + 24, (index + 1) * 64)}`);
}

function compareLogPosition(a, b) {
  const aBlock = fromQuantity(a.blockNumber);
  const bBlock = fromQuantity(b.blockNumber);
  if (aBlock !== bBlock) return aBlock < bBlock ? -1 : 1;

  const aLogIndex = fromQuantity(a.logIndex);
  const bLogIndex = fromQuantity(b.logIndex);
  if (aLogIndex !== bLogIndex) return aLogIndex < bLogIndex ? -1 : 1;

  return 0;
}

function maybeFormat(value, decimals) {
  return value === undefined || value === "" ? "" : formatUnits(value, decimals);
}

function csvEscape(value) {
  const str = value === undefined || value === null ? "" : value.toString();
  return /[",\n]/.test(str) ? `"${str.replace(/"/g, '""')}"` : str;
}

function formatTimestamp(timestamp) {
  return new Date(Number(timestamp) * 1000).toISOString().replace("T", " ").replace(".000Z", " UTC");
}

function parseBlockEnv(raw, fallbackValue) {
  if (!raw || raw === "latest") return fallbackValue;
  return BigInt(raw);
}

function parseBigIntEnv(name, fallbackValue) {
  const raw = process.env[name];
  return raw ? BigInt(raw) : fallbackValue;
}

function parseAddressListEnv(name, fallbackValue) {
  const raw = process.env[name];
  const values = raw ? raw.split(",") : fallbackValue;
  return values
    .map((value) => value.trim())
    .filter(Boolean)
    .map((value) => getAddress(value));
}

function toQuantity(value) {
  return `0x${BigInt(value).toString(16)}`;
}

function fromQuantity(value) {
  return BigInt(value);
}

function mustEnv(name) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}
