// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Generic Safe interface
interface ISafe {
    /// @dev Allows to add a module to the whitelist.
    /// @param module Module to be whitelisted.
    function enableModule(address module) external;

    /// @dev Sets guard that checks transactions before and after execution.
    /// @param guard Guard address.
    function setGuard(address guard) external;

    /// @dev Returns Safe transaction nonce.
    function nonce() external view returns (uint256);
}

/// @dev Zero address.
error ZeroAddress();

/// @dev Wrong length of arrays.
error WrongArrayLength();

/// @dev Must be `DELEGATECALL` only.
error DelegatecallOnly();

/// @dev Nonce must be zero.
error ZeroNonceOnly();

/// @title SafeSetupHelper - Smart contract for wiring modules and a guard into a Safe during its creation
/// @notice Safe `setup()` delegatecalls a single `to` / `data` pair before any transaction can be executed.
///         This contract is that delegatecall target: it enables the required modules and sets the transaction
///         guard, such that a service multisig is fully wired the moment the service registry creates it.
///
///         This exists because a service multisig cannot be configured after the fact. The service registry
///         creates it owned by the service agent instances, so no protocol contract is ever an owner and
///         therefore none can enable a module on it later.
///
///         Module and guard writes go through external self-calls rather than direct storage writes. Inside
///         the setup delegatecall `address(this)` is the Safe, so those calls satisfy the Safe `authorized`
///         modifier, run the Safe's own validation and emit its `EnabledModule` / `ChangedGuard` events.
contract SafeSetupHelper {
    // Address of this contract: used to ensure it is only ever `DELEGATECALL`-ed
    address private immutable _self;

    /// @dev SafeSetupHelper constructor.
    constructor() {
        _self = address(this);
    }

    /// @dev Enables modules and sets a transaction guard on a Safe being created.
    /// @notice This function must only be called via `DELEGATECALL` from Safe `setup()`.
    /// @param modules Set of modules to enable. Must be non-empty, with no zero addresses and no duplicates.
    /// @param guard Transaction guard address, or zero address for no guard.
    function setup(address[] memory modules, address guard) external {
        // Check that the function is called via `DELEGATECALL`
        if (address(this) == _self) {
            revert DelegatecallOnly();
        }

        // Check that the Safe nonce is zero: able to execute only during the multisig initialization
        if (ISafe(address(this)).nonce() > 0) {
            revert ZeroNonceOnly();
        }

        // Get number of modules
        uint256 numModules = modules.length;
        // Check for array length
        if (numModules == 0) {
            revert WrongArrayLength();
        }

        // Traverse modules
        for (uint256 i = 0; i < numModules; ++i) {
            // Check for zero address
            if (modules[i] == address(0)) {
                revert ZeroAddress();
            }

            // Enable module: the Safe itself rejects the sentinel address and duplicates
            ISafe(address(this)).enableModule(modules[i]);
        }

        // Set guard, if provided
        if (guard != address(0)) {
            ISafe(address(this)).setGuard(guard);
        }
    }
}
