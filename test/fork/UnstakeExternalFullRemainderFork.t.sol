// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

/// @dev Verifies the EXACT calldata bytes handed to the owner multisig for the full remainder,
/// rather than a re-encoding of the same intent. The hex below is what gets pasted into the Safe,
/// so the test executes those bytes verbatim via a raw `call` and checks what they actually do.
///
/// Companion to UnstakeExternalRetiredFork.t.sol, which proves the whole two-hop path with a
/// 1,000 OLAS sample. This one is narrow: the bytes are right, and the L2 side can absorb the
/// full size without leaving a queued remainder.
///
/// Run: forge test --match-contract UnstakeExternalFullRemainderFork -vv
/// Needs ETHEREUM_RPC_URL and GNOSIS_RPC_URL; skips itself when they are absent.
interface IDep {
    function owner() external view returns (address);
    function mapChainIdStakedExternals(uint256 chainId) external view returns (uint256);
    function unstakeExternal(
        uint256[] memory chainIds,
        uint256[] memory amounts,
        bytes[] memory bridgePayloads,
        uint256[] memory values,
        address sender
    ) external payable;
}

interface IDistributor {
    function withdrawAndRequestUnstake(uint256 amount, bytes32 operation) external;
    function l2StakingProcessor() external view returns (address);
    function collector() external view returns (address);
    function mapUnstakeOperationRequestedAmounts(bytes32 operation) external view returns (uint256);
}

interface ICollectorF {
    function mapOperationReceiverBalances(bytes32 operation) external view returns (uint256, address);
}

interface IERC20B {
    function balanceOf(address) external view returns (uint256);
}

contract UnstakeExternalFullRemainderForkTest is Test {
    address internal constant DEPOSITORY = 0xEfF4A1D9faF5c750d5E32754c40Cf163767C63A4;
    address internal constant OWNER_SAFE = 0x52A1326BFbf7B2c22c7b893092FF25ceb29a780F;
    address internal constant DISTRIBUTOR_GNOSIS = 0x7E8C636FBD0D9085C112680d8C3fde701452dcb5;
    address internal constant OLAS_GNOSIS = 0xcE11e14225575945b8E6Dc0D4F2dD4C570f79d9f;

    bytes32 internal constant UNSTAKE_RETIRED = keccak256("UNSTAKE_RETIRED");
    uint256 internal constant GNOSIS_CHAIN_ID = 100;
    uint256 internal constant AMOUNT = 1_675_000e18;

    /// @dev The literal bytes destined for the Safe.
    bytes internal constant CALLDATA_1675K = hex"3c3a98dd"
        hex"00000000000000000000000000000000000000000000000000000000000000a0"
        hex"00000000000000000000000000000000000000000000000000000000000000e0"
        hex"0000000000000000000000000000000000000000000000000000000000000120"
        hex"0000000000000000000000000000000000000000000000000000000000000180"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"0000000000000000000000000000000000000000000000000000000000000064"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"0000000000000000000000000000000000000000000162b1ee93fda7a0e00000"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"0000000000000000000000000000000000000000000000000000000000000020"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"0000000000000000000000000000000000000000000000000000000000000000";

    function _skip(string memory varName) internal returns (bool) {
        try vm.envString(varName) returns (string memory) {
            return false;
        } catch {
            console.log("SKIP: %s not set", varName);
            return true;
        }
    }

    /// @dev The hex equals an abi encoding of exactly the intended arguments — no hidden field.
    function test_calldata_decodesToIntendedArguments() public {
        uint256[] memory chainIds = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        uint256[] memory values = new uint256[](1);
        chainIds[0] = GNOSIS_CHAIN_ID;
        amounts[0] = AMOUNT;
        payloads[0] = "";
        values[0] = 0;

        bytes memory expected =
            abi.encodeWithSelector(IDep.unstakeExternal.selector, chainIds, amounts, payloads, values, address(0));
        assertEq(keccak256(CALLDATA_1675K), keccak256(expected), "calldata is not the intended call");
        assertEq(CALLDATA_1675K.length, 452, "unexpected calldata length");
    }

    /// @dev Executing those exact bytes from the Safe debits the allowance by exactly 1,675,000.
    function test_L1_rawCalldata_fromSafe_debitsAllowance() public {
        if (_skip("ETHEREUM_RPC_URL")) return;
        vm.createSelectFork(vm.envString("ETHEREUM_RPC_URL"));

        IDep dep = IDep(DEPOSITORY);
        assertEq(dep.owner(), OWNER_SAFE, "OWNER_SAFE is not the Depository owner");

        uint256 packed = dep.mapChainIdStakedExternals(GNOSIS_CHAIN_ID);
        uint256 before = packed >> 160;
        assertEq(address(uint160(packed)), DISTRIBUTOR_GNOSIS, "distributor mismatch");
        emit log_named_uint("allowance before (OLAS)", before / 1e18);
        assertGe(before, AMOUNT, "allowance too small for the full remainder");

        // Anyone other than owner/treasury is rejected on the same bytes.
        vm.prank(address(0xBEEF));
        (bool okBad,) = DEPOSITORY.call(CALLDATA_1675K);
        assertFalse(okBad, "non-owner call should revert");

        vm.prank(OWNER_SAFE);
        (bool ok,) = DEPOSITORY.call(CALLDATA_1675K);
        assertTrue(ok, "owner call reverted");

        uint256 remaining = dep.mapChainIdStakedExternals(GNOSIS_CHAIN_ID) >> 160;
        emit log_named_uint("allowance after  (OLAS)", remaining / 1e18);
        assertEq(before - remaining, AMOUNT, "allowance did not debit by exactly the amount");
    }

    /// @dev The L2 side can absorb the full size out of free balance: nothing is left queued
    /// pending future unstakes, and the whole amount lands on the Collector under UNSTAKE_RETIRED.
    function test_L2_fullRemainder_leavesNoQueue() public {
        if (_skip("GNOSIS_RPC_URL")) return;
        vm.createSelectFork(vm.envString("GNOSIS_RPC_URL"));

        IDistributor dist = IDistributor(DISTRIBUTOR_GNOSIS);
        address collector = dist.collector();
        uint256 free = IERC20B(OLAS_GNOSIS).balanceOf(DISTRIBUTOR_GNOSIS);
        emit log_named_uint("distributor free OLAS", free / 1e18);
        assertGe(free, AMOUNT, "free balance below the requested amount");

        (uint256 collBefore,) = ICollectorF(collector).mapOperationReceiverBalances(UNSTAKE_RETIRED);
        uint256 queueBefore = dist.mapUnstakeOperationRequestedAmounts(UNSTAKE_RETIRED);

        vm.prank(dist.l2StakingProcessor());
        dist.withdrawAndRequestUnstake(AMOUNT, UNSTAKE_RETIRED);

        (uint256 collAfter,) = ICollectorF(collector).mapOperationReceiverBalances(UNSTAKE_RETIRED);
        uint256 queueAfter = dist.mapUnstakeOperationRequestedAmounts(UNSTAKE_RETIRED);

        emit log_named_uint("collector UNSTAKE_RETIRED (OLAS)", collAfter / 1e18);
        emit log_named_uint("still queued              (OLAS)", queueAfter / 1e18);
        assertEq(collAfter - collBefore, AMOUNT, "collector did not receive the full amount");
        assertEq(queueAfter, queueBefore, "a remainder was queued");
        assertEq(IERC20B(OLAS_GNOSIS).balanceOf(DISTRIBUTOR_GNOSIS), free - AMOUNT, "wrong OLAS moved");
    }
}
