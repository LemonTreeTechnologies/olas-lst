// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console, Vm} from "forge-std/Test.sol";
import {ExternalStakingDistributor} from "../../contracts/l2/ExternalStakingDistributor.sol";
import {SafeSetupHelper} from "../../contracts/l2/SafeSetupHelper.sol";

/// @dev Green-light check for Base pool 0x66A9d66c before any capital moves.
///
/// This is a DELIVERY-side pool and behaves nothing like 0x51c5f498. Its checker reads
/// [safeNonce, mechDeliveryCount] and counts deliveries made by the service's OWN mech, so:
///
///   * every staked service needs its own mech (0x51c5f498 shares one across all of them);
///   * deliveries cannot be batched -- N ids in one Safe transaction move the delivery count
///     by N and the Safe nonce by 1, and the checker requires deliveryDelta <= nonceDelta, so
///     a batch credits ZERO;
///   * requests, by contrast, are minted in bulk from the instance EOA, whose transactions do
///     not consume a Safe nonce and therefore do not tighten the gate.
///
/// getAgentIds() is empty here, so an explicit agentId must be passed or stake() reverts.
///
/// Run: forge test --match-contract BaseB14CDeliveryFork -vv   (needs BASE_RPC_URL)
interface IStakingB {
    function availableRewards() external view returns (uint256);
    function rewardsPerSecond() external view returns (uint256);
    function getServiceIds() external view returns (uint256[] memory);
    function getAgentIds() external view returns (uint256[] memory);
    function minStakingDeposit() external view returns (uint256);
    function livenessPeriod() external view returns (uint256);
    function activityChecker() external view returns (address);
    function checkpoint() external returns (uint256[] memory, uint256[] memory, uint256[] memory, uint256[] memory);
    function mapServiceInfo(uint256 id)
        external
        view
        returns (address multisig, address owner, uint256 tsStart, uint256 reward, uint256 inactivity);
}

interface ICheckerB {
    function livenessRatio() external view returns (uint256);
    function getMultisigNonces(address) external view returns (uint256[] memory);
    function isRatioPass(uint256[] memory, uint256[] memory, uint256) external view returns (bool);
}

interface IMarketB {
    function requestBatch(
        bytes[] memory requestDatas,
        uint256 maxDeliveryRate,
        bytes32 paymentType,
        address priorityMech,
        uint256 responseTimeout,
        bytes memory paymentData
    ) external payable returns (bytes32[] memory);
    function mapMechServiceDeliveryCounts(address) external view returns (uint256);
    function create(uint256 serviceId, address mechFactory, bytes memory payload) external returns (address);
}

interface IMechB {
    function paymentType() external view returns (bytes32);
    function deliverToMarketplace(bytes32[] memory requestIds, bytes[] memory datas) external;
}

interface ISafeB {
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

interface IJinnRouterLike {
    function getMultisigNonces(address) external view returns (uint256[] memory);
}

interface IRegB {
    function totalSupply() external view returns (uint256);
}

contract Base66A9UnpayableForkTest is Test {
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
    address constant MECH_MARKETPLACE = 0xf24eE42edA0fc9b33B7D41B06Ee8ccD2Ef7C5020;
    address constant MECH_FACTORY = 0x2E008211f34b25A7d7c102403c6C2C3B665a1abe;
    bytes32 constant CONFIG_HASH = 0xca0a2dda805c401808b21b8fdf86eb8b1b4117931cb6dbf8226c38dfd0214068;

    address constant POOL = 0x66A92CDa5B319DCCcAC6c1cECbb690CA3Fb59488;
    uint256 constant AGENT_ID = 103;

    ExternalStakingDistributor internal esd;
    uint256 internal agentPk = 0x66A9;
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
        esd = ExternalStakingDistributor(payable(ESD_PROXY));
        address owner = esd.owner();
        vm.startPrank(owner);
        address[] memory proxies = new address[](1);
        uint256[] memory configs = new uint256[](1);
        proxies[0] = POOL;
        // openAccess TRUE: the test stakes as itself, not as an allowlisted curating agent.
        configs[0] = esd.wrapStakingConfig(
            address(0), 500, 1000, 8500, ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1, true
        );
        esd.setStakingProxyConfigs(proxies, configs);
        vm.stopPrank();
        deal(OLAS, address(esd), IStakingB(POOL).minStakingDeposit() * 4);
        vm.deal(address(esd), 1 ether);
    }

