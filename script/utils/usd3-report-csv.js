#!/usr/bin/env node

const { id } = require("ethers");

const USD3 = "0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc";
const SUSD3 = "0xf689555121e529Ff0463e191F9Bd9d1E496164a7";
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const DEFAULT_DEPLOYER = "0x1226858E04b9d077258F153275613734421cD06B";

const REPORT_TOPIC = id("Reported(uint256,uint256,uint256,uint256)");
const TRANSFER_TOPIC = id("Transfer(address,address,uint256)");
const DEPOSIT_TOPIC = id("Deposit(address,address,uint256,uint256)");
const FULL_PROFIT_UNLOCK_DATE_SELECTOR = id("fullProfitUnlockDate()").slice(0, 10);

const DEFAULT_FROM_TIMESTAMP = 1780617600n; // 2026-06-05 00:00:00 UTC
const DEFAULT_LOOKBACK_BLOCKS = 100_000n;
const DEFAULT_LOG_CHUNK_BLOCKS = 20_000n;

main().catch((err) => {
  console.error(err.stack || err.message || String(err));
  process.exit(1);
});

async function main() {
  const rpcUrl = mustEnv("ETH_RPC_URL");
  const deployer = (process.env.USD3_REPORT_DEPLOYER || DEFAULT_DEPLOYER).toLowerCase();
  const latestBlock = fromQuantity(await rpc(rpcUrl, "eth_blockNumber", []));
  const toBlock = parseBlockEnv(process.env.USD3_REPORT_TO_BLOCK, latestBlock);
  const fromBlock = await resolveFromBlock(rpcUrl, latestBlock);
  const lookbackBlocks = parseBigIntEnv("USD3_REPORT_LOOKBACK_BLOCKS", DEFAULT_LOOKBACK_BLOCKS);
  const chunkBlocks = parseBigIntEnv("USD3_REPORT_LOG_CHUNK_BLOCKS", DEFAULT_LOG_CHUNK_BLOCKS);
  const previousSearchFrom = fromBlock > lookbackBlocks ? fromBlock - lookbackBlocks : 0n;

  const usd3Reports = await getLogsChunked(rpcUrl, USD3, previousSearchFrom, toBlock, [REPORT_TOPIC], chunkBlocks);
  const susd3Reports = await getLogsChunked(rpcUrl, SUSD3, fromBlock, toBlock, [REPORT_TOPIC], chunkBlocks);

  const previousUsd3Reports = usd3Reports.filter((log) => fromQuantity(log.blockNumber) < fromBlock);
  const reportUsd3Logs = usd3Reports.filter((log) => fromQuantity(log.blockNumber) >= fromBlock);
  const latestPreviousUsd3Report =
    previousUsd3Reports.length === 0 ? null : previousUsd3Reports[previousUsd3Reports.length - 1];

  const reportRows = [
    ...reportUsd3Logs.map((log) => parseReportLog("USD3", USD3, "USDC", log)),
    ...susd3Reports.map((log) => parseReportLog("sUSD3", SUSD3, "USD3", log)),
  ].sort(compareReportRows);

  const contributionByUsd3ReportBlock = await loadContributionsByUsd3ReportBlock(
    rpcUrl,
    deployer,
    latestPreviousUsd3Report,
    reportUsd3Logs,
    chunkBlocks,
  );

  const blockTimestamps = new Map();
  for (const row of reportRows) {
    if (!blockTimestamps.has(row.block.toString())) {
      blockTimestamps.set(row.block.toString(), await getBlockTimestamp(rpcUrl, row.block));
    }
  }

  const csvRows = [
    [
      "report_utc",
      "strategy",
      "block",
      "profit",
      "profit_unit",
      "raw_usdc_contribution",
      "native_yield_ex_raw_usdc",
      "full_unlock_utc",
      "full_unlock_duration_seconds",
      "full_unlock_duration_human",
    ].join(","),
  ];

  for (const row of reportRows) {
    const reportTimestamp = blockTimestamps.get(row.block.toString());
    const fullUnlockDate = await callUint(rpcUrl, row.strategyAddress, FULL_PROFIT_UNLOCK_DATE_SELECTOR, row.block);
    const unlockDuration = fullUnlockDate > reportTimestamp ? fullUnlockDate - reportTimestamp : 0n;
    const contribution = row.label === "USD3" ? contributionByUsd3ReportBlock.get(row.block.toString()) || 0n : null;
    const nativeYield = contribution === null ? null : row.profit - contribution;

    csvRows.push(
      [
        formatTimestamp(reportTimestamp),
        row.label,
        row.block.toString(),
        formatToken(row.profit, 6),
        row.profitUnit,
        contribution === null ? "" : formatToken(contribution, 6),
        nativeYield === null ? "" : formatSignedToken(nativeYield, 6),
        formatTimestamp(fullUnlockDate),
        unlockDuration.toString(),
        formatDuration(unlockDuration),
      ].join(","),
    );
  }

  process.stdout.write(`${csvRows.join("\n")}\n`);
}

