-include .env

# deps
update:; forge update
build  :; forge build
size  :; forge build --sizes

# storage inspection
inspect :; forge inspect ${contract} storageLayout

# format
fmt :; forge fmt

# specify which fork to use. set this in our .env
# if we want to test multiple forks in one go, remove this as an argument below
FORK_URL := ${ETH_RPC_URL} # BASE_RPC_URL, ETH_RPC_URL, ARBITRUM_RPC_URL

# if we want to run only matching tests, set that here
test := test_

# local tests without fork
test  :; FOUNDRY_PROFILE=test forge test -vv --fork-url ${FORK_URL}
trace  :; FOUNDRY_PROFILE=test forge test -vvv --fork-url ${FORK_URL}
gas  :; FOUNDRY_PROFILE=test forge test --fork-url ${FORK_URL} --gas-report
test-contract  :; FOUNDRY_PROFILE=test forge test -vv --match-contract $(contract) --fork-url ${FORK_URL}
test-contract-gas  :; FOUNDRY_PROFILE=test forge test --gas-report --match-contract ${contract} --fork-url ${FORK_URL}
trace-contract  :; FOUNDRY_PROFILE=test forge test -vvv --match-contract $(contract) --fork-url ${FORK_URL}
test-test  :; FOUNDRY_PROFILE=test forge test -vv --match-test $(test) --fork-url ${FORK_URL}
test-test-trace  :; FOUNDRY_PROFILE=test forge test -vvv --match-test $(test) --fork-url ${FORK_URL}
trace-test  :; FOUNDRY_PROFILE=test forge test -vvvvv --match-test $(test) --fork-url ${FORK_URL}
snapshot :; forge snapshot -vv --fork-url ${FORK_URL}
snapshot-diff :; forge snapshot --diff -vv --fork-url ${FORK_URL}
trace-setup  :; FOUNDRY_PROFILE=test forge test -vvvv --fork-url ${FORK_URL}
trace-max  :; FOUNDRY_PROFILE=test forge test -vvvvv --fork-url ${FORK_URL}
coverage :; forge coverage --fork-url ${FORK_URL}
coverage-report :; forge coverage --report lcov --fork-url ${FORK_URL}
coverage-debug :; forge coverage --report debug --fork-url ${FORK_URL}

coverage-html:
	@echo "Running coverage..."
	forge coverage --report lcov --fork-url ${FORK_URL}
	@if [ "`uname`" = "Darwin" ]; then \
		lcov --ignore-errors inconsistent --remove lcov.info 'src/test/**' --output-file lcov.info; \
		genhtml --ignore-errors inconsistent -o coverage-report lcov.info; \
	else \
		lcov --remove lcov.info 'src/test/**' --output-file lcov.info; \
		genhtml -o coverage-report lcov.info; \
	fi
	@echo "Coverage report generated at coverage-report/index.html"

clean  :; forge clean
