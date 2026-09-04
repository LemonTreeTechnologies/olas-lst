// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Test.sol";

import {LiquidStakingBase} from "./LiquidStakingBase.sol";

import {StakingManager} from "../contracts/l2/StakingManager.sol";
import {Proxy} from "../contracts/Proxy.sol";
import {IService} from "../contracts/interfaces/IService.sol";

/// @dev Re-deployment of an already created service.
///
/// `_deployAndStake` used to re-deploy a service through GnosisSafeSameAddressMultisig, whose implementation has
/// since been de-whitelisted in the live service registries on every chain the protocol runs on. Any re-stake of
/// a previously unstaked service therefore reverted with UnauthorizedMultisig, permanently stranding the service.
///
/// Re-deployment now goes through RecoveryModule, which is whitelisted. When multisig owners already match the
/// registered agent instances - always the case here, since the owner is the service ActivityModule - it performs
/// same-address verification only and returns the very same multisig, needing no module access on it.
contract StakingManagerRedeployTest is LiquidStakingBase {
    bytes32 internal constant STAKE_OPERATION = keccak256("STAKE");

    /// @dev Reproduces the live registry state: the same address multisig implementation is de-whitelisted on
    ///      Gnosis, Base and Mode, so nothing in the staking cycle may depend on it.
    function setUp() public virtual override {
        super.setUp();
        serviceRegistry.changeMultisigPermission(address(gnosisSafeSameAddressMultisig), false);
    }

    /// @dev Stakes a given OLAS amount through the L2 staking processor.
    function _stakeViaProcessor(uint256 amount) internal {
        address processor = stakingManager.l2StakingProcessor();

        olas.mint(processor, amount);
        vm.prank(processor);
        olas.approve(address(stakingManager), amount);

        vm.prank(processor);
        stakingManager.stake(address(stakingTokenInstance), amount, STAKE_OPERATION);
    }

    /// @dev Unstakes a given OLAS amount through the L2 staking processor.
    function _unstakeViaProcessor(uint256 amount) internal {
        vm.prank(stakingManager.l2StakingProcessor());
        stakingManager.unstake(address(stakingTokenInstance), amount, UNSTAKE_OPERATION);
    }

    /// @dev Gets the single service Id currently tracked for the staking proxy.
    function _firstServiceId() internal view returns (uint256) {
        return stakingManager.mapStakedServiceIds(address(stakingTokenInstance), 1);
    }

    /// @dev A service unstaked and re-staked keeps its multisig, and ends up staked again.
    function testUnstakeAndReDeployPreservesMultisig() public {
        // Create and stake a brand new service
        _stakeViaProcessor(FULL_STAKE_DEPOSIT);

        uint256 serviceId = _firstServiceId();
        assertGt(serviceId, 0, "no service created");

        (, address multisigBefore,,,,, uint8 stateBefore) = IService(address(serviceRegistry)).mapServices(serviceId);
        assertEq(stateBefore, uint8(4), "service is not Deployed after initial stake");
        assertEq(stakingTokenInstance.getNumServiceIds(), 1, "service is not staked");

        address activityModuleBefore = stakingManager.mapServiceIdActivityModules(serviceId);

        // Unstake it: terminates and unbonds the service, leaving it in PreRegistration
        _unstakeViaProcessor(FULL_STAKE_DEPOSIT);

        (,,,,,, uint8 stateUnstaked) = IService(address(serviceRegistry)).mapServices(serviceId);
        assertEq(stateUnstaked, uint8(1), "service is not in PreRegistration after unstake");
        assertEq(stakingManager.mapLastStakedServiceIdxs(address(stakingTokenInstance)), 0, "index not rolled back");
        assertEq(stakingTokenInstance.getNumServiceIds(), 0, "service is still staked");

        // Re-stake: this takes the _deployAndStake branch, which is the path that used to revert
        _stakeViaProcessor(FULL_STAKE_DEPOSIT);

        // Same service is reused, not a fresh one
        assertEq(_firstServiceId(), serviceId, "a new service was created instead of reusing");

        (, address multisigAfter,,,,, uint8 stateAfter) = IService(address(serviceRegistry)).mapServices(serviceId);
        assertEq(multisigAfter, multisigBefore, "multisig changed across re-deployment");
        assertEq(stateAfter, uint8(4), "service is not Deployed after re-deployment");
        assertEq(stakingTokenInstance.getNumServiceIds(), 1, "service is not staked again");

        // The activity module is preserved and remains the multisig owner, so liveness keeps working
        assertEq(stakingManager.mapServiceIdActivityModules(serviceId), activityModuleBefore, "activity module changed");

        // The staking proxy independently verifies the multisig code hash, so a successful stake above already
        // proves the re-deployed multisig is byte-identical to what the pool expects
        assertEq(multisigAfter.codehash, multisigProxyHash, "multisig proxy hash changed");
    }

    /// @dev Re-deployment reuses the agent Id the service was created with, not the current implementation one.
    ///
    /// Mirrors live Gnosis state, where services created by an earlier StakingManager implementation carry a
    /// different agent Id than the current immutable one, and registerAgents() only accepts their own.
    function testReDeployUsesServiceOwnAgentId() public {
        uint256 legacyAgentId = stakingManager.agentId();

        // Create, stake and unstake a service under the current (now "legacy") agent Id
        _stakeViaProcessor(FULL_STAKE_DEPOSIT);
        uint256 serviceId = _firstServiceId();
        _unstakeViaProcessor(FULL_STAKE_DEPOSIT);

        // Upgrade to an implementation carrying a different immutable agent Id, exactly as the live Gnosis
        // StakingManager was upgraded from agent Id 69 to 85 while its existing services stayed on 69
        uint256 newAgentId = legacyAgentId + 1;

        StakingManager newImplementation = new StakingManager(
            address(olas),
            address(serviceManager),
            address(stakingFactory),
            address(safeModuleInitializer),
            address(gnosisSafeL2),
            address(beacon),
            address(collector),
            newAgentId,
            DEFAULT_HASH
        );
        stakingManager.changeImplementation(address(newImplementation));
        assertEq(stakingManager.agentId(), newAgentId, "implementation was not upgraded");

        // Re-stake the legacy service: it must be registered under its own agent Id, not the new immutable one
        _stakeViaProcessor(FULL_STAKE_DEPOSIT);

        assertEq(_firstServiceId(), serviceId, "legacy service was not reused");
        (,,,,,, uint8 state) = IService(address(serviceRegistry)).mapServices(serviceId);
        assertEq(state, uint8(4), "legacy service is not Deployed");
        assertEq(stakingTokenInstance.getNumServiceIds(), 1, "legacy service is not staked");
    }

    /// @dev Re-deployment fails loudly while recoveryModule is unset, which is the state of a proxy upgraded
    ///      from an implementation that had no such slot until changeMultisigImplementations() is called.
    function testReDeployRevertsWithoutRecoveryModule() public {
        _stakeViaProcessor(FULL_STAKE_DEPOSIT);
        _unstakeViaProcessor(FULL_STAKE_DEPOSIT);

        // Wipe the appended recoveryModule slot to emulate a freshly upgraded proxy
        vm.store(address(stakingManager), bytes32(_recoveryModuleSlot()), bytes32(0));
        assertEq(stakingManager.recoveryModule(), address(0), "recoveryModule was not wiped");

        address processor = stakingManager.l2StakingProcessor();
        olas.mint(processor, FULL_STAKE_DEPOSIT);
        vm.prank(processor);
        olas.approve(address(stakingManager), FULL_STAKE_DEPOSIT);

        vm.prank(processor);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        stakingManager.stake(address(stakingTokenInstance), FULL_STAKE_DEPOSIT, STAKE_OPERATION);

        // Setting it restores the path
        stakingManager.changeMultisigImplementations(
            address(gnosisSafeMultisig), address(recoveryModule), address(fallbackHandler)
        );
        vm.prank(processor);
        stakingManager.stake(address(stakingTokenInstance), FULL_STAKE_DEPOSIT, STAKE_OPERATION);
        assertEq(stakingTokenInstance.getNumServiceIds(), 1, "service is not staked after recovery module was set");
    }

    /// @dev Multisig implementations are owner-settable and must be whitelisted in the service registry.
    function testChangeMultisigImplementations() public {
        // Only owner
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSignature("OwnerOnly(address,address)", agent, address(this)));
        stakingManager.changeMultisigImplementations(
            address(gnosisSafeMultisig), address(recoveryModule), address(fallbackHandler)
        );

        // No zero addresses
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        stakingManager.changeMultisigImplementations(address(0), address(recoveryModule), address(fallbackHandler));
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        stakingManager.changeMultisigImplementations(address(gnosisSafeMultisig), address(0), address(fallbackHandler));
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        stakingManager.changeMultisigImplementations(address(gnosisSafeMultisig), address(recoveryModule), address(0));

        // A de-whitelisted implementation is rejected, which is exactly what happened on-chain to the
        // same address multisig and what left the protocol with an unusable re-deployment path
        vm.expectRevert(
            abi.encodeWithSignature("UnauthorizedMultisig(address)", address(gnosisSafeSameAddressMultisig))
        );
        stakingManager.changeMultisigImplementations(
            address(gnosisSafeSameAddressMultisig), address(recoveryModule), address(fallbackHandler)
        );
        vm.expectRevert(
            abi.encodeWithSignature("UnauthorizedMultisig(address)", address(gnosisSafeSameAddressMultisig))
        );
        stakingManager.changeMultisigImplementations(
            address(gnosisSafeMultisig), address(gnosisSafeSameAddressMultisig), address(fallbackHandler)
        );

        // Happy path
        stakingManager.changeMultisigImplementations(
            address(gnosisSafeMultisig), address(recoveryModule), address(agent)
        );
        assertEq(stakingManager.safeMultisig(), address(gnosisSafeMultisig));
        assertEq(stakingManager.recoveryModule(), address(recoveryModule));
        assertEq(stakingManager.fallbackHandler(), address(agent));
    }

    /// @dev The whole stake / unstake / re-stake cycle works with the same address multisig de-whitelisted,
    ///      which is the live registry state on Gnosis, Base and Mode.
    function testCycleWithoutSameAddressMultisig() public {
        assertFalse(
            serviceRegistry.mapMultisigs(address(gnosisSafeSameAddressMultisig)),
            "same address multisig must not be whitelisted in this harness"
        );

        uint256 serviceId;
        for (uint256 i = 0; i < 3; ++i) {
            _stakeViaProcessor(FULL_STAKE_DEPOSIT);
            assertEq(stakingTokenInstance.getNumServiceIds(), 1, "not staked");
            assertEq(stakingManager.getStakedServiceIds(address(stakingTokenInstance)).length, 1, "not tracked");

            // Every cycle after the first one reuses the very same service, exercising _deployAndStake
            if (i == 0) {
                serviceId = _firstServiceId();
            } else {
                assertEq(_firstServiceId(), serviceId, "a new service was created instead of reusing");
            }

            _unstakeViaProcessor(FULL_STAKE_DEPOSIT);
            assertEq(stakingTokenInstance.getNumServiceIds(), 0, "not unstaked");
        }

        // No extra services leaked into the set: index 1 is the only entry past the blank slot
        vm.expectRevert();
        stakingManager.mapStakedServiceIds(address(stakingTokenInstance), 2);
    }

    /// @dev Storage slot of the appended recoveryModule variable in StakingManager.
    function _recoveryModuleSlot() internal pure returns (uint256) {
        // Implementation.owner(0), safeMultisig(1), _deprecatedSafeSameAddressMultisig(2), fallbackHandler(3),
        // l2StakingProcessor(4), _nonce(5), _locked(6), mapStakingProxyBalances(7), mapStakedServiceIds(8),
        // mapServiceIdActivityModules(9), mapLastStakedServiceIdxs(10), recoveryModule(11)
        return 11;
    }
}
