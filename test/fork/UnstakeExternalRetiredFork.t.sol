// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

/// @dev Proves the UNSTAKE_RETIRED capital-return path against live mainnet state.
///
/// The flow spans TWO chains and two AMB hops, so it cannot be proven end-to-end in a single fork:
///
///   [L1]     Depository.unstakeExternal(owner)  -> deposit processor -> AMB
///   [Gnosis] AMB -> l2StakingProcessor -> ExternalStakingDistributor.withdrawAndRequestUnstake
///                                      -> Collector.topUpBalance(amount, UNSTAKE_RETIRED)
///   [Gnosis] Collector.relayTokens(UNSTAKE_RETIRED) -> AMB
///   [L1]     AMB -> UnstakeRelayer -> relay() -> stOLAS.topUpRetiredBalance
///
/// What these tests DO prove, on real state:
///   * only the Depository owner can reach UNSTAKE_RETIRED, and treasury reaches UNSTAKE instead;
///   * unstakeExternal debits mapChainIdStakedExternals and emits the cross-chain request;
///   * on Gnosis, the distributor moves OLAS to the Collector under the UNSTAKE_RETIRED operation;
///   * relayTokens zeroes that operation balance and hands it to the bridge;
///   * on L1, UnstakeRelayer.relay() moves its full OLAS balance into stOLAS, shifting stOLAS
///     stakedBalance -> reserveBalance by exactly that amount.
///
/// What they do NOT prove: the AMB actually delivering either message. That needs validator
/// signatures, which is precisely the failure mode that has one 726.60 OLAS withdrawal stuck
/// since 2026-07-20. Both hops are therefore simulated by impersonating the receiving endpoint.
///
/// Run: forge test --match-contract UnstakeExternalRetiredFork -vv
/// Needs ETHEREUM_RPC_URL and GNOSIS_RPC_URL; skips itself when they are absent so CI stays green.
interface IDepository {
    function owner() external view returns (address);
    function treasury() external view returns (address);
    function mapChainIdStakedExternals(uint256 chainId) external view returns (uint256);
    function unstakeExternal(
        uint256[] memory chainIds,
        uint256[] memory amounts,
        bytes[] memory bridgePayloads,
        uint256[] memory values,
        address sender
    ) external payable;
}

interface IExternalStakingDistributor {
    function withdrawAndRequestUnstake(uint256 amount, bytes32 operation) external;
    function l2StakingProcessor() external view returns (address);
    function collector() external view returns (address);
    function stakedBalance() external view returns (uint256);
    function mapUnstakeOperationRequestedAmounts(bytes32 operation) external view returns (uint256);
}

interface ICollector {
    function mapOperationReceiverBalances(bytes32 operation) external view returns (uint256, address);
    function relayTokens(bytes32 operation, bytes memory bridgePayload) external payable;
}

interface IUnstakeRelayer {
    function relay() external;
    function st() external view returns (address);
}

interface IStOLAS {
    function stakedBalance() external view returns (uint256);
    function reserveBalance() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function unstakeRelayer() external view returns (address);
}

interface IERC20F {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract UnstakeExternalRetiredForkTest is Test {
    // L1
    address internal constant DEPOSITORY = 0xEfF4A1D9faF5c750d5E32754c40Cf163767C63A4;
    address internal constant UNSTAKE_RELAYER = 0xaC7eA9478E0e1186E7D1c82b8d8dc80AEe0F79F6;
    address internal constant ST_OLAS = 0xab4C5BB0797Ca25e93a4af2E8FECD7Fcac0F2c9b;
    address internal constant OLAS_L1 = 0x0001A500A6B18995B03f44bb040A5fFc28E45CB0;
    // Gnosis
    address internal constant DISTRIBUTOR_GNOSIS = 0x7E8C636FBD0D9085C112680d8C3fde701452dcb5;
    address internal constant OLAS_GNOSIS = 0xcE11e14225575945b8E6Dc0D4F2dD4C570f79d9f;

