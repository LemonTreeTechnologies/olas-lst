// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

/// @dev Proves the NATIVE (StakingManager) retirement path on live state, and the per-call cap on it.
///
/// Distinct from the external path: capital staked through StakingManager is returned by
/// Depository.unstakeRetired, not unstakeExternal. unstakeRetired is permissionless but gated on the
/// staking model's status being Retired, which only owner can set.
///
///   [L1]     owner: setStakingModelStatuses(.., Retired)
///   [L1]     anyone: unstakeRetired(..)  -> amount = min(supply - remainder, stakeLimitPerSlot)
///   [Gnosis] AMB -> l2StakingProcessor -> StakingManager.unstake(proxy, amount, UNSTAKE_RETIRED)
///                                      -> Collector under UNSTAKE_RETIRED
///   [L1]     relay() -> stOLAS   (already covered by UnstakeExternalRetiredFork)
///
/// Live subject: model 0x22FA6310 on Gnosis holds 80 of 80 seats at 1,000 OLAS each = 80,000 OLAS,
/// with availableRewards == 0. Drained but still Active, so the deposits earn nothing.
///
/// Run: forge test --match-contract UnstakeRetiredNativeFork -vv
interface IDepositoryN {
    function owner() external view returns (address);
    function mapStakingModels(uint256 stakingModelId)
        external
        view
        returns (uint96 supply, uint96 remainder, uint96 stakeLimitPerSlot, uint8 status);
    function setStakingModelStatuses(
        uint256[] memory chainIds,
        address[] memory stakingProxies,
        uint8[] memory statuses
    ) external;
    function unstakeRetired(
        uint256[] memory chainIds,
        address[] memory stakingProxies,
        bytes[] memory bridgePayloads,
        uint256[] memory values
    ) external payable returns (uint256[] memory amounts);
}

interface IStakingManagerN {
    function unstake(address stakingProxy, uint256 amount, bytes32 operation) external;
    function l2StakingProcessor() external view returns (address);
    function collector() external view returns (address);
}

interface ICollectorN {
    function mapOperationReceiverBalances(bytes32 operation) external view returns (uint256, address);
}

interface IStakingProxyN {
    function getServiceIds() external view returns (uint256[] memory);
    function availableRewards() external view returns (uint256);
}

