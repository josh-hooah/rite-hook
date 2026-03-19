#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function usage() {
  console.error("Usage: node scripts/print_broadcast_summary.mjs <run-latest.json> [chainId]");
  process.exit(1);
}

const file = process.argv[2];
const chainArg = process.argv[3];
if (!file) {
  usage();
}

const target = path.resolve(file);
if (!fs.existsSync(target)) {
  console.error(`[demo] broadcast file not found: ${target}`);
  process.exit(1);
}

let parsed;
try {
  parsed = JSON.parse(fs.readFileSync(target, "utf8"));
} catch (error) {
  console.error(`[demo] failed to parse JSON: ${target}`);
  console.error(String(error));
  process.exit(1);
}

const chainId = Number(chainArg ?? parsed.chain ?? 0);
const txs = Array.isArray(parsed.transactions) ? parsed.transactions : [];
const receipts = Array.isArray(parsed.receipts) ? parsed.receipts : [];

const explorers = {
  base:
    chainId === 84532 ? "https://sepolia.basescan.org/tx/" : null,
  lasna: "https://lasna.reactscan.net/tx/",
};

const deployments = txs
  .filter((tx) => (tx.transactionType === "CREATE" || tx.transactionType === "CREATE2") && tx.contractName && tx.contractAddress)
  .map((tx) => ({ contractName: tx.contractName, contractAddress: tx.contractAddress }));

console.log(`[demo] broadcast file: ${target}`);
console.log(`[demo] chain id: ${chainId || "unknown"}`);

if (deployments.length > 0) {
  console.log("[demo] deployed contracts:");
  for (const deployment of deployments) {
    console.log(`  - ${deployment.contractName}: ${deployment.contractAddress}`);
  }
}

if (txs.length === 0) {
  console.log("[demo] no transactions found in broadcast file.");
  process.exit(0);
}

console.log("[demo] transactions:");
for (let i = 0; i < txs.length; i += 1) {
  const tx = txs[i];
  const receipt = receipts[i] ?? {};
  const hash =
    (typeof tx.hash === "string" && tx.hash.startsWith("0x") && tx.hash) ||
    (typeof receipt.transactionHash === "string" && receipt.transactionHash.startsWith("0x") && receipt.transactionHash) ||
    null;

  const label = tx.function
    ? `${tx.contractName ?? "Contract"}::${tx.function}`
    : `${tx.contractName ?? tx.transactionType ?? "Transaction"}`;

  console.log(`Tx ${i + 1}: ${label}`);
  if (!hash) {
    console.log("  Hash: unavailable (dry-run or pending receipts)");
    continue;
  }

  console.log(`  Hash: ${hash}`);
  if (explorers.base) {
    console.log(`  BaseSepolia: ${explorers.base}${hash}`);
  }
  if (explorers.lasna) {
    console.log(`  Lasna: ${explorers.lasna}${hash}`);
  }
}
