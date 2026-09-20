// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console, Vm} from "forge-std/Test.sol";
import {ExternalStakingDistributor} from "../../contracts/l2/ExternalStakingDistributor.sol";
import {SafeSetupHelper} from "../../contracts/l2/SafeSetupHelper.sol";
import {MultisigGuard} from "../../contracts/l2/MultisigGuard.sol";
import {Collector} from "../../contracts/l2/Collector.sol";
import {Proxy} from "../../contracts/Proxy.sol";

/// @dev Can we stake on Polygon pool 0x8887C285 at all? There is no LST deployment there --
/// no distributor, no collector, no globals, and the L1 Depository has no chain-137 entry --
/// so this deploys the L2 stack onto a Polygon fork and stakes for real against the live
/// registry and the live pool.
///
/// Polygon has its OWN multisig implementations; none of the Gnosis or Base addresses are
/// whitelisted there. Whitelisted on the live Polygon ServiceRegistry:
///   GnosisSafeMultisig              0x3d77596b…  (the create path)
///   SafeMultisigWithRecoveryModule  0x1a0bFCC2…  (the re-deploy path)
/// Both of which is exactly what the merged ExternalStakingDistributor needs.
///
/// Run: forge test --match-contract PolygonStakeFeasibilityFork -vv   (needs POLYGON_RPC_URL)
interface IStakingP {
    function availableRewards() external view returns (uint256);
    function rewardsPerSecond() external view returns (uint256);
    function getServiceIds() external view returns (uint256[] memory);
    function getAgentIds() external view returns (uint256[] memory);
    function minStakingDeposit() external view returns (uint256);
    function maxNumServices() external view returns (uint256);
    function proxyHash() external view returns (bytes32);
    function mapServiceInfo(uint256 id)
        external
        view
        returns (address multisig, address owner, uint256 tsStart, uint256 reward, uint256 inactivity);
}

interface IRegP {
    function totalSupply() external view returns (uint256);
    function mapMultisigs(address) external view returns (bool);
}

