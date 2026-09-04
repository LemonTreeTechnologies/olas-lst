// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Test.sol";

import {LiquidStakingBase} from "./LiquidStakingBase.sol";

import {ExternalStakingDistributor} from "../contracts/l2/ExternalStakingDistributor.sol";
import {SafeSetupHelper} from "../contracts/l2/SafeSetupHelper.sol";
import {StakingTokenV1, StakingBaseV1} from "../contracts/test/StakingTokenV1.sol";
import {StakingActivityChecker} from "@registries/contracts/staking/StakingActivityChecker.sol";
import {IService} from "../contracts/interfaces/IService.sol";

interface ISafeView {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function isModuleEnabled(address module) external view returns (bool);
    function nonce() external view returns (uint256);
}

/// @dev Creation of external staking services.
///
/// The create branch used to pre-create a Safe and then register it through GnosisSafeSameAddressMultisig, whose
/// implementation has since been de-whitelisted in the live service registries. Service creation therefore
/// reverted UnauthorizedMultisig on every chain, which fully blocks Base where no services are owned yet.
///
/// Creation now goes through the whitelisted GnosisSafeMultisig, with SafeSetupHelper delegatecall-ed during Safe
/// `setup()` to enable the recovery module, the distributor and the guard, and to set the guard. The service
/// registry creates the multisig owned by the agent instances, so this is the only point at which the protocol
/// can wire it: no protocol contract is ever an owner afterwards.
contract ExternalStakingCreateTest is LiquidStakingBase {
    // Guard storage slot, keccak256("guard_manager.guard.address")
    bytes32 internal constant GUARD_STORAGE_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;

    // Liveness ratio of the external activity checker
    uint256 internal constant EXTERNAL_LIVENESS_RATIO = 1e12;

    StakingTokenV1 internal externalStakingProxy;
    address internal curatingAgent;
    address internal agentInstance;

    function setUp() public virtual override {
        super.setUp();

        curatingAgent = users[2];
        agentInstance = users[3];

        externalStakingProxy = _deployExternalStakingProxy();
        _configureExternalStaking(address(externalStakingProxy), address(0));

        // Fund the distributor so it can cover staking deposits
        olas.mint(address(externalStakingDistributor), STAKING_SUPPLY);
    }

    /// @dev A created service ends up fully wired: correct owner, modules and guard.
    function testCreateServiceWiresMultisig() public {
        uint256 serviceId = _stakeNewService();

        (, address multisig,,,,, uint8 state) = IService(address(serviceRegistry)).mapServices(serviceId);
        assertEq(state, uint8(4), "service is not Deployed");
        assertTrue(multisig != address(0), "no multisig created");

        // The staking proxy verifies the multisig code hash independently, so a successful stake already proves
        // the hash matches; assert it explicitly since it is what makes GnosisSafeMultisig a valid substitute
        assertEq(multisig.codehash, multisigProxyHash, "unexpected multisig proxy hash");

        // Owner is the agent instance, exactly as the previous swapOwner dance produced
        address[] memory owners = ISafeView(multisig).getOwners();
        assertEq(owners.length, 1, "unexpected number of owners");
        assertEq(owners[0], agentInstance, "owner is not the agent instance");
        assertEq(ISafeView(multisig).getThreshold(), 1, "unexpected threshold");

        // The distributor is a module: without it, reward distribution for V1 staking cannot settle
        assertTrue(ISafeView(multisig).isModuleEnabled(address(externalStakingDistributor)), "distributor not module");
        // The guard is both a module and the transaction guard
        assertTrue(ISafeView(multisig).isModuleEnabled(address(multisigGuard)), "guard not module");
        assertEq(
            address(uint160(uint256(vm.load(multisig, GUARD_STORAGE_SLOT)))), address(multisigGuard), "guard not set"
        );
        // The recovery module is a module: without it the service could never be unstaked and re-deployed
        assertTrue(ISafeView(multisig).isModuleEnabled(address(recoveryModule)), "recovery module not module");

        // The guard resolves the multisig to its service Id, otherwise every guarded transaction reverts
        assertEq(externalStakingDistributor.mapMultisigServiceIds(multisig), serviceId, "multisig not linked");
    }

    /// @dev The full lifecycle a created service must support, which is what a missing module would break.
    function testCreatedServiceFullCycle() public {
        uint256 serviceId = _stakeNewService();
        (, address multisig,,,,,) = IService(address(serviceRegistry)).mapServices(serviceId);

        uint256 stakedBefore = externalStakingDistributor.stakedBalance();
        assertEq(stakedBefore, MIN_STAKING_DEPOSIT * 2, "unexpected staked balance");

        // Produce liveness across the pool minimum staking duration, so the service stays active and can be
        // unstaked later. Each round is one epoch of real activity on the service multisig.
        // Time is tracked explicitly rather than via skip() or block.timestamp: in this foundry version the
        // test frame does not observe previous warps, so both would keep warping to the same timestamp.
        uint256 ts = block.timestamp;
        for (uint256 i = 0; i < 3; ++i) {
            _produceActivity(multisig);
            ts += LIVENESS_PERIOD + 1;
            vm.warp(ts);
            externalStakingProxy.checkpoint();
        }

        address[] memory stakingProxies = new address[](1);
        stakingProxies[0] = address(externalStakingProxy);
        uint256[] memory serviceIds = new uint256[](1);
        serviceIds[0] = serviceId;

        // Claiming settles rewards through the distributor module on the service multisig, which only works
        // because SafeSetupHelper enabled it during Safe creation
        uint256 curatingBefore = olas.balanceOf(curatingAgent);
        uint256[] memory rewards = externalStakingDistributor.claim(stakingProxies, serviceIds);
        assertGt(rewards[0], 0, "no reward claimed");
        assertGt(olas.balanceOf(curatingAgent), curatingBefore, "curating agent was not paid");
        // Nothing is left standing on the service multisig after distribution
        assertEq(olas.balanceOf(multisig), 0, "reward left on multisig");

        // Unstake as the owner: this terminates, unbonds and recovers multisig access through the recovery
        // module. While the service is staked and rewards remain, only the owner and managing agents may unstake.
        externalStakingDistributor.unstakeAndWithdraw(address(externalStakingProxy), serviceId, UNSTAKE_OPERATION);

        (,,,,,, uint8 state) = IService(address(serviceRegistry)).mapServices(serviceId);
        assertEq(state, uint8(1), "service is not in PreRegistration after unstake");
        assertEq(externalStakingDistributor.stakedBalance(), 0, "staked balance not released");

        // After recoverAccess the distributor owns the multisig, which is what lets it be re-deployed
        address[] memory owners = ISafeView(multisig).getOwners();
        assertEq(owners.length, 1, "unexpected number of owners after unstake");
        assertEq(owners[0], address(externalStakingDistributor), "distributor did not recover multisig access");

        // Re-stake the very same service: the re-deploy branch hands ownership back to the agent instance
        vm.prank(curatingAgent);
        externalStakingDistributor.stake(
            address(externalStakingProxy), serviceId, AGENT_ID, DEFAULT_HASH, agentInstance
        );

        (, address multisigAfter,,,,, uint8 stateAfter) = IService(address(serviceRegistry)).mapServices(serviceId);
        assertEq(multisigAfter, multisig, "multisig changed across re-deployment");
        assertEq(stateAfter, uint8(4), "service is not Deployed after re-deployment");
        owners = ISafeView(multisig).getOwners();
        assertEq(owners[0], agentInstance, "owner is not the agent instance after re-deployment");
        assertTrue(ISafeView(multisig).isModuleEnabled(address(externalStakingDistributor)), "distributor not module");
    }

    /// @dev Creation reverts loudly while the Safe multisig implementation or setup helper is unset, which is
    ///      the state of a proxy upgraded from an implementation that had no such slots.
    function testCreateRevertsWithoutImplementations() public {
        // Wipe both appended slots to emulate a freshly upgraded proxy
        vm.store(address(externalStakingDistributor), bytes32(uint256(13)), bytes32(0));
        vm.store(address(externalStakingDistributor), bytes32(uint256(14)), bytes32(0));
        assertEq(externalStakingDistributor.safeMultisig(), address(0), "safeMultisig was not wiped");
        assertEq(externalStakingDistributor.safeSetupHelper(), address(0), "safeSetupHelper was not wiped");

        vm.prank(curatingAgent);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        externalStakingDistributor.stake(address(externalStakingProxy), 0, AGENT_ID, DEFAULT_HASH, agentInstance);

        // Setting them restores creation
        externalStakingDistributor.changeMultisigImplementations(address(gnosisSafeMultisig), address(safeSetupHelper));
        _stakeNewService();
    }

    /// @dev Multisig implementations are owner-settable and must be whitelisted in the service registry.
    function testChangeMultisigImplementations() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSignature("OwnerOnly(address,address)", agent, address(this)));
        externalStakingDistributor.changeMultisigImplementations(address(gnosisSafeMultisig), address(safeSetupHelper));

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        externalStakingDistributor.changeMultisigImplementations(address(0), address(safeSetupHelper));
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        externalStakingDistributor.changeMultisigImplementations(address(gnosisSafeMultisig), address(0));

        // The de-whitelisted implementation that caused the blocker is rejected
        vm.expectRevert(
            abi.encodeWithSignature("UnauthorizedMultisig(address)", address(gnosisSafeSameAddressMultisig))
        );
        externalStakingDistributor.changeMultisigImplementations(
            address(gnosisSafeSameAddressMultisig), address(safeSetupHelper)
        );

        SafeSetupHelper newHelper = new SafeSetupHelper();
        externalStakingDistributor.changeMultisigImplementations(address(gnosisSafeMultisig), address(newHelper));
        assertEq(externalStakingDistributor.safeMultisig(), address(gnosisSafeMultisig));
        assertEq(externalStakingDistributor.safeSetupHelper(), address(newHelper));
    }

    /// @dev The setup helper is only usable as a Safe setup delegatecall target.
    function testSetupHelperIsDelegatecallOnly() public {
        address[] memory modules = new address[](1);
        modules[0] = address(externalStakingDistributor);

        vm.expectRevert(abi.encodeWithSignature("DelegatecallOnly()"));
        safeSetupHelper.setup(modules, address(multisigGuard));
    }

    /// @dev Creation reverts if no multisig guard is configured, rather than producing an unguarded multisig.
    function testCreateRevertsWithoutGuard() public {
        // Guard occupies slot 3: owner(0), stakedBalance(1), l2StakingProcessor(2), guard(3)
        vm.store(address(externalStakingDistributor), bytes32(uint256(3)), bytes32(0));
        assertEq(externalStakingDistributor.guard(), address(0), "guard was not wiped");

        vm.prank(curatingAgent);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        externalStakingDistributor.stake(address(externalStakingProxy), 0, AGENT_ID, DEFAULT_HASH, agentInstance);
    }

    // Helpers

    /// @dev Deploys an external staking proxy of the kind third parties run, with its own activity checker.
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

        // Fund the external staking pool with rewards
        olas.mint(address(this), STAKING_SUPPLY);
        olas.approve(proxy, STAKING_SUPPLY);
        StakingTokenV1(proxy).deposit(STAKING_SUPPLY);

        return StakingTokenV1(proxy);
    }

    /// @dev Whitelists a staking proxy on the distributor with a V1 reward split.
    function _configureExternalStaking(address stakingProxy, address stakingGuard) internal {
        address[] memory stakingProxies = new address[](1);
        stakingProxies[0] = stakingProxy;
        uint256[] memory configs = new uint256[](1);
        // 80% to the collector, 17.5% to the protocol, 2.5% to the curating agent, staking type V1
        configs[0] = externalStakingDistributor.wrapStakingConfig(
            stakingGuard,
            8000,
            1750,
            250,
            ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1,
            stakingGuard == address(0)
        );
        externalStakingDistributor.setStakingProxyConfigs(stakingProxies, configs);
    }

    /// @dev Stakes a brand new service and returns its Id.
    function _stakeNewService() internal returns (uint256 serviceId) {
        vm.prank(curatingAgent);
        externalStakingDistributor.stake(address(externalStakingProxy), 0, AGENT_ID, DEFAULT_HASH, agentInstance);

        uint256[] memory serviceIds = externalStakingProxy.getServiceIds();
        serviceId = serviceIds[serviceIds.length - 1];
    }

    /// @dev Produces multisig activity so the service passes the liveness check.
    function _produceActivity(address multisig) internal {
        // The activity checker reads the multisig nonce, which any owner transaction increments
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
}
