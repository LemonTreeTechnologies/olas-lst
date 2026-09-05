// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Test.sol";

import {LiquidStakingBase} from "./LiquidStakingBase.sol";

import {Collector} from "../contracts/l2/Collector.sol";
import {ExternalStakingDistributor} from "../contracts/l2/ExternalStakingDistributor.sol";
import {StakingTokenV1, StakingBaseV1} from "../contracts/test/StakingTokenV1.sol";
import {StakingActivityChecker} from "@registries/contracts/staking/StakingActivityChecker.sol";
import {IService} from "../contracts/interfaces/IService.sol";

/// @dev External staking reward split.
///
/// `_distributeRewards` already splits an external reward into collector, protocol and curating agent shares per
/// the staking proxy config. Sending the collector share to the shared REWARD bucket meant
/// `Collector.relayTokens` applied its own `protocolFactor` to it a second time, so the share reaching stOLAS
/// holders was lower than the configured split implies. Internal and external rewards share one bucket and one
/// global factor, so there was no way to exempt one from the other.
///
/// External rewards now use a bucket of their own, EXTERNAL_REWARD, whose Collector receiver is the same L1
/// Distributor. `relayTokens` applies the protocol factor to REWARD only, so the configured split is what the
/// L1 Distributor actually receives.
contract ExternalStakingRewardSplitTest is LiquidStakingBase {
    uint256 internal constant EXTERNAL_LIVENESS_RATIO = 1e12;

    // 80% collector, 17.5% protocol, 2.5% curating agent
    uint256 internal constant COLLECTOR_FACTOR = 8000;
    uint256 internal constant PROTOCOL_FACTOR_CONFIG = 1750;
    uint256 internal constant CURATING_FACTOR = 250;

    // A deliberately non-zero Collector protocol factor: 10%
    uint256 internal constant COLLECTOR_PROTOCOL_FACTOR = 1000;

    StakingTokenV1 internal externalStakingProxy;
    address internal curatingAgent;
    address internal agentInstance;

    function setUp() public virtual override {
        super.setUp();

        curatingAgent = users[2];
        agentInstance = users[3];

        externalStakingProxy = _deployExternalStakingProxy();

        address[] memory stakingProxies = new address[](1);
        stakingProxies[0] = address(externalStakingProxy);
        uint256[] memory configs = new uint256[](1);
        configs[0] = externalStakingDistributor.wrapStakingConfig(
            address(0),
            COLLECTOR_FACTOR,
            PROTOCOL_FACTOR_CONFIG,
            CURATING_FACTOR,
            ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1,
            true
        );
        externalStakingDistributor.setStakingProxyConfigs(stakingProxies, configs);

        // The Collector protocol factor is zero on every live chain today, so the double cut is latent rather
        // than active. Set it here so the test fails if external rewards ever route through the REWARD bucket.
        collector.changeProtocolFactor(COLLECTOR_PROTOCOL_FACTOR);
        assertEq(collector.protocolFactor(), COLLECTOR_PROTOCOL_FACTOR, "protocol factor not set");

        olas.mint(address(externalStakingDistributor), STAKING_SUPPLY);
    }

    /// @dev An external reward is split exactly as configured, and the Collector protocol factor does not
    ///      take a second cut out of the stOLAS holder share.
    function testExternalRewardIsNotTaxedTwice() public {
        uint256 reward = _stakeAndAccrueReward();

        uint256 expectedCollector = (reward * COLLECTOR_FACTOR) / externalStakingDistributor.MAX_REWARD_FACTOR();
        uint256 expectedProtocol = (reward * PROTOCOL_FACTOR_CONFIG) / externalStakingDistributor.MAX_REWARD_FACTOR();
        uint256 expectedCurating = reward - expectedCollector - expectedProtocol;

        uint256 curatingBefore = olas.balanceOf(curatingAgent);
        uint256 protocolBefore = collector.protocolBalance();

        address[] memory stakingProxies = new address[](1);
        stakingProxies[0] = address(externalStakingProxy);
        uint256[] memory serviceIds = new uint256[](1);
        serviceIds[0] = _serviceId();
        externalStakingDistributor.claim(stakingProxies, serviceIds);

        // The curating agent and the protocol get exactly their configured shares
        assertEq(olas.balanceOf(curatingAgent) - curatingBefore, expectedCurating, "curating agent share is wrong");
        assertEq(collector.protocolBalance() - protocolBefore, expectedProtocol, "protocol share is wrong");

        // The collector share lands in the external bucket, untouched, and the shared REWARD bucket is empty
        (uint256 externalBalance,) = collector.mapOperationReceiverBalances(EXTERNAL_REWARD_OPERATION);
        (uint256 rewardBalance,) = collector.mapOperationReceiverBalances(REWARD_OPERATION);
        assertEq(externalBalance, expectedCollector, "collector share is wrong");
        assertEq(rewardBalance, 0, "external reward must not touch the shared REWARD bucket");

        // Relaying takes no further cut, so the full collector share reaches the L1 Distributor
        uint256 distributorBefore = olas.balanceOf(address(distributor));
        uint256 protocolBeforeRelay = collector.protocolBalance();
        collector.relayTokens(EXTERNAL_REWARD_OPERATION, BRIDGE_PAYLOAD);

        assertEq(
            olas.balanceOf(address(distributor)) - distributorBefore,
            expectedCollector,
            "L1 Distributor did not receive the full collector share"
        );
        assertEq(collector.protocolBalance(), protocolBeforeRelay, "protocol took a second cut on relay");

        // Conservation: every wei of the reward is accounted for
        assertEq(expectedCollector + expectedProtocol + expectedCurating, reward, "reward split does not conserve");
    }

    /// @dev Internal staking rewards keep paying the Collector protocol factor, which is the intended model
    ///      and the behaviour this change must not alter.
    function testInternalRewardStillPaysProtocolFactor() public {
        // Fund the shared REWARD bucket directly, as the internal staking path does
        uint256 amount = 100 ether;
        olas.mint(address(this), amount);
        olas.approve(address(collector), amount);
        collector.topUpBalance(amount, REWARD_OPERATION);

        uint256 expectedProtocolCut = (amount * COLLECTOR_PROTOCOL_FACTOR) / collector.MAX_PROTOCOL_FACTOR();
        uint256 protocolBefore = collector.protocolBalance();
        uint256 distributorBefore = olas.balanceOf(address(distributor));

        collector.relayTokens(REWARD_OPERATION, BRIDGE_PAYLOAD);

        assertEq(collector.protocolBalance() - protocolBefore, expectedProtocolCut, "protocol cut is wrong");
        assertEq(
            olas.balanceOf(address(distributor)) - distributorBefore,
            amount - expectedProtocolCut,
            "L1 Distributor received the wrong amount"
        );
    }

    /// @dev Both buckets relay to the same L1 receiver, so the split is a routing detail and not a
    ///      change in where external rewards end up.
    function testBothRewardBucketsShareTheL1Receiver() public {
        (, address rewardReceiver) = collector.mapOperationReceiverBalances(REWARD_OPERATION);
        (, address externalReceiver) = collector.mapOperationReceiverBalances(EXTERNAL_REWARD_OPERATION);
        assertEq(externalReceiver, rewardReceiver, "reward buckets must share the L1 receiver");
        assertEq(externalReceiver, address(distributor), "external rewards must reach the L1 Distributor");
    }

    // Helpers

    /// @dev Stakes a service, produces liveness and returns the accrued reward.
    function _stakeAndAccrueReward() internal returns (uint256) {
        vm.prank(curatingAgent);
        externalStakingDistributor.stake(address(externalStakingProxy), 0, AGENT_ID, DEFAULT_HASH, agentInstance);

        (, address multisig,,,,,) = IService(address(serviceRegistry)).mapServices(_serviceId());

        // Time is tracked explicitly: under viaIR the optimizer hoists TIMESTAMP out of a loop, so skip() and
        // block.timestamp-relative warps do not accumulate
        uint256 ts = block.timestamp;
        _produceActivity(multisig);
        ts += LIVENESS_PERIOD + 1;
        vm.warp(ts);
        externalStakingProxy.checkpoint();

        uint256 reward = externalStakingProxy.calculateStakingReward(_serviceId());
        assertGt(reward, 0, "no reward accrued");
        return reward;
    }

    function _serviceId() internal view returns (uint256) {
        uint256[] memory serviceIds = externalStakingProxy.getServiceIds();
        return serviceIds[serviceIds.length - 1];
    }

    function _produceActivity(address multisig) internal {
        vm.deal(multisig, 1 ether);
        vm.prank(agentInstance);
        (bool success,) = multisig.call(
            abi.encodeWithSignature(
                "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                multisig,
                uint256(0),
                bytes(""),
                uint8(0),
                uint256(0),
                uint256(0),
                uint256(0),
                address(0),
                address(0),
                abi.encodePacked(bytes32(uint256(uint160(agentInstance))), bytes32(0), uint8(1))
            )
        );
        assertTrue(success, "activity transaction failed");
    }

    function _deployExternalStakingProxy() internal returns (StakingTokenV1) {
        StakingActivityChecker externalActivityChecker = new StakingActivityChecker(EXTERNAL_LIVENESS_RATIO);
        StakingTokenV1 implementation = new StakingTokenV1();

        address[] memory implementations = new address[](1);
        implementations[0] = address(implementation);
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;
        stakingVerifier.setImplementationsStatuses(implementations, statuses, true);

        uint256[] memory externalAgentIds = new uint256[](1);
        externalAgentIds[0] = AGENT_ID;

        StakingBaseV1.StakingParams memory params = StakingBaseV1.StakingParams({
            metadataHash: DEFAULT_HASH,
            maxNumServices: 3,
            rewardsPerSecond: REWARDS_PER_SECOND,
            minStakingDeposit: MIN_STAKING_DEPOSIT,
            minNumStakingPeriods: 3,
            maxNumInactivityPeriods: 3,
            livenessPeriod: LIVENESS_PERIOD,
            timeForEmissions: TIME_FOR_EMISSIONS,
            numAgentInstances: 1,
            agentIds: externalAgentIds,
            threshold: 0,
            configHash: bytes32(0),
            proxyHash: multisigProxyHash,
            serviceRegistry: address(serviceRegistry),
            activityChecker: address(externalActivityChecker)
        });

        bytes memory initPayload = abi.encodeWithSelector(
            implementation.initialize.selector, params, address(serviceRegistryTokenUtility), address(olas)
        );
        address proxy = stakingFactory.createStakingInstance(address(implementation), initPayload);

        olas.mint(address(this), STAKING_SUPPLY);
        olas.approve(proxy, STAKING_SUPPLY);
        StakingTokenV1(proxy).deposit(STAKING_SUPPLY);

        return StakingTokenV1(proxy);
    }
}
