// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

import {MultisigGuard} from "../../contracts/l2/MultisigGuard.sol";

interface ISafeLive {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function isModuleEnabled(address module) external view returns (bool);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
    function nonce() external view returns (uint256);
    function approveHash(bytes32 hashToApprove) external;
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

interface IProxyLive {
    function changeImplementation(address newImplementation) external;
}

interface IEsdLive {
    function unstakeAndWithdraw(address stakingProxy, uint256 serviceId, bytes32 operation) external;
    function mapMultisigServiceIds(address multisig) external view returns (uint256);
}

interface ITokenLive {
    function balanceOf(address account) external view returns (uint256);
}

/// @dev The module set constraint against live Base state.
///
/// The local harness builds its own Safes and registries, so it cannot show that the constraint holds for the
/// service multisigs that are actually live, nor that it leaves them usable. Both matter: every live external
/// staking seat is a Safe whose sole owner is a third party, so the constraint is what stands between that owner
/// and a deposit that can never be returned; and if the expected module set did not match what those Safes
/// really carry, the upgrade would instead block their owner transactions and stall the services.
///
/// The guard is a proxy shared by every service multisig on the chain, so a single changeImplementation applies
/// to all of them at once, which is what this test performs before each assertion.
///
/// Requires a Base RPC. Set BASE_RPC_URL to run; the suite skips itself otherwise so that CI stays green.
contract MultisigGuardModuleSetForkTest is Test {
    // Live Base deployment
    address internal constant GUARD_PROXY = 0x4D3911420a8E4E7dB8c979f4915dA8983C5e3ba2;
    address internal constant GUARD_OWNER = 0x40c0392c23fAfa216C69Bc291AFcb1b3F4abd49b;
    address internal constant ESD = 0x40abf47B926181148000DbCC7c8DE76A3a61a66f;
    address internal constant ESD_OWNER = 0x40c0392c23fAfa216C69Bc291AFcb1b3F4abd49b;
    address internal constant RECOVERY_MODULE = 0x359d53C326388D24037b3b1590d217fdb5EEE74c;
    address internal constant SERVICE_REGISTRY_TOKEN_UTILITY = 0x34C895f302D0b5cf52ec0Edd3945321EB0f83dd5;
    address internal constant OLAS = 0x54330d28ca3357F294334BDC454a032e7f353416;

    // A live external staking seat: its pool, its Safe, and the third party that solely owns that Safe
    uint256 internal constant SERVICE_ID = 646;
    address internal constant STAKING_PROXY = 0x51c5f4982B9b0B3c0482678f5847EA6228Cc8E54;
    address internal constant SERVICE_MULTISIG = 0xc9B8fb012b4EdF3f85773482E44BD63FC91a9A8a;
    address internal constant SAFE_OWNER = 0x5fFD757545E4600f9f0302d36d0393196cE30C9D;

    address internal constant SENTINEL_MODULES = address(0x1);

    // The seat's deposit: the pool's minStakingDeposit of 5000 OLAS, for the service and one agent instance
    uint256 internal constant FULL_STAKING_DEPOSIT = 10_000 ether;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console.log("BASE_RPC_URL is not set, skipping Base fork tests");
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;
    }

    /// @dev Upgrades the live guard proxy to the implementation built from this source tree.
    function _upgradeGuard() internal {
        MultisigGuard implementation = new MultisigGuard(SERVICE_REGISTRY_TOKEN_UTILITY, ESD, OLAS);
        vm.prank(GUARD_OWNER);
        IProxyLive(GUARD_PROXY).changeImplementation(address(implementation));
    }

    /// @dev Executes a Safe transaction as the sole owner, via an on-chain approved hash.
    function _execAsOwner(bytes memory data, uint8 operation) internal returns (bool) {
        bytes32 txHash = ISafeLive(SERVICE_MULTISIG)
            .getTransactionHash(
                SERVICE_MULTISIG,
                0,
                data,
                operation,
                0,
                0,
                0,
                address(0),
                address(0),
                ISafeLive(SERVICE_MULTISIG).nonce()
            );

        vm.prank(SAFE_OWNER);
        ISafeLive(SERVICE_MULTISIG).approveHash(txHash);

        vm.prank(SAFE_OWNER);
        (bool ok,) = SERVICE_MULTISIG.call(
            abi.encodeWithSignature(
                "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                SERVICE_MULTISIG,
                uint256(0),
                data,
                operation,
                uint256(0),
                uint256(0),
                uint256(0),
                address(0),
                address(0),
                abi.encodePacked(bytes32(uint256(uint160(SAFE_OWNER))), bytes32(0), uint8(1))
            )
        );
        return ok;
    }

