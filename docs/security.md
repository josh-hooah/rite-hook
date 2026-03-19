# Security

## Threat Model
Primary adversarial goals:

- forge callback sender
- spoof ReactVM identity
- replay stale mitigation payloads
- induce repeated false-positive mitigations
- execute toxic swaps before mitigation propagates

## Implemented Controls
- Callback sender authentication: `msg.sender == callbackProxy`
- ReactVM allowlist: `reactVMAllowlist[reactVM] == true`
- Replay protection: monotonic nonce checks in executor + hook
- Idempotent handling: stale nonce produces deterministic rejection/no-op
- Reentrancy protection: `nonReentrant` on callback execution path
- Bounded mitigation config: fee/throttle/pause upper limits
- Deterministic arithmetic bounds for risk metrics

## Manipulation Resistance
- Multi-component scoring reduces single-metric manipulation sensitivity.
- Temporal and direction-flip heuristics improve sandwich-pattern sensitivity.
- Cooldown (`mitigationCooldownSeconds`) limits rapid repeated actions.

## False-Positive Resistance
- Component thresholds are configurable in `RiskConfig`.
- High-risk mode can apply fee-only (without pause) when MEV-sensitive pattern is absent.
- Critical mode threshold is separate and higher than high-risk threshold.

## Trust Model
Trusted / configurable components:

- callback proxy address
- ReactVM allowlist entries
- owner/operator risk configuration

External dependencies:

- Reactive callback delivery liveness
- callback proxy correctness on destination chain
- chain RPC integrity for operational tooling

## Residual Risks
- extreme market regimes can still generate false positives or delayed response
- malicious flow can stay below thresholds while causing gradual harm
- operator misconfiguration can over-throttle healthy flow

## Disclosure
Report vulnerabilities via root `SECURITY.md`.