async function resolveFromBlock(rpcUrl, latestBlock) {
  if (process.env.USD3_REPORT_FROM_BLOCK) return BigInt(process.env.USD3_REPORT_FROM_BLOCK);

  const fromTimestamp = parseBigIntEnv("USD3_REPORT_FROM_TIMESTAMP", DEFAULT_FROM_TIMESTAMP);
  let low = 0n;
  let high = latestBlock;

  while (low < high) {
    const mid = (low + high) / 2n;
    const timestamp = await getBlockTimestamp(rpcUrl, mid);
    if (timestamp < fromTimestamp) {
      low = mid + 1n;
    } else {
      high = mid;
    }
  }

  return low;
}

async function loadContributionsByUsd3ReportBlock(rpcUrl, deployer, previousReportLog, reportLogs, chunkBlocks) {
  const result = new Map();
  if (reportLogs.length === 0) return result;

  let previousReportBlock = previousReportLog ? fromQuantity(previousReportLog.blockNumber) : null;
  const firstWindowBlock =
    previousReportBlock === null ? fromQuantity(reportLogs[0].blockNumber) : previousReportBlock + 1n;
  const lastReportBlock = fromQuantity(reportLogs[reportLogs.length - 1].blockNumber);

  const transferLogs = await getLogsChunked(
    rpcUrl,
    USDC,
    firstWindowBlock,
    lastReportBlock,
    [TRANSFER_TOPIC, topicAddress(deployer), topicAddress(USD3)],
    chunkBlocks,
  );
  const depositLogs = await getLogsChunked(
    rpcUrl,
    USD3,
    firstWindowBlock,
    lastReportBlock,
    [DEPOSIT_TOPIC, topicAddress(deployer)],
    chunkBlocks,
  );
  const depositAmountsByTx = new Map();

  for (const log of depositLogs) {
    const txHash = log.transactionHash.toLowerCase();
    const amounts = depositAmountsByTx.get(txHash) || [];
    amounts.push(wordAt(log.data, 0));
    depositAmountsByTx.set(txHash, amounts);
  }

  const sortedTransfers = transferLogs.map(parseTransferLog).sort(compareLogPosition);
  const sortedReports = reportLogs
    .map((log) => ({
      block: fromQuantity(log.blockNumber),
      logIndex: fromQuantity(log.logIndex),
    }))
    .sort(compareLogPosition);

  let transferIndex = 0;
  let windowStartBlock = previousReportBlock === null ? firstWindowBlock : previousReportBlock + 1n;

  for (const report of sortedReports) {
    let contribution = 0n;

    while (transferIndex < sortedTransfers.length) {
      const transfer = sortedTransfers[transferIndex];
      if (transfer.block < windowStartBlock) {
        transferIndex++;
        continue;
      }
      if (transfer.block > report.block) break;
      if (transfer.block === report.block && transfer.logIndex > report.logIndex) break;

      if (!isDepositTransfer(transfer, depositAmountsByTx)) {
        contribution += transfer.amount;
      }
      transferIndex++;
    }

    result.set(report.block.toString(), contribution);
    windowStartBlock = report.block + 1n;
  }

  return result;
}