    bytes32 internal constant UNSTAKE_RETIRED = keccak256("UNSTAKE_RETIRED");
    uint256 internal constant GNOSIS_CHAIN_ID = 100;

    function _skip(string memory varName) internal returns (bool) {
        try vm.envString(varName) returns (string memory) {
            return false;
        } catch {
            console.log("SKIP: %s not set", varName);
            return true;
        }
    }

    /// @dev L1 leg 1: only the owner reaches UNSTAKE_RETIRED, and the request is booked.
    function test_L1_unstakeExternal_ownerOnly_booksRequest() public {
        if (_skip("ETHEREUM_RPC_URL")) return;
        vm.createSelectFork(vm.envString("ETHEREUM_RPC_URL"));

        IDepository dep = IDepository(DEPOSITORY);
        address owner = dep.owner();
        address treasury = dep.treasury();
        console.log("Depository owner   :", owner);
        console.log("Depository treasury:", treasury);

        uint256 packed = dep.mapChainIdStakedExternals(GNOSIS_CHAIN_ID);
        uint256 stakedExternalBefore = packed >> 160;
        address distributor = address(uint160(packed));
        console.log("Gnosis distributor :", distributor);
        emit log_named_uint("unstakeable before (OLAS)", stakedExternalBefore / 1e18);
        assertEq(distributor, DISTRIBUTOR_GNOSIS, "distributor mismatch");
        assertGt(stakedExternalBefore, 0, "nothing registered to unstake");

        uint256[] memory chainIds = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        uint256[] memory values = new uint256[](1);
        chainIds[0] = GNOSIS_CHAIN_ID;
        amounts[0] = 1_000e18;
        payloads[0] = "";
        values[0] = 0;

        // A random caller must be rejected outright.
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        dep.unstakeExternal(chainIds, amounts, payloads, values, address(0));

        // Owner call succeeds and debits the per-chain allowance.
        vm.prank(owner);
        dep.unstakeExternal(chainIds, amounts, payloads, values, address(0));

        uint256 stakedExternalAfter = dep.mapChainIdStakedExternals(GNOSIS_CHAIN_ID) >> 160;
        emit log_named_uint("unstakeable after  (OLAS)", stakedExternalAfter / 1e18);
        emit log_named_uint("debited            (OLAS)", (stakedExternalBefore - stakedExternalAfter) / 1e18);
        assertEq(stakedExternalBefore - stakedExternalAfter, amounts[0], "allowance not debited by amount");
    }

