// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ExternalStakingDistributor} from "../../contracts/l2/ExternalStakingDistributor.sol";
import {SafeSetupHelper} from "../../contracts/l2/SafeSetupHelper.sol";

/// @dev Can we actually stake into the two fattest Base pools?
///
/// The 890,000 idle OLAS on Base is blocked because ExternalStakingDistributor's create path goes
/// through GnosisSafeSameAddressMultisig, which the Base ServiceRegistry has de-whitelisted. This
/// test asks the next question: once that is fixed (the fix branch under test here), do the live
/// Base pools actually ACCEPT a service the distributor produces?
///
/// It runs the whole thing against live Base state -- live ServiceRegistry, live ServiceManager,
/// live staking proxies -- with a freshly deployed distributor standing in for the deployed one,
/// so nothing about the answer depends on a mock.
///
/// Run: forge test --match-contract BaseFatPoolsStakeFork -vv    (needs BASE_RPC_URL)
interface IStakingProxy {
    function getAgentIds() external view returns (uint256[] memory);
    function getServiceIds() external view returns (uint256[] memory);
    function maxNumServices() external view returns (uint256);
    function minStakingDeposit() external view returns (uint256);
    function availableRewards() external view returns (uint256);
    function numAgentInstances() external view returns (uint256);
    function threshold() external view returns (uint256);
    function configHash() external view returns (bytes32);
    function proxyHash() external view returns (bytes32);
}

interface IChecker {
    function isRatioPass(uint256[] memory curNonces, uint256[] memory lastNonces, uint256 ts)
        external
        view
        returns (bool);
    function livenessRatio() external view returns (uint256);
}

interface IStakingProxy2 {
    function activityChecker() external view returns (address);
}

interface IServiceRegistryF {
    function totalSupply() external view returns (uint256);
}

interface IERC20D {
    function balanceOf(address) external view returns (uint256);
}

