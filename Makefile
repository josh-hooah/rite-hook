.PHONY: bootstrap build contracts-build contracts-test coverage frontend-build deploy-local deploy-sepolia deploy-reactive demo-local demo-sepolia pin-check commit-check clean-tree

bootstrap:
	./scripts/bootstrap.sh

build: contracts-build frontend-build

contracts-build:
	cd contracts && forge build

contracts-test:
	cd contracts && forge test

coverage:
	cd contracts && forge coverage --report lcov --no-match-path 'test/invariant/*'
	./scripts/check_coverage.sh contracts/lcov.info

frontend-build:
	cd frontend && pnpm install && pnpm build

deploy-local:
	cd contracts && forge script script/Deploy.s.sol --rpc-url $${LOCAL_RPC:-http://127.0.0.1:8545} --private-key $$DEPLOYER_PRIVATE_KEY --broadcast

deploy-sepolia:
	cd contracts && forge script script/Deploy.s.sol --rpc-url $$SEPOLIA_RPC --private-key $$DEPLOYER_PRIVATE_KEY --broadcast

deploy-reactive:
	cd reactive && ./scripts/deploy.sh

demo-local:
	./scripts/demo-local.sh

demo-sepolia:
	./scripts/demo-sepolia.sh

pin-check:
	./scripts/verify_uniswap_pin.sh

commit-check:
	./scripts/verify_commits.sh

clean-tree:
	./scripts/check_clean_tree.sh
