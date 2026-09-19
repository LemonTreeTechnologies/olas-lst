// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console, Vm} from "forge-std/Test.sol";
import {ExternalStakingDistributor} from "../../contracts/l2/ExternalStakingDistributor.sol";
import {SafeSetupHelper} from "../../contracts/l2/SafeSetupHelper.sol";

/// @dev Proves we can actually EARN on Base pool 0x51c5f498, not merely take a seat.
///
/// That pool's activity checker is a third-party contract (the Jinn "JinnRouter"), sitting behind
/// an upgradeable proxy the Jinn team owns. Its liveness rule is unusual and easy to get wrong:
///
///   nonceDelta = cur[0] - last[0]                       // Safe transactions
///   total      = sum of cur[i] - last[i] for i in 1..4  // claimed activities
///   require(total != 0 && total <= nonceDelta)          // <-- the bound
///   pass       = total * 1e18 / ts >= livenessRatio
///
/// The bound means activities can never be batched: N creations in one Safe transaction give
/// total = N against nonceDelta = 1 and credit ZERO. One activity per Safe transaction, always --
/// the same trap as mech deliveries on Gnosis 0xCAbD0C94, by a different mechanism.
///
/// Counters are [safeNonce, creation, restorationDelivery, evalCreation, evalDelivery]. Only
/// index 1 is needed: JinnRouter.createRestorationJob does `creationCount[msg.sender]++` with no
/// access control, then forwards a request to the Mech Marketplace.
///
/// What is REAL here: the live pool, the live checker/router, the live ServiceRegistry, a real
/// distributor-created service, 20 real Safe execTransaction calls through the real router, and
/// a real permissionless checkpoint() on the live pool.
/// What is MOCKED: only the Mech Marketplace's `request` call at the far end of the router, which
/// is third-party plumbing we are not testing and which would need a live mech we do not yet own.
///
/// Run: forge test --match-contract Jinn51c5RewardFork -vv    (needs BASE_RPC_URL)
interface IStakingP {
    function activityChecker() external view returns (address);
    function availableRewards() external view returns (uint256);
    function getServiceIds() external view returns (uint256[] memory);
    function minStakingDeposit() external view returns (uint256);
    function livenessPeriod() external view returns (uint256);
    function checkpoint() external returns (uint256[] memory, uint256[] memory, uint256[] memory, uint256[] memory);
    function mapServiceInfo(uint256 serviceId)
        external
        view
        returns (address multisig, address owner, uint256 tsStart, uint256 reward, uint256 inactivity);
}

interface IJinnRouter {
    function creationCount(address) external view returns (uint256);
    function livenessRatio() external view returns (uint256);
    function getMultisigNonces(address) external view returns (uint256[] memory);
}

interface ISafeTx {
    function nonce() external view returns (uint256);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool);
}

interface IMech {
    function paymentType() external view returns (bytes32);
    function maxDeliveryRate() external view returns (uint256);
}

interface IStakingP2 {
    function tsCheckpoint() external view returns (uint256);
}

interface IRegistryTS {
    function totalSupply() external view returns (uint256);
}

