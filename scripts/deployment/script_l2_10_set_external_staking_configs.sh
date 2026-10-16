#!/bin/bash

# Sets external staking proxy configs on ExternalStakingDistributorProxy.
#
# The config is a single packed uint256, and it is byte aligned, so it is built here field by field rather
# than hardcoded. Packing it on-chain via wrapStakingConfig() is also correct, but building it here keeps the
# values auditable in the diff and makes the staking access model explicit per proxy.
#
#   byte 27      openAccess       1 if any account may stake into the proxy, 0 if a staking guard governs it
#   bytes 26-7   stakingGuard     staking guard address, or zero when openAccess is 1
#   bytes 6-5    collectorFactor  share relayed to L1 for stOLAS holders, in 1/10000
#   bytes 4-3    protocolFactor   share kept as protocol assets, in 1/10000
#   bytes 2-1    curatingFactor   share paid to the curating agent, in 1/10000
#   byte 0       stakingType      0 = OLAS V1 (reward on the service multisig), 1 = OLAS V2
#
# Staking access must be stated explicitly: exactly one of a non-zero stakingGuard or openAccess=1. A config
# with neither is rejected on-chain, because that ambiguity is what used to turn a guarded proxy into a
# permissionless one silently. A config with both is contradictory and equally rejected.
#
# This script is safe to run BEFORE the ExternalStakingDistributor implementation upgrade: the openAccess bit
# sits above every field the previous implementation reads, so it ignores the bit entirely and behaves exactly
# as it does today. Running it first therefore avoids any window in which an open proxy is closed.

# Check if $1 is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <network>"
  echo "Example: $0 base_mainnet"
  exit 1
fi

red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
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

externalStakingDistributorProxyAddress=$(jq -r ".externalStakingDistributorProxyAddress" $globals)

# Per-network staking proxy configs.
# Each entry: stakingProxy:stakingGuard:collectorFactor:protocolFactor:curatingFactor:stakingType:openAccess
configEntries=()
case "$1" in
  base_mainnet)
    # Every configured Base proxy is listed with its full intended config, including the ones already set, so
    # that a run from any checkout converges on this state instead of reverting part of it. Re-sending an
    # unchanged config is a no-op and is reported as already set below.
    #
    # All of them are guard governed. Open access means any account can take a seat the protocol pays the
    # staking deposit for, while solely owning the created service multisig and being recorded as the seat's
    # curating agent, so it is not granted on a proxy holding protocol capital.
    stakingGuard="0x860ffb692ce3b4f2fd24aee9bcc82357f863f88e"
    configEntries+=("0x0dfafbf570e9e813507aae18aa08dfba0abc5139:$stakingGuard:1000:0:9000:0:0")
    configEntries+=("0x26fa75ef9ccaa60e58260226a71e9d07564c01bf:$stakingGuard:1000:0:9000:0:0")
    configEntries+=("0x51c5f4982b9b0b3c0482678f5847ea6228cc8e54:$stakingGuard:1000:0:9000:0:0")
    configEntries+=("0x66a92cda5b319dcccac6c1cecbb690ca3fb59488:$stakingGuard:1000:0:9000:0:0")
    configEntries+=("0xb14cd66c6c601230ea79fa7cc072e5e0c2f3a756:$stakingGuard:1000:0:9000:0:0")
    configEntries+=("0xbe6e12364b549622395999db0db53f163994d7af:$stakingGuard:1000:0:9000:0:0")
    ;;
  gnosis_mainnet)
    # Guard-governed proxies keep working across the upgrade unchanged, so none are listed by default.
    # Add new proxies here as they are opened, keeping the staking guard non-zero and openAccess at 0.
    ;;
  mode_mainnet)
    # As above: guard-governed, nothing to re-set for the upgrade
    ;;
  *)
    echo "${red}!!! No staking proxy configs defined for $1${reset}"
    exit 1
    ;;
esac