    function _prevOfModule(address module) internal view returns (address prev) {
        (address[] memory arr,) = ISafeLive(SERVICE_MULTISIG).getModulesPaginated(SENTINEL_MODULES, 20);
        prev = SENTINEL_MODULES;
        for (uint256 i = 0; i < arr.length; ++i) {
            if (arr[i] == module) {
                return prev;
            }
            prev = arr[i];
        }
        revert("recovery module not in list");
    }

    /// @dev The live Safe carries exactly the module set the constraint expects. Asserted on its own, because
    ///      the upgrade blocks every owner transaction on any live Safe that carries anything else.
    function testLiveModuleSetMatchesTheExpectedOne() public {
        if (!forked) return;

        (address[] memory modules, address next) = ISafeLive(SERVICE_MULTISIG).getModulesPaginated(SENTINEL_MODULES, 3);

        assertEq(modules.length, 3, "unexpected number of modules on a live service multisig");
        assertEq(next, SENTINEL_MODULES, "a fourth module is enabled on a live service multisig");
        assertTrue(ISafeLive(SERVICE_MULTISIG).isModuleEnabled(RECOVERY_MODULE), "recovery module is not enabled");
        assertTrue(ISafeLive(SERVICE_MULTISIG).isModuleEnabled(ESD), "distributor is not enabled");
        assertTrue(ISafeLive(SERVICE_MULTISIG).isModuleEnabled(GUARD_PROXY), "guard is not enabled");
    }

    /// @dev Before the upgrade the live guard lets the Safe owner drop the recovery module, which is what makes
    ///      the seat's deposit unrecoverable. Asserted so the fix below cannot pass against an already safe state.
    function testLiveGuardLetsRecoveryModuleBeDisabledBeforeUpgrade() public {
        if (!forked) return;

        bytes memory data =
            abi.encodeWithSignature("disableModule(address,address)", _prevOfModule(RECOVERY_MODULE), RECOVERY_MODULE);

        assertTrue(_execAsOwner(data, 0), "the live guard already refuses this");
        assertFalse(ISafeLive(SERVICE_MULTISIG).isModuleEnabled(RECOVERY_MODULE), "recovery module still enabled");

        // And with it gone the protocol can no longer pull the deposit back. Called as the distributor owner,
        // because unstakeAndWithdraw is owner gated while the service is staked with rewards left
        vm.warp(block.timestamp + 90 days);
        vm.prank(ESD_OWNER);
        vm.expectRevert();
        IEsdLive(ESD).unstakeAndWithdraw(STAKING_PROXY, SERVICE_ID, bytes32(0));
    }

    /// @dev After the upgrade the same transaction is refused and the module stays enabled.
    function testUpgradedGuardRefusesDisablingRecoveryModule() public {
        if (!forked) return;
        _upgradeGuard();

        bytes memory data =
            abi.encodeWithSignature("disableModule(address,address)", _prevOfModule(RECOVERY_MODULE), RECOVERY_MODULE);

        assertFalse(_execAsOwner(data, 0), "the upgraded guard let the recovery module be disabled");
        assertTrue(ISafeLive(SERVICE_MULTISIG).isModuleEnabled(RECOVERY_MODULE), "recovery module was disabled");
    }

    /// @dev The owner cannot add a module to a live Safe either.
    function testUpgradedGuardRefusesEnablingAnExtraModule() public {
        if (!forked) return;
        _upgradeGuard();

        bytes memory data = abi.encodeWithSignature("enableModule(address)", address(0xdead));

        assertFalse(_execAsOwner(data, 0), "the upgraded guard let an extra module be enabled");
        assertFalse(ISafeLive(SERVICE_MULTISIG).isModuleEnabled(address(0xdead)), "extra module was enabled");
    }

    /// @dev Liveness: an ordinary owner transaction on a live Safe still goes through after the upgrade. The new
    ///      checks read the distributor and paginate the Safe's modules, so a mismatch would stall the service.
    function testUpgradedGuardStillAllowsOrdinaryOwnerTransactions() public {
        if (!forked) return;
        _upgradeGuard();

        assertTrue(_execAsOwner("", 0), "an ordinary owner transaction was refused after the upgrade");
    }

    /// @dev Liveness: the protocol can still unstake a live seat and gets the full deposit back.
    function testUpgradedGuardStillAllowsUnstakeAndWithdraw() public {
        if (!forked) return;
        _upgradeGuard();

        uint256 balanceBefore = ITokenLive(OLAS).balanceOf(ESD);

        vm.warp(block.timestamp + 90 days);
        vm.prank(ESD_OWNER);
        IEsdLive(ESD).unstakeAndWithdraw(STAKING_PROXY, SERVICE_ID, bytes32(0));

        assertEq(
            ITokenLive(OLAS).balanceOf(ESD) - balanceBefore,
            FULL_STAKING_DEPOSIT,
            "the full staking deposit was not returned"
        );
    }
}
