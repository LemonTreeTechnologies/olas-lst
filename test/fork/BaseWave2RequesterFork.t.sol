// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console, Vm} from "forge-std/Test.sol";
import {ExternalStakingDistributor} from "../../contracts/l2/ExternalStakingDistributor.sol";

/// @dev Proves, pool by pool, that we can stake AND be paid on the three wave-2 Base pools
/// before any capital moves. This is the step that was skipped before 0xCA61633b, where an
/// arithmetic-only probe said "payable" and the pool turned out to read activityNonce() on an
/// ActivityModule our path never creates -- 25,000 OLAS into a pool that credits nothing.
///
/// Each pool here is driven end to end on live state: stake through the deployed distributor,
/// send real Mech Marketplace requests through the service's own Safe, close the epoch with
/// the live permissionless checkpoint, and assert the reward is non-zero.
///
/// Run: forge test --match-contract BaseWave2RequesterFork -vv   (needs BASE_RPC_URL)
interface IStakingW {
    function availableRewards() external view returns (uint256);
    function rewardsPerSecond() external view returns (uint256);
    function getServiceIds() external view returns (uint256[] memory);
    function minStakingDeposit() external view returns (uint256);
    function livenessPeriod() external view returns (uint256);
    function activityChecker() external view returns (address);
    function checkpoint() external returns (uint256[] memory, uint256[] memory, uint256[] memory, uint256[] memory);
    function mapServiceInfo(uint256 id)
        external
        view
        returns (address multisig, address owner, uint256 tsStart, uint256 reward, uint256 inactivity);
}

interface ICheckW {
    function livenessRatio() external view returns (uint256);
    function getMultisigNonces(address) external view returns (uint256[] memory);
}

interface IMechW {
    function paymentType() external view returns (bytes32);
}

interface ISafeW {
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

interface IRegW {
    function totalSupply() external view returns (uint256);
}

contract BaseWave2RequesterForkTest is Test {
    address constant OLAS = 0x54330d28ca3357F294334BDC454a032e7f353416;
    address constant SERVICE_REGISTRY = 0x3C1fF68f5aa342D296d4DEe4Bb1cACCA912D95fE;
    address constant ESD_PROXY = 0x40abf47B926181148000DbCC7c8DE76A3a61a66f;
    address constant MECH_MARKETPLACE = 0xf24eE42edA0fc9b33B7D41B06Ee8ccD2Ef7C5020;
    address constant OUR_MECH = 0x0a53E3c8918cD0310e69885130693caB02e56cF3; // from service 646
    bytes32 constant CONFIG_HASH = 0xca0a2dda805c401808b21b8fdf86eb8b1b4117931cb6dbf8226c38dfd0214068;

    ExternalStakingDistributor internal esd;
    uint256 internal agentPk = 0xBEEF01;
    address internal agentInstance;

    function _skip() internal returns (bool) {
        try vm.envString("BASE_RPC_URL") returns (string memory) {
            return false;
        } catch {
            console.log("SKIP: BASE_RPC_URL not set");
            return true;
        }
    }

    function _prepare(address pool) internal {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        agentInstance = vm.addr(agentPk);
        esd = ExternalStakingDistributor(payable(ESD_PROXY));
        address owner = esd.owner();
        vm.startPrank(owner);
        address[] memory proxies = new address[](1);
        uint256[] memory configs = new uint256[](1);
        proxies[0] = pool;
        // openAccess true purely so the test can stake as itself; production uses the guard.
        configs[0] = esd.wrapStakingConfig(
            address(0), 1000, 0, 9000, ExternalStakingDistributor.StakingType.STAKING_TYPE_OLAS_V1, true
        );
        esd.setStakingProxyConfigs(proxies, configs);
        vm.stopPrank();
        deal(OLAS, address(esd), IStakingW(pool).minStakingDeposit() * 4);
        vm.deal(address(esd), 1 ether);
    }

    function _request(address ms) internal {
        bytes memory inner = abi.encodeWithSignature(
            "request(bytes,uint256,bytes32,address,uint256,bytes)",
            abi.encodePacked(keccak256(abi.encode(ms, ISafeW(ms).nonce(), block.timestamp))),
            uint256(2),
            IMechW(OUR_MECH).paymentType(),
            OUR_MECH,
            uint256(300),
            bytes("")
        );
        ISafeW safe = ISafeW(ms);
        uint256 n = safe.nonce();
        bytes32 h = safe.getTransactionHash(MECH_MARKETPLACE, 2, inner, 0, 0, 0, 0, address(0), address(0), n);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, h);
        vm.deal(ms, ms.balance + 1 ether);
        vm.prank(agentInstance);
        safe.execTransaction(
            MECH_MARKETPLACE, 2, inner, 0, 0, 0, 0, address(0), payable(address(0)), abi.encodePacked(r, s, v)
        );
    }

