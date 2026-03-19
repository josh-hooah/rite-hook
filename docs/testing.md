# Testing

## Contracts Suite
```bash
cd contracts
FOUNDRY_OFFLINE=true forge test -vv
```

## Reactive Suite
```bash
cd reactive
FOUNDRY_OFFLINE=true forge test -vv
```

## Focused Integration Suites
```bash
cd contracts
FOUNDRY_OFFLINE=true forge test --match-path test/integration/IntentLifecycle.t.sol -vv
FOUNDRY_OFFLINE=true forge test --match-path test/integration/SecurityLifecycle.t.sol -vv

cd ../reactive
FOUNDRY_OFFLINE=true forge test --match-path test/IntentReactive.t.sol -vv
FOUNDRY_OFFLINE=true forge test --match-path test/SecurityReactive.t.sol -vv
```

## Invariant Suite
```bash
cd contracts
FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=64 forge test --match-path test/invariant/IntentExecutor.invariant.t.sol -vv
```

## Coverage
```bash
cd contracts
FOUNDRY_OFFLINE=true forge coverage --report lcov --no-match-path 'test/invariant/*'
cd ..
./scripts/check_coverage.sh contracts/lcov.info
```

Coverage gate enforces:

- line coverage: `100%`
- branch coverage: `100%`
- scope filter: `src/**`

## Security Scenarios Covered
- callback proxy forgery rejection
- unallowlisted ReactVM rejection
- stale/replayed nonce rejection
- idempotent mitigation no-op behavior
- pause/throttle/max size protection enforcement
- bounded fee and pause configuration
- reactive deduplication and cooldown behavior

## Intent Scenarios Covered
- create/update/cancel lifecycle behavior
- stale nonce callback rejection
- trigger mismatch handling
- expiry and refund path
- partial execution and settlement behavior
- adapter revert path handling

## Recommended Extensions
- adversarial intent triggering under noisy telemetry
- expanded invariants for dual-domain nonce monotonicity
- longer-horizon fuzzing around threshold boundary drift