if [ ${#configEntries[@]} == 0 ]; then
  echo "${yellow}No staking proxy configs to set for $1, nothing to do${reset}"
  exit 0
fi

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

# Build the packed configs, validating each one the same way the contract does
stakingProxies=""
stakingConfigs=""
for entry in "${configEntries[@]}"; do
  IFS=':' read -r proxy guard collectorFactor protocolFactor curatingFactor stakingType openAccess <<< "$entry"

  # Exactly one of a staking guard or open access, which is what the contract enforces
  if [ "$guard" == "0x0000000000000000000000000000000000000000" ] && [ "$openAccess" != "1" ]; then
    echo "${red}!!! $proxy has neither a staking guard nor open access${reset}"
    exit 1
  fi
  if [ "$guard" != "0x0000000000000000000000000000000000000000" ] && [ "$openAccess" == "1" ]; then
    echo "${red}!!! $proxy has both a staking guard and open access${reset}"
    exit 1
  fi

  # Reward factors must be non-zero for the collector and must total 100.00%
  if [ "$collectorFactor" == "0" ]; then
    echo "${red}!!! $proxy has a zero collector factor${reset}"
    exit 1
  fi
  total=$((collectorFactor + protocolFactor + curatingFactor))
  if [ "$total" != "10000" ]; then
    echo "${red}!!! $proxy factors total $total, expected 10000${reset}"
    exit 1
  fi

  # Pack field by field: the layout is byte aligned, so this cannot truncate the guard address
  packed=$(printf "%02x%040s%04x%04x%04x%02x" \
    "$openAccess" "$(echo ${guard#0x} | tr 'A-Z' 'a-z')" \
    "$collectorFactor" "$protocolFactor" "$curatingFactor" "$stakingType" | tr ' ' '0')
  config=$(cast to-dec "0x$packed")

  # Show what changes on-chain
  current=$($castCallHeader $externalStakingDistributorProxyAddress "mapStakingProxyConfigs(address)(uint256)" $proxy | awk '{print $1}')
  echo "${green}$proxy${reset}"
  echo "  guard=$guard collector=$collectorFactor protocol=$protocolFactor curating=$curatingFactor type=$stakingType openAccess=$openAccess"
  echo "  current: $current"
  echo "  new:     $config"
  if [ "$current" == "$config" ]; then
    echo "  ${yellow}already set${reset}"
  fi

  stakingProxies="$stakingProxies,$proxy"
  stakingConfigs="$stakingConfigs,$config"
done
stakingProxies="[${stakingProxies:1}]"
stakingConfigs="[${stakingConfigs:1}]"

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

echo "${green}Set Staking Proxy Configs in ExternalStakingDistributorProxy${reset}"
castArgs="$externalStakingDistributorProxyAddress setStakingProxyConfigs(address[],uint256[]) $stakingProxies $stakingConfigs"
echo $castArgs
castCmd="$castSendHeader $castArgs"
result=$($castCmd)
echo "$result" | grep "status"

# Read back what landed, so a silent mismatch cannot pass unnoticed
echo "${green}Verifying stored configs${reset}"
i=0
for entry in "${configEntries[@]}"; do
  IFS=':' read -r proxy _ _ _ _ _ _ <<< "$entry"
  expected=$(echo $stakingConfigs | tr -d '[]' | cut -d',' -f$((i + 1)))
  # Retry the read: load balanced RPCs can serve a replica that has not yet caught up with the transaction,
  # which otherwise reports a correctly stored config as a mismatch
  stored=""
  for attempt in 1 2 3 4 5; do
    stored=$($castCallHeader $externalStakingDistributorProxyAddress "mapStakingProxyConfigs(address)(uint256)" $proxy | awk '{print $1}')
    if [ "$stored" == "$expected" ]; then
      break
    fi
    sleep 3
  done
  if [ "$stored" != "$expected" ]; then
    echo "${red}!!! $proxy stored config is incorrect!${reset}"
    echo "${red}!!! Fetched:  $stored${reset}"
    echo "${red}!!! Expected: $expected${reset}"
  else
    echo "  $proxy OK"
  fi
  i=$((i + 1))
done
