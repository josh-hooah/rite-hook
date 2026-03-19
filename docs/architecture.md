# Architecture

## Origin -> Reactive -> Destination

```mermaid
flowchart LR
  subgraph O[Origin Chain]
    PM[PoolManager]
    IH[IntentHook]
    SH[SecurityHook]
    PM --> IH
    PM --> SH
  end

  subgraph R[Reactive Network]
    SYS[System subscribe(...)]
    IR[IntentReactive]
    SR[SecurityReactive]
    SYS --> IR
    SYS --> SR
  end

  subgraph D[Destination Chain]
    CP[Callback Proxy]
    IE[IntentExecutor]
    SE[SecurityExecutor]
    AD[HookmateV4SwapAdapter]
    CP --> IE
    CP --> SE
    IE --> AD
    SE --> SH
  end

  IH -- SwapTelemetry --> IR
  SH -- SecurityTelemetry --> SR
  IR -- executeIntent callback --> CP
  SR -- applyMitigation callback --> CP
```

## Intent Lifecycle

```mermaid
sequenceDiagram
  participant User
  participant IE as IntentExecutor
  participant IH as IntentHook
  participant IR as IntentReactive
  participant CP as CallbackProxy
  participant AD as SwapAdapter

  User->>IE: createIntent
  IE-->>IR: IntentCreated
  IH-->>IR: SwapTelemetry
  IR->>IR: trigger evaluation
  IR-->>CP: Callback(executeIntent)
  CP->>IE: executeIntent(reactVM,...)
  IE->>IE: auth + nonce + trigger
  IE->>AD: executeSwap
  AD-->>IE: output amount
```

## Security Lifecycle

```mermaid
sequenceDiagram
  participant Swapper
  participant PM as PoolManager
  participant SH as SecurityHook
  participant SR as SecurityReactive
  participant CP as CallbackProxy
  participant SE as SecurityExecutor

  Swapper->>PM: swap
  PM->>SH: beforeSwap
  SH->>SH: enforce protection state
  PM->>SH: afterSwap
  SH-->>SR: SecurityTelemetry
  SR->>SR: score components + riskScore
  SR-->>CP: Callback(applyMitigation)
  CP->>SE: applyMitigation(reactVM,...)
  SE->>SE: auth + nonce checks
  SE->>SH: applyProtection
```

## Component Interaction

```mermaid
graph TD
  IH[IntentHook] --> IT[IntentTelemetry]
  IT --> IR[IntentReactive]
  IR --> ICB[Intent Callback]
  ICB --> IE[IntentExecutor]
  IE --> AD[SwapAdapter]

  SH[SecurityHook] --> ST[SecurityTelemetry]
  ST --> SR[SecurityReactive]
  SR --> SCB[Security Callback]
  SCB --> SE[SecurityExecutor]
  SE --> SH

  FE[Frontend] --> IE
  FE --> SH
  FE --> SE
```

## Contract Boundaries
- `IntentHook`: swap-observation telemetry source for intent triggers
- `IntentReactive`: trigger evaluation + callback dispatch
- `IntentExecutor`: callback auth + intent lifecycle + settlement
- `HookmateV4SwapAdapter`: swap execution adapter boundary
- `SecurityHook`: risk telemetry + mitigation enforcement
- `SecurityReactive`: deterministic risk scoring + callback dispatch
- `SecurityExecutor`: callback trust gate + replay/idempotency controls

## Reactive Dual-State Notes
Per Reactive base architecture:

- `rnOnly` code runs in Reactive Network state context
- `vmOnly` code runs in ReactVM context

`IntentReactive.react(LogRecord)` and `SecurityReactive.react(LogRecord)` are `vmOnly` entrypoints.
