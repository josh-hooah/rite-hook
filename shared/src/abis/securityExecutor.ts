export const securityExecutorAbi = [
  {
    type: "event",
    name: "MitigationAccepted",
    anonymous: false,
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" },
      { indexed: true, name: "nonce", type: "uint256" },
      { indexed: false, name: "riskScoreBps", type: "uint16" },
      { indexed: false, name: "reason", type: "bytes32" }
    ]
  },
  {
    type: "event",
    name: "MitigationRejected",
    anonymous: false,
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" },
      { indexed: true, name: "nonce", type: "uint256" },
      { indexed: false, name: "reason", type: "bytes32" }
    ]
  }
] as const;
