// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

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
}

interface IEsdLive {
    function unstakeAndWithdraw(address stakingProxy, uint256 serviceId, bytes32 operation) external;
    function recoveryModule() external view returns (address);
}

interface IPoolLive {
    function checkpoint() external;
}

interface IToken {
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Post-deployment check against the LIVE Gnosis guard proxy, which already points at the deployed
///      implementation. Nothing here deploys or patches the guard: whatever these tests observe is exactly
///      what a real caller on Gnosis gets right now.
contract MultisigGuardGnosisLiveForkTest is Test {
    address internal constant GUARD_PROXY = 0xBD645cf2D4F04A1c12B97fe2a8b4A09EF50F1896;
    address internal constant DEPLOYED_IMPL = 0x53f6c9E1B9305C89987D3687d7C7fd32d1ea5AC3;
    address internal constant ESD = 0x7E8C636FBD0D9085C112680d8C3fde701452dcb5;
    address internal constant ESD_OWNER = 0x40c0392c23fAfa216C69Bc291AFcb1b3F4abd49b;
    address internal constant RECOVERY_MODULE = 0x0Cb12457ed26d572c5e4A50f30b6f7A904662a72;
    address internal constant OLAS = 0xcE11e14225575945b8E6Dc0D4F2dD4C570f79d9f;

    // The highest-value live Gnosis seat: the 5000 OLAS minStakingDeposit pool
    uint256 internal constant SERVICE_ID = 3440;
    address internal constant POOL = 0xCAbD0C941E54147D40644CF7DA7e36d70DF46f44;
    address internal constant SERVICE_MULTISIG = 0xe3CEdEAF36E1f7DF0660f5Be6dB72f7d838452C0;
    address internal constant SAFE_OWNER = 0xd6645D31284D997b6fFd0836FCa1eCb8129d9651;

    address internal constant SENTINEL = address(0x1);
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("GNOSIS_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console.log("GNOSIS_RPC_URL is not set, skipping");
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;
    }

    /// @dev The proxy really is on the deployed implementation, so nothing below passes against the old one.
    function testLiveProxyIsOnTheDeployedImplementation() public {
        if (!forked) return;
        address impl = address(uint160(uint256(vm.load(GUARD_PROXY, IMPL_SLOT))));
        assertEq(impl, DEPLOYED_IMPL, "guard proxy is not on the deployed implementation");
        assertEq(IEsdLive(ESD).recoveryModule(), RECOVERY_MODULE, "unexpected recovery module on the distributor");
    }

    function _execAsOwner(address to, bytes memory data) internal returns (bool ok) {
        bytes32 txHash = ISafeLive(SERVICE_MULTISIG)
            .getTransactionHash(to, 0, data, 0, 0, 0, 0, address(0), address(0), ISafeLive(SERVICE_MULTISIG).nonce());
        vm.prank(SAFE_OWNER);
        ISafeLive(SERVICE_MULTISIG).approveHash(txHash);
        vm.prank(SAFE_OWNER);
        (ok,) = SERVICE_MULTISIG.call(
            abi.encodeWithSignature(
                "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                to,
                uint256(0),
                data,
                uint8(0),
                uint256(0),
                uint256(0),
                uint256(0),
                address(0),
                address(0),
                abi.encodePacked(bytes32(uint256(uint160(SAFE_OWNER))), bytes32(0), uint8(1))
            )
        );
    }

    function _prevOf(address module) internal view returns (address prev) {
        (address[] memory arr,) = ISafeLive(SERVICE_MULTISIG).getModulesPaginated(SENTINEL, 20);
        prev = SENTINEL;
        for (uint256 i = 0; i < arr.length; ++i) {
            if (arr[i] == module) return prev;
            prev = arr[i];
        }
        revert("recovery module not in list");
    }

    /// @dev THE ATTACK. The sole owner of a live seat tries to drop the recovery module. Must be refused.
    function testLiveGuardRefusesDisablingRecoveryModule() public {
        if (!forked) return;
        assertTrue(ISafeLive(SERVICE_MULTISIG).isModuleEnabled(RECOVERY_MODULE), "recovery not enabled to begin with");

        bool ok = _execAsOwner(
            SERVICE_MULTISIG,
            abi.encodeWithSignature("disableModule(address,address)", _prevOf(RECOVERY_MODULE), RECOVERY_MODULE)
        );

        assertFalse(ok, "LIVE GUARD LET THE RECOVERY MODULE BE DISABLED");
        assertTrue(ISafeLive(SERVICE_MULTISIG).isModuleEnabled(RECOVERY_MODULE), "recovery module was disabled");
        console.log("live Gnosis guard REFUSED disableModule(recoveryModule)");
    }

    /// @dev Adding a module is refused too, which is what closes the add-a-module variant.
    function testLiveGuardRefusesEnablingAModule() public {
        if (!forked) return;
        bool ok = _execAsOwner(SERVICE_MULTISIG, abi.encodeWithSignature("enableModule(address)", address(0xdead)));
        assertFalse(ok, "LIVE GUARD LET A MODULE BE ADDED");
        assertFalse(ISafeLive(SERVICE_MULTISIG).isModuleEnabled(address(0xdead)), "attacker module enabled");
        console.log("live Gnosis guard REFUSED enableModule(attacker)");
    }

    /// @dev And an ordinary owner transaction that leaves the module set alone still goes through, so the
    ///      upgrade has not stalled the live seats.
    function testLiveOrdinaryOwnerTransactionStillWorks() public {
        if (!forked) return;
        assertTrue(_execAsOwner(SERVICE_MULTISIG, ""), "the upgraded guard blocked an ordinary owner transaction");
        console.log("ordinary owner transaction still works");
    }

    /// @dev End to end: the protocol can still pull the full deposit back out of a live seat.
    function testLiveUnstakeAndWithdrawStillReturnsTheDeposit() public {
        if (!forked) return;
        uint256 before = IToken(OLAS).balanceOf(ESD);

        vm.warp(block.timestamp + 120 days);
        IPoolLive(POOL).checkpoint();

        vm.prank(ESD_OWNER);
        IEsdLive(ESD).unstakeAndWithdraw(POOL, SERVICE_ID, bytes32(0));

        uint256 gained = IToken(OLAS).balanceOf(ESD) - before;
        console.log("OLAS returned to the distributor:", gained / 1e18);
        assertEq(gained, 10_000 ether, "the deposit that came back was not exactly 10,000 OLAS");
    }
}
