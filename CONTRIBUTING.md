# Contributing

## Setup
1. Clone repository.
2. Run bootstrap:
```bash
./scripts/bootstrap.sh
```

## Local Checks
```bash
cd contracts && forge build && forge test
cd ../frontend && pnpm i && pnpm build
cd ../shared && pnpm i && pnpm build
```

## Coding Standards
- Keep hook logic minimal and deterministic.
- Preserve callback signature first arg: `address reactVM`.
- Prefer explicit auth checks over implicit assumptions.
- Update docs in `/docs` and `spec.md` for architectural changes.

## PR Expectations
- Include tests for behavior changes.
- Include threat/assumption notes if touching callback/auth logic.
- Keep commit messages clear (`feat:`, `fix:`, `test:`, `docs:`, `chore:`, etc.).
