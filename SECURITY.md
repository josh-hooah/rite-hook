# Security Policy

## Scope
This repository includes onchain components (`contracts/`, `reactive/`) and offchain UI/docs tooling.

## Supported Security Controls
- Callback sender and ReactVM allowlist checks.
- Replay protection via intent nonce.
- Idempotent callback execution semantics.
- Reentrancy guard on callback execution path.
- Strict `onlyPoolManager` hook entrypoints.

## Reporting a Vulnerability
Please report vulnerabilities privately to the maintainers before public disclosure.
Include:
- Affected component/file
- Reproduction steps
- Impact and exploit preconditions
- Suggested remediation

## Disclosure Expectations
- Do not publish exploit details before coordinated remediation.
- Provide enough detail for deterministic reproduction.

## Not in Scope
- Test-only mocks and simulation harnesses that are explicitly non-production.
