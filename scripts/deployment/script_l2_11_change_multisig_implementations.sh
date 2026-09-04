#!/bin/bash

# Sets Safe multisig implementation addresses on StakingManagerProxy.
#
# This MUST be run right after upgrading the StakingManager implementation: proxies deployed by an earlier
# implementation have no recoveryModule in storage, and service re-deployment reverts with ZeroAddress until
# this script is run.

# Check if $1 is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <network>"
  echo "Example: $0 gnosis_mainnet"
  exit 1
fi

red=$(tput setaf 1)
green=$(tput setaf 2)
reset=$(tput sgr0)

# Get globals file
globals="$(dirname "$0")/globals_$1.json"
if [ ! -f $globals ]; then
  echo "${red}!!! $globals is not found${reset}"
  exit 0
fi

# Read variables using jq
useLedger=$(jq -r '.useLedger' $globals)
derivationPath=$(jq -r '.derivationPath' $globals)
chainId=$(jq -r '.chainId' $globals)
networkURL=$(jq -r '.networkURL' $globals)

stakingManagerProxyAddress=$(jq -r '.stakingManagerProxyAddress' $globals)
serviceRegistryAddress=$(jq -r '.serviceRegistryAddress' $globals)
gnosisSafeMultisigImplementationAddress=$(jq -r '.gnosisSafeMultisigImplementationAddress' $globals)
recoveryModuleAddress=$(jq -r '.recoveryModuleAddress' $globals)
fallbackHandlerAddress=$(jq -r '.fallbackHandlerAddress' $globals)

# Check for Polygon keys only since on other networks those are not needed
if [ $chainId == 137 ]; then
  API_KEY=$ALCHEMY_API_KEY_MATIC
  if [ "$API_KEY" == "" ]; then
      echo "set ALCHEMY_API_KEY_MATIC env variable"
      exit 0
  fi
elif [ $chainId == 80002 ]; then
    API_KEY=$ALCHEMY_API_KEY_AMOY
    if [ "$API_KEY" == "" ]; then
        echo "set ALCHEMY_API_KEY_AMOY env variable"
        exit 0
    fi
fi

castCallHeader="cast call --rpc-url $networkURL$API_KEY"

# Pre-flight: both implementations must be whitelisted in the service registry, otherwise service deployment
# reverts with UnauthorizedMultisig. changeMultisigImplementations() enforces this on-chain as well.
for implementation in $gnosisSafeMultisigImplementationAddress $recoveryModuleAddress; do
  castArgs="$serviceRegistryAddress mapMultisigs(address)(bool) $implementation"
  result=$($castCallHeader $castArgs)
  if [ "$result" != "true" ]; then
    echo "${red}!!! $implementation is not whitelisted in ServiceRegistry $serviceRegistryAddress${reset}"
    exit 1
  fi
  echo "${green}Whitelisted: $implementation${reset}"
done

# Get deployer based on the ledger flag
if [ "$useLedger" == "true" ]; then
  walletArgs="-l --mnemonic-derivation-path $derivationPath"
  deployer=$(cast wallet address $walletArgs)
else
  echo "Using PRIVATE_KEY: ${PRIVATE_KEY:0:6}..."
  walletArgs="--private-key $PRIVATE_KEY"
  deployer=$(cast wallet address $walletArgs)
fi

castSendHeader="cast send --rpc-url $networkURL$API_KEY $walletArgs"

echo "${green}Change multisig implementations in StakingManagerProxy${reset}"
castArgs="$stakingManagerProxyAddress changeMultisigImplementations(address,address,address) $gnosisSafeMultisigImplementationAddress $recoveryModuleAddress $fallbackHandlerAddress"
echo $castArgs
castCmd="$castSendHeader $castArgs"
result=$($castCmd)
echo "$result" | grep "status"