    /// @dev Gnosis leg: distributor -> Collector under UNSTAKE_RETIRED, then relayTokens drains it.
    function test_Gnosis_withdrawRequest_movesOlasToCollectorUnderRetiredOp() public {
        if (_skip("GNOSIS_RPC_URL")) return;
        vm.createSelectFork(vm.envString("GNOSIS_RPC_URL"));

        IExternalStakingDistributor dist = IExternalStakingDistributor(DISTRIBUTOR_GNOSIS);
        address processor = dist.l2StakingProcessor();
        ICollector collector = ICollector(dist.collector());
        console.log("l2StakingProcessor :", processor);
        console.log("collector          :", address(collector));

        uint256 distFree = IERC20F(OLAS_GNOSIS).balanceOf(DISTRIBUTOR_GNOSIS);
        emit log_named_uint("distributor free   (OLAS)", distFree / 1e18);
        assertGt(distFree, 1_000e18, "distributor has no free OLAS to withdraw");

        (uint256 opBalBefore, address receiver) = collector.mapOperationReceiverBalances(UNSTAKE_RETIRED);
        console.log("UNSTAKE_RETIRED receiver:", receiver);
        assertTrue(receiver != address(0), "no receiver configured for UNSTAKE_RETIRED");

        uint256 amount = 1_000e18;

        // Anyone other than the processor is rejected.
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        dist.withdrawAndRequestUnstake(amount, UNSTAKE_RETIRED);

        // The AMB hop is simulated here: impersonate the processor the bridge would call.
        vm.prank(processor);
        dist.withdrawAndRequestUnstake(amount, UNSTAKE_RETIRED);

        (uint256 opBalAfter,) = collector.mapOperationReceiverBalances(UNSTAKE_RETIRED);
        emit log_named_uint("op balance before  (OLAS)", opBalBefore / 1e18);
        emit log_named_uint("op balance after   (OLAS)", opBalAfter / 1e18);
        assertEq(opBalAfter - opBalBefore, amount, "collector did not credit the retired operation");
        assertEq(distFree - IERC20F(OLAS_GNOSIS).balanceOf(DISTRIBUTOR_GNOSIS), amount, "distributor OLAS not debited");
        assertEq(dist.mapUnstakeOperationRequestedAmounts(UNSTAKE_RETIRED), 0, "should be fully covered by free OLAS");

        // relayTokens is permissionless and zeroes the operation balance as it hands off to the bridge.
        vm.deal(address(0xCAFE), 1 ether);
        vm.prank(address(0xCAFE));
        collector.relayTokens{value: 0}(UNSTAKE_RETIRED, "");
        (uint256 opBalRelayed,) = collector.mapOperationReceiverBalances(UNSTAKE_RETIRED);
        emit log_named_uint("op balance post-relay(OLAS)", opBalRelayed / 1e18);
        assertEq(opBalRelayed, 0, "relayTokens did not clear the operation balance");
    }

    /// @dev L1 leg 2: UnstakeRelayer -> stOLAS, shifting stakedBalance into reserveBalance.
    function test_L1_unstakeRelayer_relay_feedsStOlas() public {
        if (_skip("ETHEREUM_RPC_URL")) return;
        vm.createSelectFork(vm.envString("ETHEREUM_RPC_URL"));

        IStOLAS st = IStOLAS(ST_OLAS);
        assertEq(st.unstakeRelayer(), UNSTAKE_RELAYER, "stOLAS points at a different relayer");
        assertEq(IUnstakeRelayer(UNSTAKE_RELAYER).st(), ST_OLAS, "relayer points at a different stOLAS");

        uint256 amount = 1_000e18;
        // Simulate the second AMB hop: the bridge crediting OLAS to the relayer on L1.
        deal(OLAS_L1, UNSTAKE_RELAYER, IERC20F(OLAS_L1).balanceOf(UNSTAKE_RELAYER) + amount);

        uint256 stakedBefore = st.stakedBalance();
        uint256 reserveBefore = st.reserveBalance();
        uint256 stOlasOlasBefore = IERC20F(OLAS_L1).balanceOf(ST_OLAS);
        emit log_named_uint("stOLAS staked  before(OLAS)", stakedBefore / 1e18);
        emit log_named_uint("stOLAS reserve before(OLAS)", reserveBefore / 1e18);

        // Permissionless.
        vm.prank(address(0xCAFE));
        IUnstakeRelayer(UNSTAKE_RELAYER).relay();

        uint256 stakedAfter = st.stakedBalance();
        uint256 reserveAfter = st.reserveBalance();
        emit log_named_uint("stOLAS staked  after (OLAS)", stakedAfter / 1e18);
        emit log_named_uint("stOLAS reserve after (OLAS)", reserveAfter / 1e18);

        assertEq(reserveAfter - reserveBefore, amount, "reserveBalance did not rise by the relayed amount");
        assertEq(IERC20F(OLAS_L1).balanceOf(ST_OLAS) - stOlasOlasBefore, amount, "stOLAS did not receive the OLAS");
        assertEq(IERC20F(OLAS_L1).balanceOf(UNSTAKE_RELAYER), 0, "relayer should be emptied");
        if (stakedBefore >= amount) {
            assertEq(stakedBefore - stakedAfter, amount, "stakedBalance did not fall by the relayed amount");
        }
    }
}
