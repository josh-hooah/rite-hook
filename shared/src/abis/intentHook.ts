export const intentHookAbi = [
  {
    type: "event",
    name: "SwapTelemetry",
    anonymous: false,
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" },
      { indexed: true, name: "sender", type: "address" },
      { indexed: false, name: "tick", type: "int24" },
      { indexed: false, name: "sqrtPriceX96", type: "uint160" },
      { indexed: false, name: "rollingVolatilityBps", type: "uint32" },
      { indexed: false, name: "amount0Delta", type: "int128" },
      { indexed: false, name: "amount1Delta", type: "int128" },
      { indexed: false, name: "observedAt", type: "uint64" }
    ]
  }
] as const;
