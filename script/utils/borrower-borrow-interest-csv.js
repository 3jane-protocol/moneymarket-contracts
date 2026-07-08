#!/usr/bin/env node

const { Interface, formatUnits, getAddress, id } = require("ethers");

const DEFAULT_MORPHO_CREDIT = "0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc";
const DEFAULT_MARKET_ID = "0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75";
const DEFAULT_BORROWER = "0x3Ff3ff33D20a086834A095ed6ed562c9e189291b";
const DEFAULT_FROM_BLOCK = 23_214_677n;
const DEFAULT_LOG_CHUNK_BLOCKS = 20_000n;
const DEFAULT_DECIMALS = 6;

const VIRTUAL_SHARES = 1_000_000n;
const VIRTUAL_ASSETS = 1n;

const BORROW_TOPIC = id("Borrow(bytes32,address,address,address,uint256,uint256)");
const REPAY_TOPIC = id("Repay(bytes32,address,address,uint256,uint256)");
const ACCRUE_INTEREST_TOPIC = id("AccrueInterest(bytes32,uint256,uint256,uint256)");
const PREMIUM_ACCRUED_TOPIC = id("PremiumAccrued(bytes32,address,uint256,uint256)");
const ACCOUNT_SETTLED_TOPIC = id("AccountSettled(bytes32,address,address,uint256,uint256)");

const MORPHO_INTERFACE = new Interface([
  "function market(bytes32) view returns (uint128 totalSupplyAssets,uint128 totalSupplyShares,uint128 totalBorrowAssets,uint128 totalBorrowShares,uint128 lastUpdate,uint128 fee,uint128 totalMarkdownAmount)",
  "function position(bytes32,address) view returns (uint256 supplyShares,uint128 borrowShares,uint128 collateral)",
]);

main().catch((err) => {
  console.error(err.stack || err.message || String(err));
  process.exit(1);
});

async function main() {
  const rpcUrl = mustEnv("ETH_RPC_URL");
  const morphoCredit = getAddress(process.env.MORPHO_CREDIT_ADDRESS || DEFAULT_MORPHO_CREDIT);
  const marketId = process.env.MORPHO_MARKET_ID || DEFAULT_MARKET_ID;
  const borrower = getAddress(process.env.MORPHO_BORROWER_REPORT_BORROWER || DEFAULT_BORROWER);
  const latestBlock = fromQuantity(await rpc(rpcUrl, "eth_blockNumber", []));
  const fromBlock = parseBigIntEnv("MORPHO_BORROWER_REPORT_FROM_BLOCK", DEFAULT_FROM_BLOCK);
  const toBlock = parseBlockEnv(process.env.MORPHO_BORROWER_REPORT_TO_BLOCK, latestBlock);
  const chunkBlocks = parseBigIntEnv("MORPHO_BORROWER_REPORT_LOG_CHUNK_BLOCKS", DEFAULT_LOG_CHUNK_BLOCKS);
  const decimals = Number(parseBigIntEnv("MORPHO_BORROWER_REPORT_DECIMALS", BigInt(DEFAULT_DECIMALS)));

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
  const timestampByBlock = await loadBlockTimestamps(rpcUrl, rows.map((row) => row.block));

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
    borrower_borrow_shares_after: values.borrowerShares,
    market_total_borrow_assets_after: values.totalBorrowAssets,
    market_total_borrow_shares_after: values.totalBorrowShares,
    prev_borrow_rate: values.prevBorrowRate ?? "",
    market_interest_assets: values.marketInterestAssets ?? "",
  };
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
    "assets",
    "assets_decimal",
    "shares",
    "base_interest_assets",
    "base_interest_decimal",
    "premium_assets",
    "premium_decimal",
    "premium_fee_assets",
    "written_off_assets",
    "written_off_shares",
    "debt_before_assets",
    "debt_before_decimal",
    "debt_after_assets",
    "debt_after_decimal",
    "borrower_borrow_shares_after",
    "market_total_borrow_assets_after",
    "market_total_borrow_shares_after",
    "prev_borrow_rate",
    "market_interest_assets",
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
  return ((x * y - 1n) / d) + 1n;
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