    function _safeExec(address ms, address to, uint256 value, bytes memory data) internal {
        ISafeB safe = ISafeB(ms);
        uint256 n = safe.nonce();
        bytes32 h = safe.getTransactionHash(to, value, data, 0, 0, 0, 0, address(0), address(0), n);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, h);
        vm.prank(agentInstance);
        bool ok = safe.execTransaction(
            to, value, data, 0, 0, 0, 0, address(0), payable(address(0)), abi.encodePacked(r, s, v)
        );
        assertTrue(ok, "Safe execTransaction failed");
    }

    function test_66A9_creditsZeroDespiteRealDeliveries() public {
        if (_skip()) return;
        _setUpFork();

        // getAgentIds() is empty, so agentId 0 cannot be derived and must be supplied.
        // 66A9 exposes agentIds, unlike B14C; an explicit id is passed either way.

        uint256 idBefore = IRegB(SERVICE_REGISTRY).totalSupply();
        esd.stake(POOL, 0, AGENT_ID, CONFIG_HASH, agentInstance);
        uint256 sid = IRegB(SERVICE_REGISTRY).totalSupply();
        assertEq(sid, idBefore + 1, "no service minted");
        (address ms,,,,) = IStakingB(POOL).mapServiceInfo(sid);
        emit log_named_uint("serviceId", sid);
        emit log_named_address("multisig ", ms);

        // Each service needs its OWN mech on a delivery-side pool.
        vm.recordLogs();
        _safeExec(
            ms,
            MECH_MARKETPLACE,
            0,
            abi.encodeWithSignature("create(uint256,address,bytes)", sid, MECH_FACTORY, abi.encode(uint256(2)))
        );
        // Take the mech from the event the MARKETPLACE itself emitted. An earlier version
        // scanned every log for an address-shaped topic and picked up the MultisigGuard.
        address mech;
        Vm.Log[] memory lg = vm.getRecordedLogs();
        for (uint256 i = 0; i < lg.length; ++i) {
            if (lg[i].emitter == MECH_MARKETPLACE && lg[i].topics.length > 1) {
                address c = address(uint160(uint256(lg[i].topics[1])));
                if (c != address(0) && c.code.length > 0) mech = c;
            }
        }
        assertTrue(mech != address(0), "mech not created");
        emit log_named_address("our mech ", mech);

        uint256 ratio = ICheckerB(IStakingB(POOL).activityChecker()).livenessRatio();
        uint256 need = (ratio * 86400) / 1e18 + 1;
        emit log_named_uint("deliveries needed for a 24h close", need);

        // Requests in BULK from the instance EOA (no Safe nonce consumed).
        vm.deal(agentInstance, 1 ether);
        bytes[] memory datas = new bytes[](need);
        for (uint256 i = 0; i < need; ++i) {
            datas[i] = abi.encodePacked(bytes32(uint256(i + 1)));
        }
        vm.prank(agentInstance);
        bytes32[] memory ids = IMarketB(MECH_MARKETPLACE).requestBatch{value: 2 * need}(
            datas, 2, IMechB(mech).paymentType(), mech, 300, ""
        );
        emit log_named_uint("requests minted in one tx", ids.length);

        // Deliveries ONE PER SAFE TRANSACTION.
        uint256 before = IMarketB(MECH_MARKETPLACE).mapMechServiceDeliveryCounts(ms);
        vm.deal(ms, 1 ether);
        for (uint256 i = 0; i < ids.length; ++i) {
            bytes32[] memory one = new bytes32[](1);
            bytes[] memory payload = new bytes[](1);
            one[0] = ids[i];
            payload[0] = hex"01";
            _safeExec(ms, mech, 0, abi.encodeWithSelector(IMechB.deliverToMarketplace.selector, one, payload));
        }
        uint256 delivered = IMarketB(MECH_MARKETPLACE).mapMechServiceDeliveryCounts(ms) - before;
        emit log_named_uint("deliveries credited", delivered);
        assertGe(delivered, need, "not enough deliveries credited");

        // The marketplace credited every delivery, but the POOL'S checker still reads zero on
        // index 1. Its getMultisigNonces returns [safeNonce, X] where X comes from two
        // selectors -- 0x43000819 and 0x7d3cd146 -- that REVERT on the live marketplace
        // 0xf24eE42e. The checker swallows that and yields 0, so isRatioPass is handed
        // [61, 0] and can never pass however much work we do.
        uint256[] memory chk = IJinnRouterLike(IStakingB(POOL).activityChecker()).getMultisigNonces(ms);
        emit log_named_uint("marketplace delivery count", delivered);
        emit log_named_uint("checker index 1           ", chk[1]);
        assertEq(chk[1], 0, "index 1 unexpectedly moved -- re-verify, this pool may be usable now");

        // Close and check payment.
        uint256 poolBefore = IStakingB(POOL).availableRewards();
        vm.warp(block.timestamp + IStakingB(POOL).livenessPeriod() + 1);
        IStakingB(POOL).checkpoint();
        (,,, uint256 reward,) = IStakingB(POOL).mapServiceInfo(sid);
        emit log_named_uint("reward credited (wei)", reward);
        assertEq(reward, 0, "pool paid -- the blocker is gone, re-verify before excluding it");
        assertEq(poolBefore, IStakingB(POOL).availableRewards(), "pool paid out unexpectedly");
        emit log("0x66A92CDa credits ZERO for 60 real deliveries: excluded from the Base plan");
    }
}
