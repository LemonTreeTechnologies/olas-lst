// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

import {ExternalStakingDistributor} from "../../contracts/l2/ExternalStakingDistributor.sol";
import {SafeSetupHelper} from "../../contracts/l2/SafeSetupHelper.sol";
import {IService} from "../../contracts/interfaces/IService.sol";

interface IServiceRegistryFork {
    function mapMultisigs(address multisigImplementation) external view returns (bool);
}

interface IStakingFork {
    function getServiceIds() external view returns (uint256[] memory);
    function getAgentIds() external view returns (uint256[] memory);
    function minStakingDeposit() external view returns (uint256);
    function availableRewards() external view returns (uint256);
    function maxNumServices() external view returns (uint256);
    function proxyHash() external view returns (bytes32);
}

interface ISafeView {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function isModuleEnabled(address module) external view returns (bool);
}

interface IMultisigImplementationFork {
    function safe() external view returns (address);
    function safeProxyFactory() external view returns (address);
    function gnosisSafe() external view returns (address payable);
    function gnosisSafeProxyFactory() external view returns (address);
}

/// @dev Service creation against live Gnosis state.
///
/// The local harness deploys its own registries, so it cannot show that the create path works against the
/// registry the protocol is actually wired to. Three properties of live contracts carry this fix, and each is
/// asserted here rather than checked by hand: GnosisSafeMultisig is whitelisted, it shares the Safe singleton
/// and proxy factory with safeMultisigWithRecoveryModule so the created Safe keeps the code hash the staking
/// pools verify, and the Safe `setup()` delegatecall seam behaves as the mock does.
///
/// The distributor implementation and the setup helper are deployed and the live proxy is upgraded, exactly as
/// the deployment will do, so this also exercises the documented migration order: changeImplementation followed
/// by changeMultisigImplementations.
///
/// Requires an archive-capable Gnosis RPC. Set GNOSIS_RPC_URL to run; the suite skips itself otherwise so that
/// CI, which has no such endpoint, stays green.
contract ExternalStakingCreateForkTest is Test {
    // Live Gnosis deployment
    address internal constant ESD_PROXY = 0x7E8C636FBD0D9085C112680d8C3fde701452dcb5;
    address internal constant ESD_OWNER = 0x40c0392c23fAfa216C69Bc291AFcb1b3F4abd49b;
    address internal constant MULTISIG_GUARD = 0xBD645cf2D4F04A1c12B97fe2a8b4A09EF50F1896;
    address internal constant SERVICE_MANAGER = 0x068a4f0946cF8c7f9C1B58a3b5243Ac8843bf473;
    address internal constant SERVICE_REGISTRY = 0x9338b5153AE39BB89f50468E608eD9d764B755fD;
    address internal constant COLLECTOR = 0x64003846B67D66AfdFb03325fa4292b76FCF182F;
    address internal constant OLAS = 0xcE11e14225575945b8E6Dc0D4F2dD4C570f79d9f;
    address internal constant MULTI_SEND = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;
    address internal constant FALLBACK_HANDLER = 0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4;

    // Multisig implementations
    address internal constant SAFE_MULTISIG_WITH_RECOVERY = 0xB4eB492bbfDcE5ccc11d675797cCF090eB0bCbd6;
    address internal constant GNOSIS_SAFE_MULTISIG = 0x3C1fF68f5aa342D296d4DEe4Bb1cACCA912D95fE;
    address internal constant SAME_ADDRESS_MULTISIG = 0x6e7f594f680f7aBad18b7a63de50F0FeE47dfD06;
    address internal constant RECOVERY_MODULE = 0x0Cb12457ed26d572c5e4A50f30b6f7A904662a72;

    // An external staking pool the distributor is already configured for, with free slots and rewards
    address internal constant STAKING_PROXY = 0xeF44Fb0842DDeF59D37f85D61A1eF492bbA6135d;

    // The code hash every staking pool verifies a service multisig against
    bytes32 internal constant MULTISIG_PROXY_HASH = 0xb89c1b3bdf2cf8827818646bce9a8f6e372885f8c55e5c07acbd307cb133b000;

    // Guard storage slot, keccak256("guard_manager.guard.address")
    bytes32 internal constant GUARD_STORAGE_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;

    // OLAS balance mapping slot in the Gnosis OLAS token
    uint256 internal constant OLAS_BALANCE_SLOT = 3;

    // Service config hash: the pool imposes none, so any non-zero value is valid
    bytes32 internal constant CONFIG_HASH = 0xcbbaa134c10c0a7805c42f8897dd6ea8ffe1225368f85ea9a2230fe70308fb0c;

    ExternalStakingDistributor internal distributor;
    SafeSetupHelper internal safeSetupHelper;
    address internal agentInstance;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("GNOSIS_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console.log("GNOSIS_RPC_URL is not set, skipping Gnosis fork tests");
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;

        distributor = ExternalStakingDistributor(payable(ESD_PROXY));
        agentInstance = makeAddr("agentInstance");

        // Deploy the helper and the new implementation, then upgrade the live proxy in the documented order
        safeSetupHelper = new SafeSetupHelper();
        ExternalStakingDistributor implementation = new ExternalStakingDistributor(
            OLAS, SERVICE_MANAGER, SAFE_MULTISIG_WITH_RECOVERY, FALLBACK_HANDLER, MULTI_SEND, COLLECTOR
        );

        vm.prank(ESD_OWNER);
        distributor.changeImplementation(address(implementation));

        // Appended slots are zero on an upgraded proxy until this call, which is why it is a required step
        assertEq(distributor.safeMultisig(), address(0), "safeMultisig should be unset right after the upgrade");
        vm.prank(ESD_OWNER);
        distributor.changeMultisigImplementations(GNOSIS_SAFE_MULTISIG, address(safeSetupHelper));

        // Fund the distributor for the staking deposit and the native deposit / bond wrappers
        uint256 deposit = IStakingFork(STAKING_PROXY).minStakingDeposit() * 2;
        vm.store(OLAS, keccak256(abi.encode(ESD_PROXY, OLAS_BALANCE_SLOT)), bytes32(deposit));
        vm.deal(ESD_PROXY, 1 ether);
    }

    /// @dev The live registry admits the implementation this fix routes through, and rejects the one it replaces.
    function testLiveWhitelistState() public {
        if (!forked) return;

        assertTrue(
            IServiceRegistryFork(SERVICE_REGISTRY).mapMultisigs(GNOSIS_SAFE_MULTISIG),
            "GnosisSafeMultisig must be whitelisted, the create path routes through it"
        );
        assertTrue(
            IServiceRegistryFork(SERVICE_REGISTRY).mapMultisigs(RECOVERY_MODULE),
            "RecoveryModule must be whitelisted, the re-deploy path routes through it"
        );
        assertFalse(
            IServiceRegistryFork(SERVICE_REGISTRY).mapMultisigs(SAME_ADDRESS_MULTISIG),
            "same address multisig is expected to stay de-whitelisted"
        );
    }

    /// @dev The substituted implementation produces a byte-identical Safe proxy.
    ///
    /// This is what makes GnosisSafeMultisig a valid stand-in: it shares the Safe singleton and proxy factory
    /// with safeMultisigWithRecoveryModule, so `keccak256(multisig.code)` still equals the pools' proxyHash.
    function testSafeSingletonAndFactoryParity() public {
        if (!forked) return;

        address safe = IMultisigImplementationFork(SAFE_MULTISIG_WITH_RECOVERY).safe();
        address factory = IMultisigImplementationFork(SAFE_MULTISIG_WITH_RECOVERY).safeProxyFactory();

        assertEq(IMultisigImplementationFork(GNOSIS_SAFE_MULTISIG).gnosisSafe(), safe, "Safe singleton differs");
        assertEq(
            IMultisigImplementationFork(GNOSIS_SAFE_MULTISIG).gnosisSafeProxyFactory(), factory, "Safe factory differs"
        );
        assertEq(IStakingFork(STAKING_PROXY).proxyHash(), MULTISIG_PROXY_HASH, "unexpected pool proxy hash");
    }

    /// @dev A service is created, wired and staked against the live registry and a live staking pool.
    function testCreateAndStakeAgainstLiveState() public {
        if (!forked) return;

        // The pool must have room, otherwise there is nothing to prove here
        uint256[] memory before = IStakingFork(STAKING_PROXY).getServiceIds();
        if (before.length >= IStakingFork(STAKING_PROXY).maxNumServices()) {
            console.log("staking pool is full, skipping the create-and-stake assertion");
            return;
        }
        assertGt(IStakingFork(STAKING_PROXY).availableRewards(), 0, "staking pool has no rewards");

        uint256 stakedBefore = distributor.stakedBalance();

        // agentId is passed as zero on purpose, so the distributor fetches it from the pool
        vm.prank(ESD_OWNER);
        distributor.stake(STAKING_PROXY, 0, 0, CONFIG_HASH, agentInstance);

        uint256[] memory afterIds = IStakingFork(STAKING_PROXY).getServiceIds();
        assertEq(afterIds.length, before.length + 1, "service was not staked into the pool");
        uint256 serviceId = afterIds[afterIds.length - 1];

        (, address multisig,,,,, uint8 state) = IService(SERVICE_REGISTRY).mapServices(serviceId);
        assertEq(state, uint8(4), "service is not Deployed");
        assertTrue(multisig != address(0), "no multisig created");

        // The pool verifies this itself, so a successful stake already proves it; asserted explicitly because it
        // is the property that makes the substituted implementation safe
        assertEq(multisig.codehash, MULTISIG_PROXY_HASH, "created multisig has an unexpected code hash");

        // Owner is the agent instance, as the previous pre-create plus swapOwner flow produced
        address[] memory owners = ISafeView(multisig).getOwners();
        assertEq(owners.length, 1, "unexpected number of owners");
        assertEq(owners[0], agentInstance, "owner is not the agent instance");
        assertEq(ISafeView(multisig).getThreshold(), 1, "unexpected threshold");

        // Everything the protocol needs, wired by the setup delegatecall
        assertTrue(ISafeView(multisig).isModuleEnabled(ESD_PROXY), "distributor is not a module");
        assertTrue(ISafeView(multisig).isModuleEnabled(MULTISIG_GUARD), "guard is not a module");
        assertTrue(ISafeView(multisig).isModuleEnabled(RECOVERY_MODULE), "recovery module is not a module");
        assertEq(
            address(uint160(uint256(vm.load(multisig, GUARD_STORAGE_SLOT)))),
            MULTISIG_GUARD,
            "transaction guard is not set"
        );

        // The guard resolves the multisig to its service Id, otherwise every guarded transaction reverts
        assertEq(distributor.mapMultisigServiceIds(multisig), serviceId, "multisig is not linked to its service");

        // Accounting followed the deposit
        uint256 deposit = IStakingFork(STAKING_PROXY).minStakingDeposit() * 2;
        assertEq(distributor.stakedBalance(), stakedBefore + deposit, "staked balance was not updated");
    }

    /// @dev The path the fix replaces still reverts against live state, so the regression cannot silently return.
    function testOldCreatePathStillReverts() public {
        if (!forked) return;

        vm.prank(ESD_OWNER);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedMultisig(address)", SAME_ADDRESS_MULTISIG));
        distributor.changeMultisigImplementations(SAME_ADDRESS_MULTISIG, address(safeSetupHelper));
    }
}