contract UnstakeRetiredNativeForkTest is Test {
    address internal constant DEPOSITORY = 0xEfF4A1D9faF5c750d5E32754c40Cf163767C63A4; // L1
    address internal constant STAKING_MANAGER = 0xEfF4A1D9faF5c750d5E32754c40Cf163767C63A4; // Gnosis
    address internal constant NATIVE_POOL = 0x22FA631064A99c43196ec5f8324b73211Ced98f9; // Gnosis
    bytes32 internal constant UNSTAKE_RETIRED = keccak256("UNSTAKE_RETIRED");
    uint256 internal constant GNOSIS = 100;
    uint8 internal constant STATUS_RETIRED = 0; // enum {Retired, Active, Inactive}
    uint8 internal constant STATUS_ACTIVE = 1;

    function _skip(string memory v) internal returns (bool) {
        try vm.envString(v) returns (string memory) {
            return false;
        } catch {
            console.log("SKIP: %s not set", v);
            return true;
        }
    }

    function _modelId(uint256 chainId, address proxy) internal pure returns (uint256 id) {
        id = uint256(uint160(proxy));
        id |= chainId << 160;
    }

    /// @dev L1: unstakeRetired is blocked while Active, works once owner retires it, and is capped per call.
    function test_L1_unstakeRetired_requiresRetired_andIsCappedPerSlot() public {
        if (_skip("ETHEREUM_RPC_URL")) return;
        vm.createSelectFork(vm.envString("ETHEREUM_RPC_URL"));

        IDepositoryN dep = IDepositoryN(DEPOSITORY);
        address owner = dep.owner();
        uint256 id = _modelId(GNOSIS, NATIVE_POOL);

        (uint96 supply, uint96 remainder, uint96 limit, uint8 status) = dep.mapStakingModels(id);
        emit log_named_uint("supply           (OLAS)", supply / 1e18);
        emit log_named_uint("remainder        (OLAS)", remainder / 1e18);
        emit log_named_uint("stakeLimitPerSlot(OLAS)", limit / 1e18);
        emit log_named_uint("status (0=Retired,1=Active)", status);
        assertEq(status, STATUS_ACTIVE, "model is expected Active on current state");
        assertGt(supply, 0, "model has no supply");

        uint256[] memory chainIds = new uint256[](1);
        address[] memory proxies = new address[](1);
        bytes[] memory payloads = new bytes[](1);
        uint256[] memory values = new uint256[](1);
        chainIds[0] = GNOSIS;
        proxies[0] = NATIVE_POOL;
        payloads[0] = "";
        values[0] = 0;

        // Active model: unstakeRetired must refuse it.
        vm.expectRevert();
        dep.unstakeRetired(chainIds, proxies, payloads, values);

        // Only owner may change status.
        uint8[] memory statuses = new uint8[](1);
        statuses[0] = STATUS_RETIRED;
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        dep.setStakingModelStatuses(chainIds, proxies, statuses);

        vm.prank(owner);
        dep.setStakingModelStatuses(chainIds, proxies, statuses);
        (,,, status) = dep.mapStakingModels(id);
        assertEq(status, STATUS_RETIRED, "status did not move to Retired");

        // Now permissionless, and capped at one slot per call.
        vm.prank(address(0xCAFE));
        uint256[] memory amounts = dep.unstakeRetired(chainIds, proxies, payloads, values);
        emit log_named_uint("amount returned 1st call (OLAS)", amounts[0] / 1e18);
        assertEq(amounts[0], limit, "first call should return exactly one slot");

        (, remainder,,) = dep.mapStakingModels(id);
        emit log_named_uint("remainder after 1 call   (OLAS)", remainder / 1e18);
        assertEq(remainder, limit, "remainder should advance by one slot");

        // A second call advances it again - so draining 80,000 needs 80 calls at 1,000 per slot.
        vm.prank(address(0xCAFE));
        uint256[] memory amounts2 = dep.unstakeRetired(chainIds, proxies, payloads, values);
        (, remainder,,) = dep.mapStakingModels(id);
        emit log_named_uint("remainder after 2 calls  (OLAS)", remainder / 1e18);
        assertEq(amounts2[0], limit, "second call should also return one slot");
        assertEq(remainder, uint96(uint256(limit) * 2), "remainder should be two slots");
        emit log_named_uint("calls needed to drain fully", uint256(supply) / uint256(limit));
    }

    /// @dev Gnosis: StakingManager.unstake credits the Collector under UNSTAKE_RETIRED and frees a seat.
    function test_Gnosis_stakingManager_unstake_creditsRetiredOperation() public {
        if (_skip("GNOSIS_RPC_URL")) return;
        vm.createSelectFork(vm.envString("GNOSIS_RPC_URL"));

        IStakingManagerN sm = IStakingManagerN(STAKING_MANAGER);
        address processor = sm.l2StakingProcessor();
        ICollectorN collector = ICollectorN(sm.collector());
        console.log("l2StakingProcessor:", processor);
        console.log("collector         :", address(collector));

        uint256 seatsBefore = IStakingProxyN(NATIVE_POOL).getServiceIds().length;
        emit log_named_uint("seats staked before", seatsBefore);
        emit log_named_uint("pool availableRewards (OLAS)", IStakingProxyN(NATIVE_POOL).availableRewards() / 1e18);
        assertGt(seatsBefore, 0, "native pool has no staked seats");

        (uint256 opBefore,) = collector.mapOperationReceiverBalances(UNSTAKE_RETIRED);

        // Only the processor may drive it.
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        sm.unstake(NATIVE_POOL, 1_000e18, UNSTAKE_RETIRED);

        // The AMB hop is simulated by impersonating the processor.
        vm.prank(processor);
        sm.unstake(NATIVE_POOL, 1_000e18, UNSTAKE_RETIRED);

        uint256 seatsAfter = IStakingProxyN(NATIVE_POOL).getServiceIds().length;
        (uint256 opAfter,) = collector.mapOperationReceiverBalances(UNSTAKE_RETIRED);
        emit log_named_uint("seats staked after", seatsAfter);
        emit log_named_uint("collector op balance before (OLAS)", opBefore / 1e18);
        emit log_named_uint("collector op balance after  (OLAS)", opAfter / 1e18);

        assertLt(seatsAfter, seatsBefore, "no seat was released");
        assertGt(opAfter, opBefore, "collector was not credited under UNSTAKE_RETIRED");
    }
}