function isDepositTransfer(transfer, depositAmountsByTx) {
  const amounts = depositAmountsByTx.get(transfer.txHash);
  if (!amounts) return false;

  for (let i = 0; i < amounts.length; i++) {
    if (amounts[i] === transfer.amount) {
      amounts.splice(i, 1);
      return true;
    }
  }

  return false;
}

function parseReportLog(label, strategyAddress, profitUnit, log) {
  return {
    label,
    strategyAddress,
    profitUnit,
    block: fromQuantity(log.blockNumber),
    logIndex: fromQuantity(log.logIndex),
    profit: wordAt(log.data, 0),
  };
}

function parseTransferLog(log) {
  return {
    block: fromQuantity(log.blockNumber),
    logIndex: fromQuantity(log.logIndex),
    txHash: log.transactionHash.toLowerCase(),
    amount: wordAt(log.data, 0),
  };
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

  return logs.sort(compareLogPosition);
}

async function getBlockTimestamp(rpcUrl, blockNumber) {
  const block = await rpc(rpcUrl, "eth_getBlockByNumber", [toQuantity(blockNumber), false]);
  if (!block) throw new Error(`Missing block ${blockNumber}`);
  return fromQuantity(block.timestamp);
}

async function callUint(rpcUrl, to, data, blockNumber) {
  const result = await rpc(rpcUrl, "eth_call", [{ to, data }, toQuantity(blockNumber)]);
  return fromQuantity(result);
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

function compareReportRows(a, b) {
  const position = compareLogPosition(a, b);
  if (position !== 0) return position;
  return a.label.localeCompare(b.label);
}

function compareLogPosition(a, b) {
  const aBlock = a.block === undefined ? fromQuantity(a.blockNumber) : a.block;
  const bBlock = b.block === undefined ? fromQuantity(b.blockNumber) : b.block;
  const aLogIndex = a.logIndex === undefined ? fromQuantity(a.logIndex) : a.logIndex;
  const bLogIndex = b.logIndex === undefined ? fromQuantity(b.logIndex) : b.logIndex;

  if (aBlock !== bBlock) return aBlock < bBlock ? -1 : 1;
  if (aLogIndex !== bLogIndex) return aLogIndex < bLogIndex ? -1 : 1;
  return 0;
}

function wordAt(data, index) {
  const hex = data.startsWith("0x") ? data.slice(2) : data;
  return BigInt(`0x${hex.slice(index * 64, (index + 1) * 64) || "0"}`);
}

function topicAddress(address) {
  return `0x${address.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`;
}

function toQuantity(value) {
  return `0x${BigInt(value).toString(16)}`;
}

function fromQuantity(value) {
  return BigInt(value);
}

function formatTimestamp(timestamp) {
  return new Date(Number(timestamp) * 1000).toISOString().replace("T", " ").replace(".000Z", " UTC");
}

function formatDuration(seconds) {
  if (seconds === 0n) return "0s";

  const days = seconds / 86400n;
  const hours = (seconds % 86400n) / 3600n;
  const minutes = (seconds % 3600n) / 60n;
  const remainingSeconds = seconds % 60n;
  const parts = [];

  if (days) parts.push(`${days}d`);
  if (hours) parts.push(`${hours}h`);
  if (minutes) parts.push(`${minutes}m`);
  if (remainingSeconds) parts.push(`${remainingSeconds}s`);

  return parts.join(" ");
}

function formatSignedToken(amount, decimals) {
  return amount < 0n ? `-${formatToken(-amount, decimals)}` : formatToken(amount, decimals);
}

function formatToken(amount, decimals) {
  const scale = 10n ** BigInt(decimals);
  const whole = amount / scale;
  const fraction = amount % scale;
  if (fraction === 0n) return whole.toString();

  return `${whole}.${fraction.toString().padStart(decimals, "0").replace(/0+$/, "")}`;
}

function parseBlockEnv(name, fallbackValue) {
  const raw = name || "latest";
  if (raw === "latest") return fallbackValue;
  return BigInt(raw);
}

function parseBigIntEnv(name, fallbackValue) {
  const raw = process.env[name];
  return raw ? BigInt(raw) : fallbackValue;
}

function mustEnv(name) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}