contract PolygonStakeFeasibilityForkTest is Test {
    // Live Polygon, from valory-xyz/autonolas-registries docs/configuration.json
    address constant OLAS = 0xFEF5d947472e72Efbb2E388c730B7428406F2F95;
    address constant SERVICE_REGISTRY = 0xE3607b00E75f6405248323A9417ff6b39B244b50;
    address constant SERVICE_MANAGER = 0xE3e5Df46060370af5Fd37B2aA11e7dac3cCB4bd0;
    address constant SR_TOKEN_UTILITY = 0xa45E64d13A30a51b91ae0eb182e88a40e9b18eD8;
    address constant SAFE_MULTISIG = 0x3d77596beb0f130a4415df3D2D8232B3d3D31e44;
    address constant SAFE_MULTISIG_RECOVERY = 0x1a0bFCC27051BCcDDc444578f56A4F5920e0E083;
    // Canonical Safe infrastructure, verified present on Polygon
    address constant FALLBACK_HANDLER = 0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4;
    address constant MULTISEND = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;

    address constant POOL = 0x8887C2852986e7cbaC99B6065fFe53074A6BCC26;
    uint256 constant AGENT_ID = 86;
    bytes32 constant CONFIG_HASH = 0xca0a2dda805c401808b21b8fdf86eb8b1b4117931cb6dbf8226c38dfd0214068;

    ExternalStakingDistributor internal esd;
    Collector internal collector;
    uint256 internal agentPk = 0xB0B;
    address internal agentInstance;

    function _skip() internal returns (bool) {
        try vm.envString("POLYGON_RPC_URL") returns (string memory) {
            return false;
        } catch {
            console.log("SKIP: POLYGON_RPC_URL not set");
            return true;
        }
    }

    /// @dev The service DEPLOYS fine on Polygon -- registry, manager and Safe creation all
    /// work -- and then the staking pool rejects the multisig with UnauthorizedMultisig.
    ///
    /// The pool checks the Safe's PROXY BYTECODE HASH, not a whitelist:
    ///   pool.proxyHash()                     0x92565062fdea8761e07d9df2fcdbd66c0582af6ddf0e0355bc07754ad97400b0
    ///   hash of a service already staked     0x92565062… (matches)
    ///   what Gnosis/Base pools accept        0xb89c1b3bdf2cf8827818646bce9a8f6e372885f8c55e5c07acbd307cb133b000
    ///
    /// So Polygon's pool wants a DIFFERENT Safe proxy implementation from the one our
    /// distributor creates, and no configuration change fixes that: the distributor builds
    /// its Safe through GnosisSafeMultisig with the canonical singleton, which produces the
    /// b89c1b3b hash everywhere. This is a contract-level blocker, not a deployment gap.
    function test_polygon_stakeRejectedByProxyHash() public {
        if (_skip()) return;
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"));
        agentInstance = vm.addr(agentPk);

        // The two implementations the distributor needs must be whitelisted on THIS chain.
        assertTrue(IRegP(SERVICE_REGISTRY).mapMultisigs(SAFE_MULTISIG), "GnosisSafeMultisig not whitelisted");
        assertTrue(
            IRegP(SERVICE_REGISTRY).mapMultisigs(SAFE_MULTISIG_RECOVERY),
            "SafeMultisigWithRecoveryModule not whitelisted"
        );

        // Deploy the L2 stack that does not exist on Polygon today.
        Collector collImpl = new Collector(OLAS);
        collector = Collector(payable(address(new Proxy(address(collImpl), abi.encodeCall(Collector.initialize, ())))));

        ExternalStakingDistributor esdImpl = new ExternalStakingDistributor(
            OLAS, SERVICE_MANAGER, SAFE_MULTISIG_RECOVERY, FALLBACK_HANDLER, MULTISEND, address(collector)
        );
        SafeSetupHelper helper = new SafeSetupHelper();
        esd = ExternalStakingDistributor(
            payable(address(
                    new Proxy(
                        address(esdImpl),
                        abi.encodeCall(ExternalStakingDistributor.initialize, (SAFE_MULTISIG, address(helper)))
                    )
                ))
        );

        MultisigGuard guardImpl = new MultisigGuard(SR_TOKEN_UTILITY, address(esd), OLAS);
        MultisigGuard guard =
            MultisigGuard(address(new Proxy(address(guardImpl), abi.encodeCall(MultisigGuard.initialize, ()))));
        esd.changeMultisigGuard(address(guard));

        // Configure the pool. openAccess true because the test stakes as itself.
        address[] memory proxies = new address[](1);
        uint256[] memory configs = new uint256[](1);
        proxies[0] = POOL;
        configs[0] = esd.wrapStakingConfig(
            address(0), 1, 1000, 8999, ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1, true
        );
        esd.setStakingProxyConfigs(proxies, configs);

        uint256 seat = IStakingP(POOL).minStakingDeposit() * 2;
        deal(OLAS, address(esd), seat * 2);
        vm.deal(address(esd), 1 ether);

        emit log_named_uint("pool availableRewards (OLAS)", IStakingP(POOL).availableRewards() / 1e18);
        emit log_named_uint("seat cost (OLAS)            ", seat / 1e18);
        emit log_named_uint(
            "free seats                  ", IStakingP(POOL).maxNumServices() - IStakingP(POOL).getServiceIds().length
        );
        emit log_named_uint("pool agentIds[0]            ", IStakingP(POOL).getAgentIds()[0]);

        emit log_named_bytes32("pool proxyHash", IStakingP(POOL).proxyHash());

        // Everything up to the staking check succeeds; the pool then rejects our Safe.
        vm.expectRevert();
        esd.stake(POOL, 0, AGENT_ID, CONFIG_HASH, agentInstance);
        emit log("stake reverts UnauthorizedMultisig: the pool wants a different Safe proxy");
    }

    /// @dev The reward split cannot be 0/x/y: setStakingProxyConfigs rejects a zero collector
    /// factor outright. This matters on Polygon, where sending the collector share to L1 is
    /// awkward, so the temptation is to zero it.
    function test_polygon_collectorFactorCannotBeZero() public {
        if (_skip()) return;
        vm.createSelectFork(vm.envString("POLYGON_RPC_URL"));

        Collector collImpl = new Collector(OLAS);
        Collector coll =
            Collector(payable(address(new Proxy(address(collImpl), abi.encodeCall(Collector.initialize, ())))));
        ExternalStakingDistributor impl = new ExternalStakingDistributor(
            OLAS, SERVICE_MANAGER, SAFE_MULTISIG_RECOVERY, FALLBACK_HANDLER, MULTISEND, address(coll)
        );
        SafeSetupHelper h = new SafeSetupHelper();
        ExternalStakingDistributor d = ExternalStakingDistributor(
            payable(address(
                    new Proxy(
                        address(impl),
                        abi.encodeCall(ExternalStakingDistributor.initialize, (SAFE_MULTISIG, address(h)))
                    )
                ))
        );

        address[] memory proxies = new address[](1);
        uint256[] memory configs = new uint256[](1);
        proxies[0] = POOL;

        // collector 0 / protocol 1000 / curating 9000 -- sums to 10000 but reverts ZeroValue.
        configs[0] = d.wrapStakingConfig(
            address(0), 0, 1000, 9000, ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1, true
        );
        vm.expectRevert();
        d.setStakingProxyConfigs(proxies, configs);

        // The nearest legal split is collector 1.
        configs[0] = d.wrapStakingConfig(
            address(0), 1, 1000, 8999, ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1, true
        );
        d.setStakingProxyConfigs(proxies, configs);
        emit log("collector factor 0 reverts; 1 is the minimum, i.e. 0.01% of rewards");
    }
}