contract Jinn51c5RewardForkTest is Test {
    address constant OLAS = 0x54330d28ca3357F294334BDC454a032e7f353416;
    address constant SERVICE_MANAGER = 0x1262136cac6a06A782DC94eb3a3dF0b4d09FF6A6;
    address constant SERVICE_REGISTRY = 0x3C1fF68f5aa342D296d4DEe4Bb1cACCA912D95fE;
    address constant SAFE_MULTISIG_RECOVERY = 0x8c534420Db046d6801A1A8bE6fb602cC8F257453;
    address constant FALLBACK_HANDLER = 0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4;
    address constant MULTISEND = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;
    address constant COLLECTOR_PROXY = 0xaC7eA9478E0e1186E7D1c82b8d8dc80AEe0F79F6;
    address constant GNOSIS_SAFE_MULTISIG = 0x22bE6fDcd3e29851B29b512F714C328A00A96B83;
    address constant MULTISIG_GUARD_PROXY = 0x4D3911420a8E4E7dB8c979f4915dA8983C5e3ba2;
    address constant ESD_PROXY = 0x40abf47B926181148000DbCC7c8DE76A3a61a66f;
    bytes32 constant CONFIG_HASH = 0xca0a2dda805c401808b21b8fdf86eb8b1b4117931cb6dbf8226c38dfd0214068;

    address constant POOL = 0x51c5f4982B9b0B3c0482678f5847EA6228Cc8E54;
    // The pool reads liveness through the checker PROXY, but that proxy forwards with
    // STATICCALL, so it serves reads only -- a state-changing call through it reverts
    // StateChangeDuringStaticCall. The counters therefore live in the implementation's own
    // storage and activity must be sent to the implementation DIRECTLY. Both addresses report
    // the same creationCount (98 for service 601's multisig), which is how this was pinned down.
    address constant CHECKER_PROXY = 0x477C41Cccc8bd08027e40CEF80c25918C595a24d;
    address constant ROUTER = 0xfFa7118A3D820cd4E820010837D65FAfF463181B;
    address constant MECH_MARKETPLACE = 0xf24eE42edA0fc9b33B7D41B06Ee8ccD2Ef7C5020;
    address constant MECH_FACTORY = 0x2E008211f34b25A7d7c102403c6C2C3B665a1abe; // MechFactoryFixedPriceNative
    uint256 constant AGENT_ID = 103;

    ExternalStakingDistributor internal esd;
    uint256 internal agentPk = 0xA11CE;
    address internal agentInstance;

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
        agentInstance = vm.addr(agentPk);

        // Upgrade the LIVE distributor proxy in place rather than deploying a standalone one.
        // The live MultisigGuard only recognises the canonical distributor address as a module
        // (a standalone copy fails ModuleDisabled), and this is what the real fix does anyway:
        // deploy the new implementation, point the existing proxy at it, then set the Safe
        // multisig implementations. Owner is still an EOA on Base, so we impersonate it.
        ExternalStakingDistributor impl = new ExternalStakingDistributor(
            OLAS, SERVICE_MANAGER, SAFE_MULTISIG_RECOVERY, FALLBACK_HANDLER, MULTISEND, COLLECTOR_PROXY
        );
        SafeSetupHelper helper = new SafeSetupHelper();
        esd = ExternalStakingDistributor(payable(ESD_PROXY));
        address esdOwner = esd.owner();
        vm.startPrank(esdOwner);
        esd.changeImplementation(address(impl));
        esd.changeMultisigImplementations(GNOSIS_SAFE_MULTISIG, address(helper));

        address[] memory proxies = new address[](1);
        uint256[] memory configs = new uint256[](1);
        proxies[0] = POOL;
        configs[0] = esd.wrapStakingConfig(
            address(0),
            5000,
            0,
            5000,
            ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1,
            // openAccess=TRUE for the test, which stakes as this contract rather than as a
            // whitelisted curating agent. Since #20 a zero stakingGuard no longer implies open
            // access -- it must be stated -- so guard 0 + openAccess false now reverts
            // WrongStakingAccess. Production keeps openAccess FALSE and a real guard, with
            // agents allowlisted by 03_set_curating_agents.py.
            true
        );
        esd.setStakingProxyConfigs(proxies, configs);
        vm.stopPrank();

        vm.deal(address(esd), 1 ether);
        deal(OLAS, address(esd), IStakingP(POOL).minStakingDeposit() * 4);
    }

    /// @dev One activity, one Safe transaction, through the real router.
    function _createRestorationJob(address multisig) internal {
        bytes memory inner = abi.encodeWithSelector(
            bytes4(0x6baf28eb), // createRestorationJob(bytes,address,uint256,uint256,bytes32,bytes)
            bytes(hex"01"),
            address(0xBEEF), // priorityMech -- the marketplace call is mocked
            uint256(2), // maxDeliveryRate: protocol minimum
            uint256(3600),
            bytes32(0),
            bytes("")
        );
        ISafeTx safe = ISafeTx(multisig);
        uint256 n = safe.nonce();
        bytes32 h = safe.getTransactionHash(ROUTER, 0, inner, 0, 0, 0, 0, address(0), address(0), n);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, h);
        vm.prank(agentInstance);
        safe.execTransaction(ROUTER, 0, inner, 0, 0, 0, 0, address(0), payable(address(0)), abi.encodePacked(r, s, v));
    }

    function test_51c5_stakeActAndEarn() public {
        if (_skip()) return;
        _setUpFork();

        // ── stake ────────────────────────────────────────────────────────────────────────
        uint256 idBefore = IRegistryTS(SERVICE_REGISTRY).totalSupply();
        esd.stake(POOL, 0, AGENT_ID, CONFIG_HASH, agentInstance);
        uint256 serviceId = IRegistryTS(SERVICE_REGISTRY).totalSupply();
        assertEq(serviceId, idBefore + 1, "no service minted");
        (address multisig,,,,) = IStakingP(POOL).mapServiceInfo(serviceId);
        assertTrue(multisig != address(0), "no multisig");
        emit log_named_uint("staked serviceId", serviceId);

        // The marketplace is third-party plumbing at the far end of the router; mock only it.
        vm.mockCall(MECH_MARKETPLACE, abi.encodeWithSelector(bytes4(0xf6938b09)), abi.encode(bytes32(uint256(1))));

        uint256[] memory before = IJinnRouter(CHECKER_PROXY).getMultisigNonces(multisig);
        uint256 creationsBefore = IJinnRouter(ROUTER).creationCount(multisig);

        // ── act: 25 activities, one Safe transaction each ────────────────────────────────
        // The bar is livenessRatio * 86400 / 1e18 ~= 19.92, so 20 is the minimum for a 24h
        // epoch. 25 gives headroom for the checkpoint landing slightly late.
        for (uint256 i = 0; i < 25; ++i) {
            _createRestorationJob(multisig);
        }

        uint256[] memory afterN = IJinnRouter(CHECKER_PROXY).getMultisigNonces(multisig);
        emit log_named_uint("safe nonce delta ", afterN[0] - before[0]);
        emit log_named_uint("creation delta   ", afterN[1] - before[1]);
        assertEq(IJinnRouter(ROUTER).creationCount(multisig) - creationsBefore, 25, "creations not counted");
        assertEq(afterN[0] - before[0], 25, "safe nonce did not move 1:1");
        // The bound the whole pool hinges on.
        assertLe(afterN[1] - before[1], afterN[0] - before[0], "total must not exceed nonceDelta");

        // ── close the epoch and check we were paid ───────────────────────────────────────
        uint256 poolBefore = IStakingP(POOL).availableRewards();
        vm.warp(block.timestamp + IStakingP(POOL).livenessPeriod() + 1);
        IStakingP(POOL).checkpoint();

        (,,, uint256 reward,) = IStakingP(POOL).mapServiceInfo(serviceId);
        uint256 poolAfter = IStakingP(POOL).availableRewards();
        emit log_named_uint("reward credited (wei)", reward);
        emit log_named_uint("pool drained by (wei)", poolBefore - poolAfter);
        assertGt(reward, 0, "VALUE CAPTURE FAILED: epoch credited zero");
        assertGt(poolBefore, poolAfter, "pool did not pay out");
    }

    /// @dev The never-batch rule, proven rather than assumed: many activities behind a single
    /// Safe transaction trip `total > nonceDelta` and credit nothing.
    function test_51c5_batchingCreditsZero() public {
        if (_skip()) return;
        _setUpFork();
        address checker = IStakingP(POOL).activityChecker();
        uint256 lr = IJinnRouter(checker).livenessRatio();
        uint256 need = (lr * 86400) / 1e18 + 1;

        uint256[] memory last = new uint256[](5);
        uint256[] memory batched = new uint256[](5);
        batched[0] = 1; // one Safe transaction
        batched[1] = need; // many activities inside it
        (bool ok, bytes memory ret) = checker.staticcall(
            abi.encodeWithSignature("isRatioPass(uint256[],uint256[],uint256)", batched, last, uint256(86400))
        );
        assertTrue(ok, "isRatioPass reverted");
        assertFalse(abi.decode(ret, (bool)), "batched activity must not pass");

        uint256[] memory spread = new uint256[](5);
        spread[0] = need;
        spread[1] = need;
        (, ret) = checker.staticcall(
            abi.encodeWithSignature("isRatioPass(uint256[],uint256[],uint256)", spread, last, uint256(86400))
        );
        assertTrue(abi.decode(ret, (bool)), "one-per-transaction must pass");
        emit log_named_uint("activities required per service per day", need);
    }

    /// @dev Production readiness: does the LIVE deployed distributor stake, with no upgrade
    /// applied in the test? If this passes, the on-chain implementation really is the fixed one.
    function test_liveImplementation_canStake() public {
        if (_skip()) return;
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        agentInstance = vm.addr(agentPk);
        esd = ExternalStakingDistributor(payable(ESD_PROXY));

        emit log_named_address("safeMultisig    ", esd.safeMultisig());
        emit log_named_address("safeSetupHelper ", esd.safeSetupHelper());
        assertTrue(esd.safeMultisig() != address(0), "safeMultisig unset -- upgrade not applied");
        assertTrue(esd.safeSetupHelper() != address(0), "safeSetupHelper unset -- upgrade not applied");

        address esdOwner = esd.owner();
        vm.startPrank(esdOwner);
        address[] memory proxies = new address[](1);
        uint256[] memory configs = new uint256[](1);
        proxies[0] = POOL;
        configs[0] = esd.wrapStakingConfig(
            address(0),
            5000,
            0,
            5000,
            ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1,
            // openAccess=TRUE for the test, which stakes as this contract rather than as a
            // whitelisted curating agent. Since #20 a zero stakingGuard no longer implies open
            // access -- it must be stated -- so guard 0 + openAccess false now reverts
            // WrongStakingAccess. Production keeps openAccess FALSE and a real guard, with
            // agents allowlisted by 03_set_curating_agents.py.
            true
        );
        esd.setStakingProxyConfigs(proxies, configs);
        vm.stopPrank();

        deal(OLAS, address(esd), IStakingP(POOL).minStakingDeposit() * 4);
        uint256 idBefore = IRegistryTS(SERVICE_REGISTRY).totalSupply();
        esd.stake(POOL, 0, AGENT_ID, CONFIG_HASH, agentInstance);
        uint256 serviceId = IRegistryTS(SERVICE_REGISTRY).totalSupply();
        assertEq(serviceId, idBefore + 1, "live implementation did not create a service");
        (address multisig,,,,) = IStakingP(POOL).mapServiceInfo(serviceId);
        assertTrue(multisig != address(0), "no multisig");
        emit log_named_uint("staked serviceId (live impl)", serviceId);
        emit log_named_address("multisig", multisig);
    }

    /// @dev Is one activity enough for our FIRST epoch, given the pool has not checkpointed in
    /// 164 days? The tempting answer is yes: a service's bar is livenessRatio x
    /// (now - max(tsStart, tsCheckpoint)), and one activity covers 4,339 s.
    ///
    /// The catch is that stake() runs _checkpoint() internally, and the pool-level close is
    /// overdue, so our own stake settles the epoch and moves tsCheckpoint to the stake time.
    /// From then on the next settlement needs a further livenessPeriod. This test measures
    /// which of those actually governs, rather than arguing about it.
    function test_51c5_firstEpoch_howManyActivitiesAreNeeded() public {
        if (_skip()) return;
        _setUpFork();

        uint256 tsCpBefore = IStakingP2(POOL).tsCheckpoint();
        emit log_named_uint("tsCheckpoint before stake", tsCpBefore);

        esd.stake(POOL, 0, AGENT_ID, CONFIG_HASH, agentInstance);
        uint256 serviceId = IRegistryTS(SERVICE_REGISTRY).totalSupply();
        (address multisig,, uint256 tsStart,,) = IStakingP(POOL).mapServiceInfo(serviceId);

        uint256 tsCpAfter = IStakingP2(POOL).tsCheckpoint();
        emit log_named_uint("tsCheckpoint after stake ", tsCpAfter);
        emit log_named_uint("our tsStart              ", tsStart);
        if (tsCpAfter > tsCpBefore) {
            emit log("stake() DID checkpoint: the clock was reset to the stake time");
        }

        vm.mockCall(MECH_MARKETPLACE, abi.encodeWithSelector(bytes4(0xf6938b09)), abi.encode(bytes32(uint256(1))));

        // One activity, then try to close an hour later.
        _createRestorationJob(multisig);
        vm.warp(block.timestamp + 3600);
        IStakingP(POOL).checkpoint();
        (,,, uint256 rewardAt1h,) = IStakingP(POOL).mapServiceInfo(serviceId);
        emit log_named_uint("reward after 1 activity + 1h", rewardAt1h);

        // Now let a full liveness period pass with only that one activity.
        vm.warp(block.timestamp + IStakingP(POOL).livenessPeriod() + 1);
        IStakingP(POOL).checkpoint();
        (,,, uint256 rewardAt24h,) = IStakingP(POOL).mapServiceInfo(serviceId);
        emit log_named_uint("reward after 1 activity + 24h", rewardAt24h);

        if (rewardAt1h > 0) {
            emit log("VERDICT: one activity and a short hold is enough");
        } else if (rewardAt24h > 0) {
            emit log("VERDICT: the close is gated to 24h, but one activity still cleared the bar");
        } else {
            emit log("VERDICT: one activity is NOT enough -- the 24h bar applies, need ~20");
        }
    }

    /// @dev The whole same-day path with NO mocks: stake a seat, create our own mech from that
    /// service's own multisig, then send real createRestorationJob calls through the real
    /// router into the real Mech Marketplace, and close.
    ///
    /// The other tests mock the marketplace's `request`, which leaves open the question this
    /// one answers: can we go from nothing to earning without waiting on anybody? One mech is
    /// enough for every service we ever stake here, because this pool counts
    /// creationCount[requester] -- the mech is only the request target. That is unlike Gnosis
    /// 0xCAbD0C94, which counts deliveries BY each service's own mech and therefore needs one
    /// mech per service.
    function test_51c5_endToEnd_ownMech_noMocks() public {
        if (_skip()) return;
        _setUpFork();

        // 1. Stake a seat -- this also mints the service and its Safe.
        esd.stake(POOL, 0, AGENT_ID, CONFIG_HASH, agentInstance);
        uint256 serviceId = IRegistryTS(SERVICE_REGISTRY).totalSupply();
        (address multisig,,,,) = IStakingP(POOL).mapServiceInfo(serviceId);
        emit log_named_uint("serviceId", serviceId);
        emit log_named_address("multisig ", multisig);

        // 2. Create our own mech from that multisig, maxDeliveryRate = 2 wei (protocol minimum).
        bytes memory createData =
            abi.encodeWithSignature("create(uint256,address,bytes)", serviceId, MECH_FACTORY, abi.encode(uint256(2)));
        address mech = _safeExecCaptureMech(multisig, createData);
        emit log_named_address("our mech ", mech);
        assertTrue(mech != address(0), "mech not created");
        assertTrue(mech.code.length > 0, "mech has no code");

        // 3. Real activity through the real marketplace -- no vm.mockCall anywhere.
        uint256[] memory before = IJinnRouter(CHECKER_PROXY).getMultisigNonces(multisig);
        for (uint256 i = 0; i < 25; ++i) {
            _createRestorationJobWithMech(multisig, mech);
        }
        uint256[] memory afterN = IJinnRouter(CHECKER_PROXY).getMultisigNonces(multisig);
        emit log_named_uint("safe nonce delta", afterN[0] - before[0]);
        emit log_named_uint("creation delta  ", afterN[1] - before[1]);
        assertGe(afterN[1] - before[1], 20, "not enough creations credited");
        assertLe(afterN[1] - before[1], afterN[0] - before[0], "bound violated");

        // 4. Close and check we were paid.
        uint256 poolBefore = IStakingP(POOL).availableRewards();
        vm.warp(block.timestamp + IStakingP(POOL).livenessPeriod() + 1);
        IStakingP(POOL).checkpoint();
        (,,, uint256 reward,) = IStakingP(POOL).mapServiceInfo(serviceId);
        emit log_named_uint("reward credited (wei)", reward);
        assertGt(reward, 0, "VALUE CAPTURE FAILED: epoch credited zero");
        assertGt(poolBefore, IStakingP(POOL).availableRewards(), "pool did not pay");
    }

    /// @dev Run create() through the Safe and pull the mech address out of the emitted event.
    /// Re-calling create() from the test contract to read its return value does not work: the
    /// marketplace requires the caller to be the service multisig and reverts
    /// UnauthorizedAccount, which is what the first version of this test tripped over.
    function _safeExecCaptureMech(address multisig, bytes memory data) internal returns (address) {
        ISafeTx safe = ISafeTx(multisig);
        uint256 n = safe.nonce();
        bytes32 h = safe.getTransactionHash(MECH_MARKETPLACE, 0, data, 0, 0, 0, 0, address(0), address(0), n);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, h);

        vm.recordLogs();
        vm.prank(agentInstance);
        bool ok = safe.execTransaction(
            MECH_MARKETPLACE, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), abi.encodePacked(r, s, v)
        );
        assertTrue(ok, "Safe execTransaction of create() failed");

        // The mech is the first address-shaped topic/word logged by a contract that now has
        // code and was not there before; CreateMech carries it as the first indexed arg.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 1) {
                address cand = address(uint160(uint256(logs[i].topics[1])));
                if (cand != address(0) && cand.code.length > 0 && cand != multisig) {
                    return cand;
                }
            }
        }
        revert("mech address not found in logs");
    }

    function _createRestorationJobWithMech(address multisig, address mech) internal {
        bytes memory inner = abi.encodeWithSelector(
            bytes4(0x6baf28eb), bytes(hex"01"), mech, uint256(2), uint256(300), IMech(mech).paymentType(), bytes("")
        );
        ISafeTx safe = ISafeTx(multisig);
        uint256 n = safe.nonce();
        bytes32 h = safe.getTransactionHash(ROUTER, 2, inner, 0, 0, 0, 0, address(0), address(0), n);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, h);
        vm.deal(multisig, multisig.balance + 1 ether);
        vm.prank(agentInstance);
        safe.execTransaction(ROUTER, 2, inner, 0, 0, 0, 0, address(0), payable(address(0)), abi.encodePacked(r, s, v));
    }

    /// @dev A Safe with no native balance cannot do this pool's activity at all.
    ///
    /// createRestorationJob is payable and forwards maxDeliveryRate to the marketplace, so the
    /// SAFE parts with those wei -- not the agent instance that signs, and not the guard. The
    /// other tests here vm.deal the multisig, which quietly hid the requirement: the first live
    /// run sent 25 transactions, reverted every one, and credited zero.
    ///
    /// This pins the requirement so the suite can never hide it again.
    function test_51c5_safeWithNoBalanceCannotAct() public {
        if (_skip()) return;
        _setUpFork();

        esd.stake(POOL, 0, AGENT_ID, CONFIG_HASH, agentInstance);
        uint256 serviceId = IRegistryTS(SERVICE_REGISTRY).totalSupply();
        (address multisig,,,,) = IStakingP(POOL).mapServiceInfo(serviceId);

        bytes memory createData =
            abi.encodeWithSignature("create(uint256,address,bytes)", serviceId, MECH_FACTORY, abi.encode(uint256(2)));
        address mech = _safeExecCaptureMech(multisig, createData);

        // Explicitly leave the Safe empty.
        vm.deal(multisig, 0);
        assertEq(multisig.balance, 0, "precondition: Safe must be empty");

        uint256 before = IJinnRouter(CHECKER_PROXY).creationCount(multisig);

        bytes memory inner = abi.encodeWithSelector(
            bytes4(0x6baf28eb), bytes(hex"01"), mech, uint256(2), uint256(300), IMech(mech).paymentType(), bytes("")
        );
        ISafeTx safe = ISafeTx(multisig);
        uint256 n = safe.nonce();
        bytes32 h = safe.getTransactionHash(ROUTER, 2, inner, 0, 0, 0, 0, address(0), address(0), n);
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(agentPk, h);
        vm.prank(agentInstance);
        vm.expectRevert(); // GS013: the inner call cannot send value the Safe does not have
        safe.execTransaction(ROUTER, 2, inner, 0, 0, 0, 0, address(0), payable(address(0)), abi.encodePacked(r, sg, v));

        assertEq(IJinnRouter(CHECKER_PROXY).creationCount(multisig), before, "nothing should be credited");

        // One wei per request is all it takes -- the point is that it must be non-zero.
        vm.deal(multisig, 2);
        _createRestorationJobWithMech(multisig, mech);
        assertEq(IJinnRouter(CHECKER_PROXY).creationCount(multisig), before + 1, "funded Safe should credit");
        emit log("a Safe needs native for maxDeliveryRate; fund it before sending activity");
    }
}
