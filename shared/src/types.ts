export enum TriggerType {
  PRICE = 0,
  TIME = 1,
  VOLATILITY = 2,
}

export enum IntentStatus {
  NONE = 0,
  PENDING = 1,
  EXECUTED = 2,
  CANCELLED = 3,
  EXPIRED = 4,
}

export type TriggerConfig = {
  targetSqrtPriceX96: bigint;
  priceAbove: boolean;
  startTime: bigint;
  endTime: bigint;
  interval: bigint;
  volatilityBps: number;
  volatilityAbove: boolean;
  chunkBips: number;
};

export type IntentView = {
  intentId: `0x${string}`;
  user: `0x${string}`;
  poolId: `0x${string}`;
  tokenIn: `0x${string}`;
  tokenOut: `0x${string}`;
  zeroForOne: boolean;
  amountIn: bigint;
  amountOutMin: bigint;
  triggerType: TriggerType;
  trigger: TriggerConfig;
  expiry: bigint;
  nonce: bigint;
  remainingAmount: bigint;
  status: IntentStatus;
};

export enum MitigationMode {
  NONE = 0,
  ADAPTIVE_FEE = 1,
  THROTTLE = 2,
  PAUSE = 3,
  COMBINED = 4,
}

export type SecurityTelemetryView = {
  poolId: `0x${string}`;
  sender: `0x${string}`;
  zeroForOne: boolean;
  amountSpecified: bigint;
  tick: number;
  sqrtPriceX96: bigint;
  rollingVolatilityBps: number;
  priceDeviationBps: number;
  slippageBps: number;
  liquidityImbalanceBps: number;
  rollingVolume: bigint;
  observedAt: bigint;
  sequence: bigint;
};

export type ProtectionStateView = {
  currentFeePips: number;
  throttleBps: number;
  maxTradeSize: bigint;
  pauseUntil: bigint;
  lastRiskScoreBps: number;
  updatedAt: bigint;
  nonce: bigint;
};

export type MitigationEventView = {
  poolId: `0x${string}`;
  nonce: bigint;
  riskScoreBps: number;
  mode: MitigationMode;
  reason: `0x${string}`;
  txHash: `0x${string}`;
  blockNumber: bigint;
};
