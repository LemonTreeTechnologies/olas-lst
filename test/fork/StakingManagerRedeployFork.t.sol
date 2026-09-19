// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

import {StakingManager} from "../../contracts/l2/StakingManager.sol";
import {IService} from "../../contracts/interfaces/IService.sol";

interface IServiceRegistryFork {
    function mapMultisigs(address multisigImplementation) external view returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IServiceManagerFork {
    function activateRegistration(uint256 serviceId) external payable returns (bool);
    function registerAgents(uint256 serviceId, address[] memory agentInstances, uint32[] memory agentIds)
        external
        payable
        returns (bool);
    function deploy(uint256 serviceId, address multisigImplementation, bytes memory data)
        external
        returns (address multisig);
}

interface ISafeFork {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function isModuleEnabled(address module) external view returns (bool);
}

/// @dev Reproduces the live Gnosis re-deployment blocker against real mainnet state, and proves the fix.
///
/// GnosisSafeSameAddressMultisig has been de-whitelisted in the Gnosis ServiceRegistryL2, so the re-deployment
/// branch of StakingManager reverts UnauthorizedMultisig. Twenty services sit in PreRegistration on the first
/// staking pool as a result, and every one of them additionally carries agent Id 69 while the deployed
/// implementation's immutable agent Id is 85 - so re-registration fails before the multisig check is even reached.
///
/// Requires an archive-capable Gnosis RPC. Set GNOSIS_RPC_URL to run; the suite skips itself otherwise so that
/// CI, which has no such endpoint, stays green.
contract StakingManagerRedeployForkTest is Test {
    // Live Gnosis deployment
    address internal constant STAKING_MANAGER_PROXY = 0xEfF4A1D9faF5c750d5E32754c40Cf163767C63A4;
    address internal constant SERVICE_REGISTRY = 0x9338b5153AE39BB89f50468E608eD9d764B755fD;
    address internal constant SERVICE_MANAGER = 0x068a4f0946cF8c7f9C1B58a3b5243Ac8843bf473;
    address internal constant OLAS = 0xcE11e14225575945b8E6Dc0D4F2dD4C570f79d9f;
    address internal constant SERVICE_REGISTRY_TOKEN_UTILITY = 0xa45E64d13A30a51b91ae0eb182e88a40e9b18eD8;

    // Multisig implementations
    address internal constant SAME_ADDRESS_MULTISIG = 0x6e7f594f680f7aBad18b7a63de50F0FeE47dfD06;
    address internal constant SAFE_MULTISIG = 0x3C1fF68f5aa342D296d4DEe4Bb1cACCA912D95fE;
    address internal constant RECOVERY_MODULE = 0x0Cb12457ed26d572c5e4A50f30b6f7A904662a72;
    address internal constant FALLBACK_HANDLER = 0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4;

    // A service parked in PreRegistration on the first staking pool, created under the legacy agent Id
    uint256 internal constant PARKED_SERVICE_ID = 2409;
    uint256 internal constant LEGACY_AGENT_ID = 69;
    address internal constant PARKED_SERVICE_MULTISIG = 0x360e0cC5720306C184D26898cb940C5E85d231b0;
    address internal constant PARKED_SERVICE_ACTIVITY_MODULE = 0x7BF0c431Dbcd485B25f0D6326D0975d7146Fa703;

    // The pools' expected service multisig code hash, verified identical across Gnosis and Base
    bytes32 internal constant MULTISIG_PROXY_HASH = 0xb89c1b3bdf2cf8827818646bce9a8f6e372885f8c55e5c07acbd307cb133b000;

    // OLAS balance slot in the Gnosis OLAS token
    uint256 internal constant OLAS_BALANCE_SLOT = 3;

    // Selector of UnauthorizedMultisig(address), raised by ServiceRegistryL2 on a de-whitelisted implementation
    bytes4 internal constant UNAUTHORIZED_MULTISIG = 0x14460f20;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("GNOSIS_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console.log("GNOSIS_RPC_URL is not set, skipping Gnosis fork tests");
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;

        // Fund the staking manager so it can pay the native deposit and bond wrappers
        vm.deal(STAKING_MANAGER_PROXY, 1 ether);
        // Fund it with OLAS and approve the token utility for the security deposit and operator bond
        vm.store(
            OLAS, keccak256(abi.encode(STAKING_MANAGER_PROXY, OLAS_BALANCE_SLOT)), bytes32(uint256(1_000_000 ether))
        );
        vm.prank(STAKING_MANAGER_PROXY);
        (bool success,) = OLAS.call(
            abi.encodeWithSignature("approve(address,uint256)", SERVICE_REGISTRY_TOKEN_UTILITY, type(uint256).max)
        );
        require(success, "OLAS approve failed");
    }

    /// @dev The live registry state that causes the blocker.
    function testLiveWhitelistState() public {
        if (!forked) return;

        assertFalse(
            IServiceRegistryFork(SERVICE_REGISTRY).mapMultisigs(SAME_ADDRESS_MULTISIG),
            "same address multisig is expected to be de-whitelisted"
        );
        assertTrue(IServiceRegistryFork(SERVICE_REGISTRY).mapMultisigs(SAFE_MULTISIG), "safe multisig not whitelisted");
        assertTrue(
            IServiceRegistryFork(SERVICE_REGISTRY).mapMultisigs(RECOVERY_MODULE), "recovery module not whitelisted"
        );
    }

    /// @dev The parked service is exactly in the state the re-deployment branch is meant to consume.
    function testParkedServiceState() public {
        if (!forked) return;

        (, address multisig,,,,, uint8 state) = IService(SERVICE_REGISTRY).mapServices(PARKED_SERVICE_ID);
        assertEq(state, uint8(1), "service is not in PreRegistration");
        assertEq(multisig, PARKED_SERVICE_MULTISIG, "unexpected service multisig");
        assertEq(multisig.codehash, MULTISIG_PROXY_HASH, "unexpected multisig proxy hash");

        // Sole owner is the activity module, which is exactly what the recovery module verifies against
        address[] memory owners = ISafeFork(multisig).getOwners();
        assertEq(owners.length, 1, "unexpected number of owners");
        assertEq(owners[0], PARKED_SERVICE_ACTIVITY_MODULE, "owner is not the activity module");
        assertEq(ISafeFork(multisig).getThreshold(), 1, "unexpected threshold");

        // The recovery module is not a module on this multisig, and does not need to be: since owners already
        // match the agent instances, RecoveryModule.create() performs verification only
        assertFalse(ISafeFork(multisig).isModuleEnabled(RECOVERY_MODULE), "recovery module unexpectedly enabled");
        assertTrue(ISafeFork(multisig).isModuleEnabled(PARKED_SERVICE_ACTIVITY_MODULE), "activity module not enabled");
    }

    /// @dev The old code path reverts against live state, the new one succeeds and returns the same multisig.
    function testReDeployPathsAgainstLiveState() public {
        if (!forked) return;

        _bringServiceToFinishedRegistration();

        // Old path: the de-whitelisted same address multisig
        vm.prank(STAKING_MANAGER_PROXY);
        vm.expectRevert(abi.encodeWithSelector(UNAUTHORIZED_MULTISIG, SAME_ADDRESS_MULTISIG));
        IServiceManagerFork(SERVICE_MANAGER)
            .deploy(PARKED_SERVICE_ID, SAME_ADDRESS_MULTISIG, abi.encodePacked(PARKED_SERVICE_MULTISIG));

        // New path: the whitelisted recovery module, acting as a same-address verifier
        vm.prank(STAKING_MANAGER_PROXY);
        address multisig = IServiceManagerFork(SERVICE_MANAGER)
            .deploy(PARKED_SERVICE_ID, RECOVERY_MODULE, abi.encode(PARKED_SERVICE_ID));

        assertEq(multisig, PARKED_SERVICE_MULTISIG, "multisig changed across re-deployment");
        assertEq(multisig.codehash, MULTISIG_PROXY_HASH, "multisig proxy hash changed");

        (, address registryMultisig,,,,, uint8 state) = IService(SERVICE_REGISTRY).mapServices(PARKED_SERVICE_ID);
        assertEq(state, uint8(4), "service is not Deployed");
        assertEq(registryMultisig, PARKED_SERVICE_MULTISIG, "registry multisig changed");

        // Owner and modules are untouched, so liveness and reward claiming keep working
        address[] memory owners = ISafeFork(multisig).getOwners();
        assertEq(owners.length, 1, "unexpected number of owners after re-deployment");
        assertEq(owners[0], PARKED_SERVICE_ACTIVITY_MODULE, "owner changed after re-deployment");
        assertTrue(
            ISafeFork(multisig).isModuleEnabled(PARKED_SERVICE_ACTIVITY_MODULE),
            "activity module disabled after re-deployment"
        );
    }

    /// @dev The deployed implementation's immutable agent Id no longer matches its own services.
    function testDeployedAgentIdMismatch() public {
        if (!forked) return;

        assertEq(StakingManager(payable(STAKING_MANAGER_PROXY)).agentId(), 85, "unexpected deployed agent Id");

        vm.prank(STAKING_MANAGER_PROXY);
        IServiceManagerFork(SERVICE_MANAGER).activateRegistration{value: 1}(PARKED_SERVICE_ID);

        address[] memory instances = new address[](1);
        instances[0] = PARKED_SERVICE_ACTIVITY_MODULE;
        uint32[] memory agentIds = new uint32[](1);

        // The current immutable agent Id is rejected by the service it is supposed to re-register
        agentIds[0] = 85;
        vm.prank(STAKING_MANAGER_PROXY);
        vm.expectRevert(abi.encodeWithSignature("AgentNotInService(uint256,uint256)", 85, PARKED_SERVICE_ID));
        IServiceManagerFork(SERVICE_MANAGER).registerAgents{value: 1}(PARKED_SERVICE_ID, instances, agentIds);

        // The service's own agent Id is accepted, which is what the fix reads from the registry
        agentIds[0] = uint32(LEGACY_AGENT_ID);
        vm.prank(STAKING_MANAGER_PROXY);
        IServiceManagerFork(SERVICE_MANAGER).registerAgents{value: 1}(PARKED_SERVICE_ID, instances, agentIds);

        (,,,,,, uint8 state) = IService(SERVICE_REGISTRY).mapServices(PARKED_SERVICE_ID);
        assertEq(state, uint8(3), "service did not reach FinishedRegistration");
    }

    /// @dev Drives the parked service from PreRegistration to FinishedRegistration, as _deployAndStake does.
    function _bringServiceToFinishedRegistration() internal {
        vm.prank(STAKING_MANAGER_PROXY);
        IServiceManagerFork(SERVICE_MANAGER).activateRegistration{value: 1}(PARKED_SERVICE_ID);

        address[] memory instances = new address[](1);
        instances[0] = PARKED_SERVICE_ACTIVITY_MODULE;
        uint32[] memory agentIds = new uint32[](1);
        agentIds[0] = uint32(LEGACY_AGENT_ID);

        vm.prank(STAKING_MANAGER_PROXY);
        IServiceManagerFork(SERVICE_MANAGER).registerAgents{value: 1}(PARKED_SERVICE_ID, instances, agentIds);
    }
}
