export const securityHookAbi = [
  {
    type: "event",
    name: "SecurityTelemetry",
    anonymous: false,
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" },
      { indexed: true, name: "sender", type: "address" },
      { indexed: false, name: "zeroForOne", type: "bool" },
      { indexed: false, name: "amountSpecified", type: "int256" },
      { indexed: false, name: "tick", type: "int24" },
      { indexed: false, name: "sqrtPriceX96", type: "uint160" },
      { indexed: false, name: "rollingVolatilityBps", type: "uint32" },
      { indexed: false, name: "priceDeviationBps", type: "uint32" },
      { indexed: false, name: "slippageBps", type: "uint32" },
      { indexed: false, name: "liquidityImbalanceBps", type: "uint32" },
      { indexed: false, name: "rollingVolume", type: "uint128" },
      { indexed: false, name: "observedAt", type: "uint64" },
      { indexed: false, name: "sequence", type: "uint64" }
    ]
  },
  {
    type: "event",
    name: "ProtectionApplied",
    anonymous: false,
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" },
      { indexed: true, name: "nonce", type: "uint256" },
      { indexed: false, name: "riskScoreBps", type: "uint16" },
      { indexed: false, name: "dynamicFeePips", type: "uint24" },
      { indexed: false, name: "throttleBps", type: "uint16" },
      { indexed: false, name: "maxTradeSize", type: "uint128" },
      { indexed: false, name: "pauseUntil", type: "uint64" },
      { indexed: false, name: "reason", type: "bytes32" }
    ]
  }
] as const;