    function _run(address pool, uint256 agentId, string memory label) internal {
        _prepare(pool);
        uint256 before = IRegW(SERVICE_REGISTRY).totalSupply();
        esd.stake(pool, 0, agentId, CONFIG_HASH, agentInstance);
        uint256 sid = IRegW(SERVICE_REGISTRY).totalSupply();
        assertEq(sid, before + 1, "no service minted");
        (address ms,,,,) = IStakingW(pool).mapServiceInfo(sid);

        uint256 ratio = ICheckW(IStakingW(pool).activityChecker()).livenessRatio();
        // Size against the bar as it will stand AT THE CLOSE, not at 86400 exactly. The
        // checkpoint runs at livenessPeriod + 1, and isRatioPass compares
        // delta * 1e18 / ts >= livenessRatio, so a delta sized for 86400 is one short at
        // 86401. The first run of this test sent exactly 60 on a 60/day pool and credited
        // zero -- which looked like the pool being dead and was actually this off-by-one.
        // Production avoids it with calls_needed_for_window's ceil plus margin.
        uint256 need = (ratio * (86400 + 120)) / 1e18 + 2;

        uint256[] memory n0 = ICheckW(IStakingW(pool).activityChecker()).getMultisigNonces(ms);
        for (uint256 i = 0; i < need; ++i) {
            _request(ms);
        }
        uint256[] memory n1 = ICheckW(IStakingW(pool).activityChecker()).getMultisigNonces(ms);

        console.log(label);
        emit log_named_uint("  serviceId        ", sid);
        emit log_named_uint("  requests sent    ", need);
        emit log_named_uint("  nonce delta      ", n1[0] - n0[0]);
        if (n1.length > 1) emit log_named_uint("  work delta       ", n1[1] - n0[1]);

        uint256 potBefore = IStakingW(pool).availableRewards();
        vm.warp(block.timestamp + IStakingW(pool).livenessPeriod() + 1);
        IStakingW(pool).checkpoint();
        (,,, uint256 reward,) = IStakingW(pool).mapServiceInfo(sid);
        emit log_named_uint("  REWARD (wei)     ", reward);
        assertGt(reward, 0, "VALUE CAPTURE FAILED: this pool credits nothing");
        assertGt(potBefore, IStakingW(pool).availableRewards(), "pool did not pay out");
    }

    function test_0dfaFbf5_oneSeat() public {
        if (_skip()) return;
        _run(0x0dfaFbf570e9E813507aAE18aA08dFbA0aBc5139, 43, "0x0dfaFbf5");
    }

    function test_26FA75ef_oneSeat() public {
        if (_skip()) return;
        _run(0x26FA75ef9Ccaa60E58260226A71e9d07564C01bF, 43, "0x26FA75ef");
    }

    function test_BE6E1236_oneSeat() public {
        if (_skip()) return;
        // getAgentIds is empty here, so an explicit id is required.
        _run(0xBE6E12364B549622395999dB0dB53f163994D7AF, 43, "0xBE6E1236");
    }
}
