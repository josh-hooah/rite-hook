export const intentExecutorAbi = [
  {
    type: "function",
    name: "createIntent",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          {
            name: "poolKey",
            type: "tuple",
            components: [
              { name: "currency0", type: "address" },
              { name: "currency1", type: "address" },
              { name: "fee", type: "uint24" },
              { name: "tickSpacing", type: "int24" },
              { name: "hooks", type: "address" }
            ]
          },
          { name: "tokenIn", type: "address" },
          { name: "tokenOut", type: "address" },
          { name: "zeroForOne", type: "bool" },
          { name: "amountIn", type: "uint256" },
          { name: "amountOutMin", type: "uint256" },
          { name: "triggerType", type: "uint8" },
          {
            name: "trigger",
            type: "tuple",
            components: [
              { name: "targetSqrtPriceX96", type: "uint160" },
              { name: "priceAbove", type: "bool" },
              { name: "startTime", type: "uint64" },
              { name: "endTime", type: "uint64" },
              { name: "interval", type: "uint64" },
              { name: "volatilityBps", type: "uint32" },
              { name: "volatilityAbove", type: "bool" },
              { name: "chunkBips", type: "uint16" }
            ]
          },
          { name: "expiry", type: "uint64" }
        ]
      }
    ],
    outputs: [{ name: "intentId", type: "bytes32" }]
  },
  {
    type: "function",
    name: "getIntent",
    stateMutability: "view",
    inputs: [{ name: "intentId", type: "bytes32" }],
    outputs: [{ name: "", type: "tuple", components: [] }]
  },
  {
    type: "event",
    name: "IntentCreated",
    anonymous: false,
    inputs: [
      { indexed: true, name: "intentId", type: "bytes32" },
      { indexed: true, name: "user", type: "address" },
      { indexed: true, name: "poolId", type: "bytes32" },
      { indexed: false, name: "triggerType", type: "uint8" },
      { indexed: false, name: "triggerConfig", type: "bytes" },
      { indexed: false, name: "expiry", type: "uint64" },
      { indexed: false, name: "nonce", type: "uint256" },
      { indexed: false, name: "zeroForOne", type: "bool" },
      { indexed: false, name: "amountIn", type: "uint256" },
      { indexed: false, name: "amountOutMin", type: "uint256" }
    ]
  }
] as const;
