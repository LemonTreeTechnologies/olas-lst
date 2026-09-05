// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Test.sol";

import {LiquidStakingBase} from "./LiquidStakingBase.sol";

import {ExternalStakingDistributor} from "../contracts/l2/ExternalStakingDistributor.sol";
import {StakingTokenV1, StakingBaseV1} from "../contracts/test/StakingTokenV1.sol";
import {StakingActivityChecker} from "@registries/contracts/staking/StakingActivityChecker.sol";
import {IService} from "../contracts/interfaces/IService.sol";

/// @dev MultisigGuard behaviour on service multisigs.
///
/// The guard is a single proxy shared by every service multisig on the chain, and its reentrancy lock lives in
/// that shared storage. `checkAfterExecution` used to take the lock and then return early on an unsuccessful
/// transaction without releasing it, so one failed Safe transaction bricked owner transactions on every service
/// multisig at once. Safe reaches that path whenever `safeTxGas` or `gasPrice` is non-zero, which any service
/// multisig owner can set.
///
/// The guard also did not constrain the staking token balance, so a service multisig owner could move out any
/// OLAS sitting on the Safe through a guard-checked transaction.
contract MultisigGuardTest is LiquidStakingBase {
    uint256 internal constant EXTERNAL_LIVENESS_RATIO = 1e12;

    StakingTokenV1 internal externalStakingProxy;
    address internal curatingAgent;
    address internal agentInstance;
    address internal serviceMultisig;
    uint256 internal serviceId;

    function setUp() public virtual override {
        super.setUp();

        curatingAgent = users[2];
        agentInstance = users[3];

        externalStakingProxy = _deployExternalStakingProxy();

        address[] memory stakingProxies = new address[](1);
        stakingProxies[0] = address(externalStakingProxy);
        uint256[] memory configs = new uint256[](1);
        configs[0] = externalStakingDistributor.wrapStakingConfig(
            address(0), 8000, 1750, 250, ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1, true
        );
        externalStakingDistributor.setStakingProxyConfigs(stakingProxies, configs);

        olas.mint(address(externalStakingDistributor), STAKING_SUPPLY);

        vm.prank(curatingAgent);
        externalStakingDistributor.stake(address(externalStakingProxy), 0, AGENT_ID, DEFAULT_HASH, agentInstance);

        uint256[] memory serviceIds = externalStakingProxy.getServiceIds();
        serviceId = serviceIds[serviceIds.length - 1];
        (, serviceMultisig,,,,,) = IService(address(serviceRegistry)).mapServices(serviceId);
        vm.deal(serviceMultisig, 1 ether);
    }

    /// @dev A failed multisig transaction must not brick the guard.
    ///
    /// Safe only calls checkAfterExecution with success == false when safeTxGas or gasPrice is non-zero, which
    /// the multisig owner controls. The guard is shared, so a single such transaction used to lock every other
    /// service multisig on the chain out of owner transactions permanently.
    function testGuardSurvivesFailedTransaction() public {
        // A call into a contract with no matching function: the inner call fails, but with a non-zero safeTxGas
        // the Safe transaction itself succeeds and the guard sees success == false
        bool executed =
            _execTransaction(address(externalStakingProxy), abi.encodeWithSignature("nonExistent()"), 100000);
        assertTrue(executed, "Safe transaction should have been accepted");

        // The guard must still work for the very same multisig
        assertTrue(_execTransaction(serviceMultisig, "", 0), "guard bricked the originating multisig");

        // And for every other one, since the lock lives in shared guard storage
        address otherMultisig = _stakeAnotherService();
        vm.deal(otherMultisig, 1 ether);
        assertTrue(_execTransactionFrom(otherMultisig, users[5], otherMultisig, "", 0), "guard bricked other multisigs");
    }

    /// @dev The guard rejects an owner transaction that moves the staking token off the service multisig.
    function testOwnerCannotSweepStakingToken() public {
        // Simulate a reward sitting on the service multisig
        uint256 amount = 100 ether;
        olas.mint(serviceMultisig, amount);
        assertEq(olas.balanceOf(serviceMultisig), amount, "multisig was not funded");

        // The owner tries to move it out through a guard-checked transaction
        vm.expectRevert();
        _execTransaction(address(olas), abi.encodeCall(olas.transfer, (agentInstance, amount)), 0);

        assertEq(olas.balanceOf(serviceMultisig), amount, "staking token left the multisig");
        assertEq(olas.balanceOf(agentInstance), 0, "owner received staking token");
    }

    /// @dev Ordinary owner transactions that do not touch the staking token still work, which is what
    ///      keeps liveness going.
    function testOwnerTransactionsStillWork() public {
        assertTrue(_execTransaction(serviceMultisig, "", 0), "plain owner transaction failed");

        // Receiving the staking token is fine, only moving it out is not
        olas.mint(serviceMultisig, 1 ether);
        assertTrue(_execTransaction(serviceMultisig, "", 0), "owner transaction failed with a funded multisig");
    }

    /// @dev Reward distribution goes through the distributor module, which Safe does not route past the guard,
    ///      so the balance constraint cannot block the protocol settling rewards.
    function testModuleDistributionIsUnaffected() public {
        uint256 ts = block.timestamp;
        for (uint256 i = 0; i < 3; ++i) {
            _execTransaction(serviceMultisig, "", 0);
            ts += LIVENESS_PERIOD + 1;
            vm.warp(ts);
            externalStakingProxy.checkpoint();
        }

        address[] memory stakingProxies = new address[](1);
        stakingProxies[0] = address(externalStakingProxy);
        uint256[] memory serviceIds = new uint256[](1);
        serviceIds[0] = serviceId;

        uint256[] memory rewards = externalStakingDistributor.claim(stakingProxies, serviceIds);
        assertGt(rewards[0], 0, "no reward claimed");
        // The module call moved the reward off the multisig despite the guard balance constraint
        assertEq(olas.balanceOf(serviceMultisig), 0, "reward was not distributed off the multisig");
    }

    // Helpers

    function _execTransaction(address to, bytes memory data, uint256 safeTxGas) internal returns (bool) {
        return _execTransactionFrom(serviceMultisig, agentInstance, to, data, safeTxGas);
    }

    /// @dev Executes a Safe transaction signed by the multisig owner.
    function _execTransactionFrom(address multisig, address owner, address to, bytes memory data, uint256 safeTxGas)
        internal
        returns (bool)
    {
        vm.prank(owner);
        (bool success,) = multisig.call(
            abi.encodeWithSignature(
                "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                to,
                uint256(0),
                data,
                uint8(0),
                safeTxGas,
                uint256(0),
                uint256(0),
                address(0),
                address(0),
                abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1))
            )
        );
        return success;
    }

    /// @dev Stakes a second service and returns its multisig.
    function _stakeAnotherService() internal returns (address multisig) {
        vm.prank(users[4]);
        externalStakingDistributor.stake(address(externalStakingProxy), 0, AGENT_ID, DEFAULT_HASH, users[5]);

        uint256[] memory serviceIds = externalStakingProxy.getServiceIds();
        (, multisig,,,,,) = IService(address(serviceRegistry)).mapServices(serviceIds[serviceIds.length - 1]);
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
