source .env

forge script scripts/testnetDeploy.s.sol:DeployContracts \
  --slow \
  --fork-url $TENDERLY_VIRTUAL_TESTNET_RPC_URL \
  --private-keys $PRIVATE_KEY_1  \
  --private-keys $PRIVATE_KEY_2 \
  --private-keys $PRIVATE_KEY_3  \
  --etherscan-api-key $TENDERLY_ACCESS_TOKEN \
  --broadcast \
  --via-ir