contract BaseFatPoolsStakeForkTest is Test {
    // Live Base addresses, from scripts/deployment/globals_base_mainnet.json
    address constant OLAS = 0x54330d28ca3357F294334BDC454a032e7f353416;
    address constant SERVICE_MANAGER = 0x1262136cac6a06A782DC94eb3a3dF0b4d09FF6A6;
    address constant SERVICE_REGISTRY = 0x3C1fF68f5aa342D296d4DEe4Bb1cACCA912D95fE;
    address constant SAFE_MULTISIG_RECOVERY = 0x8c534420Db046d6801A1A8bE6fb602cC8F257453;
    address constant FALLBACK_HANDLER = 0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4;
    address constant MULTISEND = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;
    address constant COLLECTOR_PROXY = 0xaC7eA9478E0e1186E7D1c82b8d8dc80AEe0F79F6;
    address constant GNOSIS_SAFE_MULTISIG = 0x22bE6fDcd3e29851B29b512F714C328A00A96B83;
    address constant MULTISIG_GUARD_PROXY = 0x4D3911420a8E4E7dB8c979f4915dA8983C5e3ba2;
    bytes32 constant CONFIG_HASH = 0xca0a2dda805c401808b21b8fdf86eb8b1b4117931cb6dbf8226c38dfd0214068;

    // The targets: the two fattest Base pools, plus the best-ROC one as a control.
    address constant POOL_51c5 = 0x51c5f4982B9b0B3c0482678f5847EA6228Cc8E54; // 116,642 OLAS
    address constant POOL_66A9 = 0x66A92CDa5B319DCCcAC6c1cECbb690CA3Fb59488; //  45,480 OLAS
    address constant POOL_B14C = 0xB14Cd66c6c601230EA79fa7Cc072E5E0C2F3A756; //  45,600 OLAS

    ExternalStakingDistributor internal esd;
    address internal agentInstance = address(0xA1);

    function _skip() internal returns (bool) {
        try vm.envString("BASE_RPC_URL") returns (string memory) {
            return false;
        } catch {
            console.log("SKIP: BASE_RPC_URL not set");
            return true;
        }
    }

    function _setUpFork() internal {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        esd = new ExternalStakingDistributor(
            OLAS, SERVICE_MANAGER, SAFE_MULTISIG_RECOVERY, FALLBACK_HANDLER, MULTISEND, COLLECTOR_PROXY
        );
        SafeSetupHelper helper = new SafeSetupHelper();
        esd.initialize(GNOSIS_SAFE_MULTISIG, address(helper));
        // Creation reverts without a multisig guard; the live Base deployment has one.
        esd.changeMultisigGuard(MULTISIG_GUARD_PROXY);
        // activateRegistration/registerAgents post a 1-wei-per-instance native bond, so the
        // distributor needs dust ETH. The live Base distributor must hold some too.
        vm.deal(address(esd), 1 ether);
    }

    function _whitelist(address pool) internal {
        address[] memory proxies = new address[](1);
        uint256[] memory configs = new uint256[](1);
        proxies[0] = pool;
        // stakingGuard 0 => any caller may stake; factors 5000/0/5000; StakingType.V1 == 1
        configs[0] = esd.wrapStakingConfig(
            address(0), 5000, 0, 5000, ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1
        );
        esd.setStakingProxyConfigs(proxies, configs);
    }

    /// @dev Report each pool's acceptance criteria against what the distributor produces.
    function test_poolRequirementsVsWhatWeProduce() public {
        if (_skip()) return;
        _setUpFork();
        address[3] memory pools = [POOL_51c5, POOL_66A9, POOL_B14C];
        string[3] memory names = ["0x51c5f498", "0x66A92CDa", "0xB14Cd66c"];
        for (uint256 i = 0; i < 3; ++i) {
            IStakingProxy p = IStakingProxy(pools[i]);
            uint256[] memory ids = p.getAgentIds();
            console.log("---");
            console.log(names[i]);
            emit log_named_uint("agentIds len", ids.length);
            if (ids.length > 0) {
                emit log_named_uint("agentIds[0]", ids[0]);
            } else {
                console.log("  agentIds          : UNCONSTRAINED (empty) -- caller must pass one");
            }
            emit log_named_uint("numAgentInstances", p.numAgentInstances());
            emit log_named_uint("threshold", p.threshold());
            emit log_named_uint("minStakingDeposit", p.minStakingDeposit() / 1e18);
            emit log_named_uint("free seats", p.maxNumServices() - p.getServiceIds().length);
            emit log_named_uint("availableRewards", p.availableRewards() / 1e18);
            assertEq(p.numAgentInstances(), 1, "distributor only ever makes 1-instance services");
        }
    }

    function _tryStake(address pool, uint256 agentId, string memory label) internal {
        _whitelist(pool);
        uint256 seat = IStakingProxy(pool).minStakingDeposit() * 2;
        deal(OLAS, address(esd), seat * 2);

        uint256[] memory occupiedBefore = IStakingProxy(pool).getServiceIds();
        uint256 idBefore = IServiceRegistryF(SERVICE_REGISTRY).totalSupply();

        esd.stake(pool, 0, agentId, CONFIG_HASH, agentInstance);

        // Do NOT assert on the seat COUNT. stake() runs _checkpoint() internally, and on these
        // pools that evicts the sitting foreign services -- every one of them is far past the
        // inactivity threshold -- so the count can fall even though our seat was taken. Assert
        // that OUR new service id is actually in the pool.
        uint256 newId = IServiceRegistryF(SERVICE_REGISTRY).totalSupply();
        assertEq(newId, idBefore + 1, "no new service was minted");

        uint256[] memory occupiedAfter = IStakingProxy(pool).getServiceIds();
        bool found;
        for (uint256 i = 0; i < occupiedAfter.length; ++i) {
            if (occupiedAfter[i] == newId) found = true;
        }
        assertTrue(found, "our service is not staked in the pool");

        console.log("STAKED ok:", label);
        emit log_named_uint("serviceId", newId);
        emit log_named_uint("seat cost (OLAS)", seat / 1e18);
        emit log_named_uint("seats before", occupiedBefore.length);
        emit log_named_uint("seats after", occupiedAfter.length);
        if (occupiedAfter.length <= occupiedBefore.length) {
            console.log("   NOTE: sitting foreign services were evicted by the internal checkpoint");
        }
    }

    function test_stake_51c5_biggestPot() public {
        if (_skip()) return;
        _setUpFork();
        _tryStake(POOL_51c5, 0, "0x51c5f498");
    }

    function test_stake_66A9() public {
        if (_skip()) return;
        _setUpFork();
        _tryStake(POOL_66A9, 0, "0x66A92CDa");
    }

    /// @dev B14C exposes getAgentIds() == [], so agentId 0 cannot be auto-derived and the caller
    /// must pass one explicitly. Both behaviours are asserted.
    function test_stake_B14C_needsExplicitAgentId() public {
        if (_skip()) return;
        _setUpFork();
        _whitelist(POOL_B14C);
        deal(OLAS, address(esd), 40_000e18);
        assertEq(IStakingProxy(POOL_B14C).getAgentIds().length, 0, "B14C now constrains agentIds");
        vm.expectRevert();
        esd.stake(POOL_B14C, 0, 0, CONFIG_HASH, agentInstance);
        console.log("agentId 0 reverts on B14C as expected; retrying with an explicit id");
        _tryStake(POOL_B14C, 103, "0xB14Cd66c");
    }

    // ── Liveness: can these pools actually PAY? ──────────────────────────────────────────

    /// @dev Regression guard for a probe bug that nearly cost us the biggest pot on Base.
    ///
    /// This checker bounds claimed activity by Safe transactions (see the contract comment), so
    /// a UNIFORM probe vector of value v gives total = 4v against nonceDelta = v and fails at
    /// ANY magnitude. Probed that way on 2026-09-19, 0x51c5f498 returned false at 20, 100,
    /// 1,000, 100,000 and 2^64-1, and was written off as unable to ever credit. It credits
    /// 41.096 OLAS/service/day -- see Jinn51c5RewardFork.
    ///
    /// The uniform shape failing is a property of the BOUND, not of the pool. This test pins
    /// that down so nobody reads such a result as "the pool is dead" again.
    function test_51c5_uniformProbeShapeAlwaysFails() public {
        if (_skip()) return;
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        IChecker ac = IChecker(IStakingProxy2(POOL_51c5).activityChecker());

        uint256[] memory zero = new uint256[](5);
        // Sweep far past any plausible bar: the ratio needs ~19.9/day.
        uint256[5] memory probes = [uint256(20), 100, 1000, 100_000, type(uint64).max];
        for (uint256 p = 0; p < probes.length; ++p) {
            uint256[] memory cur = new uint256[](5);
            for (uint256 i = 0; i < 5; ++i) {
                cur[i] = probes[p];
            }
            assertFalse(ac.isRatioPass(cur, zero, 86400), "uniform shape passed -- the bound changed, re-verify");
        }
        emit log("uniform probe shape fails at every magnitude -- expected; use one activity per Safe tx");
    }

    /// @dev 0xB14Cd66c is the familiar two-counter shape: [safeNonce, mechDeliveryCount], both
    /// must clear the bar, which is exactly how Gnosis 0xCAbD0C94 already runs.
    function test_B14C_checkerPassesOnDeliveryShape() public {
        if (_skip()) return;
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        IChecker ac = IChecker(IStakingProxy2(POOL_B14C).activityChecker());

        uint256[] memory zero = new uint256[](2);
        uint256[] memory both = new uint256[](2);
        both[0] = 20;
        both[1] = 20;
        assertTrue(ac.isRatioPass(both, zero, 86400), "B14C should pass when both counters move");

        // Deliveries alone do not count: the Safe nonce must move with them, which is why
        // deliveries can never be batched.
        uint256[] memory onlyDeliveries = new uint256[](2);
        onlyDeliveries[1] = 20;
        assertFalse(ac.isRatioPass(onlyDeliveries, zero, 86400), "delivery-only must not pass");

        uint256[] memory onlyNonce = new uint256[](2);
        onlyNonce[0] = 20;
        assertFalse(ac.isRatioPass(onlyNonce, zero, 86400), "nonce-only must not pass");

        emit log_named_uint("B14C calls/svc/day required", (ac.livenessRatio() * 86400) / 1e18);
    }
}
