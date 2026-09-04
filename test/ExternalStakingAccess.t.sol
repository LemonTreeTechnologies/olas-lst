// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Test.sol";

import {LiquidStakingBase} from "./LiquidStakingBase.sol";

import {ExternalStakingDistributor} from "../contracts/l2/ExternalStakingDistributor.sol";
import {StakingTokenV1, StakingBaseV1} from "../contracts/test/StakingTokenV1.sol";
import {StakingActivityChecker} from "@registries/contracts/staking/StakingActivityChecker.sol";

/// @dev Staking access on external staking proxies.
///
/// A zero staking guard used to mean two different things: "deliberately permissionless" and "nobody configured
/// a guard yet". `stake()` defaulted access to true and only tightened it when a guard was present, so an
/// incomplete config batch silently turned an allowlisted proxy into a permissionless one.
///
/// Both live models stay supported and are now stated explicitly in the config. Gnosis and Mode run every proxy
/// behind a staking guard allowlist; Base runs three proxies open to any account, where the curating agent takes
/// 85% for running the operation. Access is deny by default, and setStakingProxyConfigs rejects a config that
/// states neither or both.
contract ExternalStakingAccessTest is LiquidStakingBase {
    uint256 internal constant EXTERNAL_LIVENESS_RATIO = 1e12;

    StakingTokenV1 internal guardedProxy;
    StakingTokenV1 internal openProxy;

    address internal stakingGuard;
    address internal curatingAgent;
    address internal outsider;
    address internal agentInstance;

    function setUp() public virtual override {
        super.setUp();

        stakingGuard = users[2];
        curatingAgent = users[3];
        outsider = users[4];
        agentInstance = users[5];

        guardedProxy = _deployExternalStakingProxy();
        openProxy = _deployExternalStakingProxy();

        _setConfig(address(guardedProxy), stakingGuard, false);
        _setConfig(address(openProxy), address(0), true);

        // The staking guard allowlists its curating agent for its own proxy
        address[] memory curatingAgents = new address[](1);
        curatingAgents[0] = curatingAgent;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;
        vm.prank(stakingGuard);
        externalStakingDistributor.setCuratingAgents(address(guardedProxy), curatingAgents, statuses);

        olas.mint(address(externalStakingDistributor), STAKING_SUPPLY);
    }

    /// @dev An open proxy stays permissionless, which is the live Base model.
    function testOpenProxyIsPermissionless() public {
        (address guard,,,,, bool openAccess) = externalStakingDistributor.unwrapStakingConfig(
            externalStakingDistributor.mapStakingProxyConfigs(address(openProxy))
        );
        assertEq(guard, address(0), "open proxy must carry no staking guard");
        assertTrue(openAccess, "open proxy must be flagged open");

        // An account with no relationship to the protocol can stake and becomes the service curating agent
        vm.prank(outsider);
        externalStakingDistributor.stake(address(openProxy), 0, AGENT_ID, DEFAULT_HASH, agentInstance);

        uint256[] memory serviceIds = openProxy.getServiceIds();
        assertEq(serviceIds.length, 1, "service was not staked");
        assertEq(
            externalStakingDistributor.mapServiceIdCuratingAgents(serviceIds[0]),
            outsider,
            "staker did not become the curating agent"
        );
    }

    /// @dev A guarded proxy only accepts its allowlisted curating agents.
    function testGuardedProxyRequiresAllowlist() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedAccount(address)", outsider));
        externalStakingDistributor.stake(address(guardedProxy), 0, AGENT_ID, DEFAULT_HASH, agentInstance);

        vm.prank(curatingAgent);
        externalStakingDistributor.stake(address(guardedProxy), 0, AGENT_ID, DEFAULT_HASH, agentInstance);
        assertEq(guardedProxy.getServiceIds().length, 1, "allowlisted agent could not stake");
    }

    /// @dev The owner may always stake, regardless of the access model.
    function testOwnerAlwaysStakes() public {
        externalStakingDistributor.stake(address(guardedProxy), 0, AGENT_ID, DEFAULT_HASH, agentInstance);
        assertEq(guardedProxy.getServiceIds().length, 1, "owner could not stake into a guarded proxy");
    }

    /// @dev A guarded proxy whose config carries no explicit access is rejected at config time.
    ///
    /// This is the residue of the original finding: such a config used to be accepted and made the proxy
    /// permissionless, so a typo in a config batch opened it up with nothing reverting.
    function testAmbiguousConfigIsRejected() public {
        // Neither a staking guard nor the open flag
        uint256 config = externalStakingDistributor.wrapStakingConfig(
            address(0), 8000, 1750, 250, ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1, false
        );
        address[] memory stakingProxies = new address[](1);
        stakingProxies[0] = address(guardedProxy);
        uint256[] memory configs = new uint256[](1);
        configs[0] = config;

        vm.expectRevert(
            abi.encodeWithSignature(
                "WrongStakingAccess(address,address,bool)", address(guardedProxy), address(0), false
            )
        );
        externalStakingDistributor.setStakingProxyConfigs(stakingProxies, configs);

        // Both a staking guard and the open flag is contradictory and equally rejected
        configs[0] = externalStakingDistributor.wrapStakingConfig(
            stakingGuard, 8000, 1750, 250, ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1, true
        );
        vm.expectRevert(
            abi.encodeWithSignature(
                "WrongStakingAccess(address,address,bool)", address(guardedProxy), stakingGuard, true
            )
        );
        externalStakingDistributor.setStakingProxyConfigs(stakingProxies, configs);
    }

    /// @dev A config written by the previous implementation carries no open flag, so access closes rather
    ///      than staying open until the owner re-states it. This is the migration behaviour on Base.
    function testLegacyOpenConfigFailsClosed() public {
        // Exactly what the previous implementation stored for the live Base proxies: zero guard, no flag
        uint256 legacyConfig = uint256(uint8(0)) | (uint256(8500) << 8) | (uint256(1000) << 24) | (uint256(500) << 40);
        vm.store(
            address(externalStakingDistributor),
            keccak256(abi.encode(address(openProxy), uint256(6))),
            bytes32(legacyConfig)
        );
        assertEq(
            externalStakingDistributor.mapStakingProxyConfigs(address(openProxy)), legacyConfig, "config not written"
        );

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedAccount(address)", outsider));
        externalStakingDistributor.stake(address(openProxy), 0, AGENT_ID, DEFAULT_HASH, agentInstance);

        // Re-stating the config with the explicit flag restores the open model
        _setConfig(address(openProxy), address(0), true);
        vm.prank(outsider);
        externalStakingDistributor.stake(address(openProxy), 0, AGENT_ID, DEFAULT_HASH, agentInstance);
        assertEq(openProxy.getServiceIds().length, 1, "open access was not restored");
    }

    /// @dev Config packing round-trips, and the open flag does not disturb the other fields.
    ///
    /// The staking guard assertion also covers a packing bug: `uint160(stakingGuard) << 56` shifts within
    /// uint160 and silently truncated the top 56 bits of the address, so any config built through
    /// wrapStakingConfig carried a corrupted staking guard that no account could ever match.
    function testConfigRoundTrip() public {
        uint256 config = externalStakingDistributor.wrapStakingConfig(
            stakingGuard, 4500, 500, 5000, ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V2, false
        );
        (
            address guard,
            uint256 collectorRewardFactor,
            uint256 protocolRewardFactor,
            uint256 curatingAgentRewardFactor,
            ExternalStakingDistributor.StakingType stakingType,
            bool openAccess
        ) = externalStakingDistributor.unwrapStakingConfig(config);

        assertEq(guard, stakingGuard);
        assertEq(collectorRewardFactor, 4500);
        assertEq(protocolRewardFactor, 500);
        assertEq(curatingAgentRewardFactor, 5000);
        assertTrue(stakingType == ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V2);
        assertFalse(openAccess);

        // The same config with the open flag differs only in the flag bit
        uint256 openConfig = externalStakingDistributor.wrapStakingConfig(
            address(0), 500, 1000, 8500, ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1, true
        );
        (guard, collectorRewardFactor, protocolRewardFactor, curatingAgentRewardFactor,, openAccess) =
            externalStakingDistributor.unwrapStakingConfig(openConfig);
        assertEq(guard, address(0));
        assertEq(collectorRewardFactor, 500);
        assertEq(protocolRewardFactor, 1000);
        assertEq(curatingAgentRewardFactor, 8500);
        assertTrue(openAccess);
        assertEq(
            openConfig & externalStakingDistributor.OPEN_ACCESS_MASK(), externalStakingDistributor.OPEN_ACCESS_MASK()
        );
    }

    // Helpers

    function _setConfig(address stakingProxy, address guard, bool openAccess) internal {
        address[] memory stakingProxies = new address[](1);
        stakingProxies[0] = stakingProxy;
        uint256[] memory configs = new uint256[](1);
        configs[0] = externalStakingDistributor.wrapStakingConfig(
            guard, 8000, 1750, 250, ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1, openAccess
        );
        externalStakingDistributor.setStakingProxyConfigs(stakingProxies, configs);
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
