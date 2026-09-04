// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC721TokenReceiver} from "../../lib/autonolas-registries/lib/solmate/src/tokens/ERC721.sol";
import {Implementation, OwnerOnly, ZeroAddress} from "../Implementation.sol";
import {IService} from "../interfaces/IService.sol";
import {IStaking} from "../interfaces/IStaking.sol";
import {IToken, INFToken} from "../interfaces/IToken.sol";

// Collector interface
interface ICollector {
    /// @dev Tops up address(this) with a specified amount according to a selected operation.
    /// @param amount OLAS amount.
    /// @param operation Operation type.
    function topUpBalance(uint256 amount, bytes32 operation) external;

    /// @dev Tops up address(this) with a specified amount for protocol assets.
    /// @param amount OLAS amount.
    function topUpProtocol(uint256 amount) external;
}

// Safe multi send interface
interface IMultiSend {
    /// @dev Sends multiple transactions and reverts all if one fails.
    /// @param transactions Encoded transactions. Each transaction is encoded as a packed bytes of
    ///                     operation has to be uint8(0) in this version (=> 1 byte),
    ///                     to as a address (=> 20 bytes),
    ///                     value as a uint256 (=> 32 bytes),
    ///                     payload length as a uint256 (=> 32 bytes),
    ///                     payload as bytes.
    ///                     see abi.encodePacked for more information on packed encoding
    /// @notice The code is for most part the same as the normal MultiSend (to keep compatibility),
    ///         but reverts if a transaction tries to use a delegatecall.
    /// @notice This method is payable as delegatecalls keep the msg.value from the previous call
    ///         If the calling method (e.g. execTransaction) received ETH this would revert otherwise
    function multiSend(bytes memory transactions) external payable;
}

// Recovery Module interface
interface IRecoveryModule {
    /// @dev Recovers service multisig access for a specified service Id.
    /// @param serviceId Service Id.
    function recoverAccess(uint256 serviceId) external;
}

// Generic Safe interface
interface ISafe {
    enum Operation {
        Call,
        DelegateCall
    }

    /// @dev Allows a Module to execute a Safe transaction without any further confirmations.
    /// @param to Destination address of module transaction.
    /// @param value Ether value of module transaction.
    /// @param data Data payload of module transaction.
    /// @param operation Operation type of module transaction.
    function execTransactionFromModule(address to, uint256 value, bytes memory data, Operation operation)
        external
        returns (bool success);
}

// Safe setup helper interface
interface ISafeSetupHelper {
    /// @dev Enables modules and sets a transaction guard on a Safe being created.
    /// @param modules Set of modules to enable.
    /// @param guard Transaction guard address.
    function setup(address[] memory modules, address guard) external;
}

// Service registry interface
interface IServiceRegistry {
    /// @dev Gets multisig implementation whitelisting status.
    /// @param multisigImplementation Multisig implementation address.
    /// @return True, if multisig implementation is whitelisted.
    function mapMultisigs(address multisigImplementation) external view returns (bool);
}

// SafeMultisigWithRecoveryModule interface
interface ISafeMultisigWithRecoveryModule {
    /// @dev Gets recovery module address.
    function recoveryModule() external view returns (address);
}

/// @dev Zero value.
error ZeroValue();

/// @dev The contract is already initialized.
error AlreadyInitialized();

/// @dev Wrong length of arrays.
error WrongArrayLength();

/// @dev Value overflow.
/// @param provided Overflow value.
/// @param max Maximum possible value.
error Overflow(uint256 provided, uint256 max);

/// @dev Account is unauthorized.
/// @param account Account address.
error UnauthorizedAccount(address account);

/// @dev Caught reentrancy violation.
error ReentrancyGuard();

/// @dev Execution has failed.
/// @param target Target address.
/// @param payload Payload data.
error ExecutionFailed(address target, bytes payload);

/// @dev Staking type is not supported.
/// @param stakingType Staking type.
error UnsupportedStakingType(uint8 stakingType);

/// @dev Multisig implementation is not whitelisted in the service registry.
/// @param multisigImplementation Multisig implementation address.
error UnauthorizedMultisig(address multisigImplementation);

/// @dev Staking access is ambiguous: a staking proxy must either be governed by a staking guard, or be
///      explicitly open to any account.
/// @param stakingProxy Staking proxy address.
/// @param stakingGuard Staking guard address.
/// @param openAccess Open access flag.
error WrongStakingAccess(address stakingProxy, address stakingGuard, bool openAccess);

/// @title ExternalStakingDistributor - Smart contract for distributing OLAS across external staking contracts
contract ExternalStakingDistributor is Implementation, ERC721TokenReceiver {
    // Staking type enum
    enum StakingType {
        STAKING_TYPE_OLAS_V1,
        STAKING_TYPE_OLAS_V2
    }

    event StakingProcessorL2Updated(address indexed l2StakingProcessor);
    event MultisigGuardUpdated(address indexed guard);
    event MultisigImplementationsUpdated(address indexed safeMultisig, address indexed safeSetupHelper);
    event ExternalServiceStaked(
        address indexed sender,
        address indexed stakingProxy,
        uint256 indexed serviceId,
        uint256 agentId,
        bytes32 configHash,
        uint256 stakingDeposit,
        uint256 stakedBalance
    );
    event ExternalServiceUnstaked(
        address indexed sender,
        address indexed stakingProxy,
        uint256 indexed serviceId,
        uint256 stakingDeposit,
        uint256 stakedBalance
    );
    event ExternalServiceRestaked(address indexed sender, address indexed stakingProxy, uint256 indexed serviceId);
    event Deployed(uint256 indexed serviceId, address indexed multisig);
    event RewardsDistributed(
        uint256 indexed serviceId,
        address indexed multisig,
        uint256 collectorAmount,
        uint256 protocolAmount,
        uint256 curatingAgentAmount
    );
    event SetStakingProxyConfigs(address[] stakingProxies, uint256[] proxyTypes);
    event SetManagingAgentStatuses(address[] managingAgents, bool[] statuses);
    event SetCuratingAgentStatuses(
        address indexed stakingGuard, address indexed stakingProxy, address[] managingAgents, bool[] statuses
    );
    event Deposit(address indexed sender, bytes32 indexed operation, uint256 amount);
    event Withdraw(address indexed sender, bytes32 indexed operation, uint256 amount, uint256 unstakeRequestedAmount);
    event Claimed(address[] stakingProxies, uint256[] serviceIds, uint256[] rewards);
    event NativeTokenReceived(uint256 amount);

    // Staking Manager version
    string public constant VERSION = "0.1.0";
    // Reward transfer operation
    bytes32 public constant REWARD = 0x0b9821ae606ebc7c79bf3390bdd3dc93e1b4a7cda27aad60646e7b88ff55b001;

    // Number of agent instances
    uint256 public constant NUM_AGENT_INSTANCES = 1;
    // Threshold
    uint256 public constant THRESHOLD = 1;
    // Max reward factor: 10k is enough to handle 0..100.00% with a step of 0.01%
    uint256 public constant MAX_REWARD_FACTOR = 10_000;
    // Open access flag mask: bit 216 of the staking config, just above the staking guard address
    uint256 public constant OPEN_ACCESS_MASK = 1 << 216;

    // Service manager address
    address public immutable serviceManager;
    // OLAS token address
    address public immutable olas;
    // Service registry address
    address public immutable serviceRegistry;
    // Service registry token utility address
    address public immutable serviceRegistryTokenUtility;
    // Safe multisig with recovery module processing contract address
    address public immutable safeMultisigWithRecoveryModule;
    // Recovery module contract address
    address public immutable recoveryModule;
    // Safe fallback handler address
    address public immutable fallbackHandler;
    // Multisend contract address
    address public immutable multiSend;
    // OLAS collector address
    address public immutable collector;

    // Staked balance
    uint256 public stakedBalance;
    // L2 staking processor address
    address public l2StakingProcessor;
    // Multisig guard address
    address public guard;

    // Nonce
    uint256 internal _nonce;
    // Reentrancy lock
    uint256 internal _locked = 1;

    // Mapping of whitelisted staking proxy address => (staking reward distributions | staking type)
    // Staking config: stakingGuard 160 bits | collectorRewardFactor 16 bits | protocolRewardFactor 16 bits
    //                 | curatingAgentRewardFactor 16 bits | stakingType 8 bits
    mapping(address => uint256) public mapStakingProxyConfigs;
    // Mapping of unstake requests: unstake operation => amount requested
    mapping(bytes32 => uint256) public mapUnstakeOperationRequestedAmounts;
    // Mapping of service Id => agent address curating it
    mapping(uint256 => address) public mapServiceIdCuratingAgents;
    // UNUSED for now: Mapping whitelisted curating agent addresses
    mapping(address => bool) public mapCuratingAgents;
    // Mapping of whitelisted managing agent addresses
    mapping(address => bool) public mapManagingAgents;
    // Mapping of multisig address => service Id
    mapping(address => uint256) public mapMultisigServiceIds;

    // Mapping of (staking guard + staking proxy) hash => whitelisted curating agent addresses
    mapping(bytes32 => mapping(address => bool)) public mapStakingGuardHashCuratingAgents;

    // Safe multisig processing contract address, used to create service multisigs.
    // Appended after the mappings on purpose: this preserves the storage layout of already deployed proxies,
    // which must set it via changeMultisigImplementations() right after the implementation upgrade.
    address public safeMultisig;
    // Safe setup helper address, delegatecall-ed during service multisig creation to wire modules and the guard
    address public safeSetupHelper;

    /// @dev ExternalStakingDistributor constructor.
    /// @param _olas OLAS token address.
    /// @param _serviceManager Service manager address.
    /// @param _safeMultisigWithRecoveryModule Safe multisig with recovery module processing contract address.
    /// @param _fallbackHandler Safe fallback handler address.
    /// @param _multiSend Multisend contract address.
    /// @param _collector OLAS collector address.
    constructor(
        address _olas,
        address _serviceManager,
        address _safeMultisigWithRecoveryModule,
        address _fallbackHandler,
        address _multiSend,
        address _collector
    ) {
        // Check for zero addresses
        if (
            _olas == address(0) || _serviceManager == address(0) || _safeMultisigWithRecoveryModule == address(0)
                || _fallbackHandler == address(0) || _multiSend == address(0) || _collector == address(0)
        ) {
            revert ZeroAddress();
        }

        olas = _olas;
        serviceManager = _serviceManager;
        safeMultisigWithRecoveryModule = _safeMultisigWithRecoveryModule;
        fallbackHandler = _fallbackHandler;
        multiSend = _multiSend;
        collector = _collector;
        serviceRegistry = IService(serviceManager).serviceRegistry();
        serviceRegistryTokenUtility = IService(serviceManager).serviceRegistryTokenUtility();
        recoveryModule = ISafeMultisigWithRecoveryModule(_safeMultisigWithRecoveryModule).recoveryModule();
    }

    /// @dev Initializes external staking distributor.
    /// @param _safeMultisig Safe multisig processing contract address.
    /// @param _safeSetupHelper Safe setup helper address.
    function initialize(address _safeMultisig, address _safeSetupHelper) external {
        if (owner != address(0)) {
            revert AlreadyInitialized();
        }

        // Check for zero addresses
        if (_safeMultisig == address(0) || _safeSetupHelper == address(0)) {
            revert ZeroAddress();
        }

        safeMultisig = _safeMultisig;
        safeSetupHelper = _safeSetupHelper;

        owner = msg.sender;
    }

    /// @dev Changes Safe multisig implementation and setup helper addresses.
    /// @notice The multisig implementation must be whitelisted in the service registry at the time of the call,
    ///         as service deployment reverts otherwise. This function is also the migration path for proxies
    ///         upgraded from an implementation that had no such slots.
    /// @param newSafeMultisig New Safe multisig processing contract address.
    /// @param newSafeSetupHelper New Safe setup helper address.
    function changeMultisigImplementations(address newSafeMultisig, address newSafeSetupHelper) external {
        // Check for ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for zero addresses
        if (newSafeMultisig == address(0) || newSafeSetupHelper == address(0)) {
            revert ZeroAddress();
        }

        // Check that multisig implementation is whitelisted in the service registry
        if (!IServiceRegistry(serviceRegistry).mapMultisigs(newSafeMultisig)) {
            revert UnauthorizedMultisig(newSafeMultisig);
        }

        safeMultisig = newSafeMultisig;
        safeSetupHelper = newSafeSetupHelper;

        emit MultisigImplementationsUpdated(newSafeMultisig, newSafeSetupHelper);
    }

    /// @dev Changes staking processor L2 address.
    /// @param newStakingProcessorL2 New staking processor L2 address.
    function changeStakingProcessorL2(address newStakingProcessorL2) external {
        // Check for ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for zero address
        if (newStakingProcessorL2 == address(0)) {
            revert ZeroAddress();
        }

        l2StakingProcessor = newStakingProcessorL2;
        emit StakingProcessorL2Updated(newStakingProcessorL2);
    }

    /// @dev Changes multisig guard address.
    /// @param newGuard New multisig guard address.
    function changeMultisigGuard(address newGuard) external {
        // Check for ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for zero address
        if (newGuard == address(0)) {
            revert ZeroAddress();
        }

        guard = newGuard;
        emit MultisigGuardUpdated(newGuard);
    }

    /// @dev Builds Safe multisig creation data for the service registry.
    /// @notice The service registry creates the multisig owned by the service agent instances, so no protocol
    ///         contract is ever an owner and none can enable a module on it afterwards. Everything the protocol
    ///         needs on that multisig is therefore wired in the Safe `setup()` delegatecall to safeSetupHelper:
    ///         address(this) as a module for reward distribution, the guard both as a module and as the
    ///         transaction guard, and the recovery module, without which the service could never be unstaked
    ///         and re-deployed later.
    /// @param localGuard Multisig guard address.
    /// @return data Packed Safe multisig creation data.
    function _getMultisigCreationData(address localGuard) internal returns (bytes memory data) {
        // Prepare Safe multisig nonce
        uint256 localNonce = _nonce;
        uint256 randomNonce = uint256(keccak256(abi.encodePacked(block.timestamp, msg.sender, localNonce)));

        // Update global nonce
        _nonce = localNonce + 1;

        // Modules to enable on a created multisig
        address[] memory modules = new address[](3);
        modules[0] = recoveryModule;
        modules[1] = address(this);
        modules[2] = localGuard;

        // Safe setup delegatecall payload
        bytes memory payload = abi.encodeCall(ISafeSetupHelper.setup, (modules, localGuard));

        // Packed Safe multisig creation data:
        // to | fallbackHandler | paymentToken | paymentReceiver | payment | nonce | payload
        data = abi.encodePacked(
            safeSetupHelper, fallbackHandler, address(0), address(0), uint256(0), randomNonce, payload
        );
    }

    /// @dev Creates and / or (re-)deploys service and stakes it.
    /// @param stakingProxy Staking proxy address.
    /// @param minStakingDeposit Min staking deposit value.
    /// @param serviceId Service Id.
    /// @param agentId Agent Blueprint Id.
    /// @param configHash Config hash.
    /// @param agentInstance Agent instance address.
    function _deployAndStake(
        address stakingProxy,
        uint256 minStakingDeposit,
        uint256 serviceId,
        uint256 agentId,
        bytes32 configHash,
        address agentInstance
    ) internal returns (uint256) {
        // Get service creation flag
        bool createService = serviceId > 0 ? false : true;

        // Set agent params
        IService.AgentParams[] memory agentParams = new IService.AgentParams[](NUM_AGENT_INSTANCES);
        agentParams[0] = IService.AgentParams(uint32(NUM_AGENT_INSTANCES), uint96(minStakingDeposit));

        // Get agent Ids
        uint32[] memory agentIds = new uint32[](NUM_AGENT_INSTANCES);
        agentIds[0] = uint32(agentId);

        // Set agent instances as [agentInstance]
        address[] memory instances = new address[](NUM_AGENT_INSTANCES);
        instances[0] = agentInstance;

        if (createService) {
            // Create a service owned by this contract
            serviceId = IService(serviceManager)
                .create(address(this), olas, configHash, agentIds, agentParams, uint32(THRESHOLD));
        } else {
            // Update service owned by this contract
            IService(serviceManager).update(olas, configHash, agentIds, agentParams, uint32(THRESHOLD), serviceId);
        }

        // Activate registration (1 wei as a deposit wrapper)
        IService(serviceManager).activateRegistration{value: 1}(serviceId);

        // Register msg.sender as an agent instance (numAgentInstances wei as a bond wrapper)
        IService(serviceManager).registerAgents{value: NUM_AGENT_INSTANCES}(serviceId, instances, agentIds);

        address multisig;
        if (createService) {
            // Get multisig guard
            address localGuard = guard;
            // Check for zero address: the guard is a module and the transaction guard of every service multisig
            if (localGuard == address(0)) {
                revert ZeroAddress();
            }

            // Get Safe multisig implementation
            address localSafeMultisig = safeMultisig;
            // Check for zero address: must be set via changeMultisigImplementations() after an upgrade
            if (localSafeMultisig == address(0) || safeSetupHelper == address(0)) {
                revert ZeroAddress();
            }

            // Deploy service: the service registry creates a multisig owned by the registered agent instances,
            // wired with the required modules and guard by the Safe setup delegatecall
            multisig =
                IService(serviceManager).deploy(serviceId, localSafeMultisig, _getMultisigCreationData(localGuard));

            // Link multisig and service Id before any guarded multisig transaction can happen, as the guard
            // rejects transactions of a multisig it cannot resolve to a service Id
            mapMultisigServiceIds[multisig] = serviceId;
        } else {
            // Re-deploy service via recovery module
            multisig = IService(serviceManager).deploy(serviceId, recoveryModule, abi.encode(serviceId));
        }

        emit Deployed(serviceId, multisig);

        // Approve service NFT for staking instance
        INFToken(serviceRegistry).approve(stakingProxy, serviceId);

        // Stake service
        IStaking(stakingProxy).stake(serviceId);

        return serviceId;
    }

    /// @dev Distributes rewards.
    /// @param stakingProxy Staking proxy address.
    /// @param serviceId Service Id.
    /// @param reward Service reward.
    function _distributeRewards(address stakingProxy, uint256 serviceId, uint256 reward) internal {
        // Get service multisig
        (, address multisig,,,,,) = IService(serviceRegistry).mapServices(serviceId);

        // Get service curating agent address
        address curatingAgent = mapServiceIdCuratingAgents[serviceId];

        // Sanity checks
        if (multisig == address(0) || curatingAgent == address(0)) {
            revert ZeroAddress();
        }

        // Get proxy config value
        uint256 config = mapStakingProxyConfigs[stakingProxy];

        // Unwrap config
        (, uint256 collectorAmount, uint256 protocolAmount,, StakingType stakingType,) = unwrapStakingConfig(config);

        // Calculate reward distribution
        collectorAmount = (reward * collectorAmount) / MAX_REWARD_FACTOR;
        protocolAmount = (reward * protocolAmount) / MAX_REWARD_FACTOR;
        uint256 fullCollectorAmount = collectorAmount + protocolAmount;
        uint256 curatingAgentAmount = reward - fullCollectorAmount;

        // Check staking type to define transfer operations
        if (stakingType == StakingType.STAKING_TYPE_OLAS_V1) {
            // Reward is on multisig

            // Encode OLAS approve function call for collector
            bytes memory data = abi.encodeCall(IToken.approve, (collector, fullCollectorAmount));
            // MultiSend payload with the packed data of (operation, multisig address, value(0), payload length, payload)
            bytes memory msPayload = abi.encodePacked(ISafe.Operation.Call, olas, uint256(0), data.length, data);

            // Encode collector top-up function call for REWARD operation
            data = abi.encodeCall(ICollector.topUpBalance, (collectorAmount, REWARD));
            // Concatenate multi send payload with the packed data of (operation, multisig address, value(0), payload length, payload)
            msPayload = bytes.concat(
                msPayload, abi.encodePacked(ISafe.Operation.Call, collector, uint256(0), data.length, data)
            );

            // Check for protocol amount
            if (protocolAmount > 0) {
                // Encode collector top-up function call for protocol assets
                data = abi.encodeCall(ICollector.topUpProtocol, (protocolAmount));
                // Concatenate multi send payload with the packed data of (operation, multisig address, value(0), payload length, payload)
                msPayload = bytes.concat(
                    msPayload, abi.encodePacked(ISafe.Operation.Call, collector, uint256(0), data.length, data)
                );
            }

            // Check for curating agent amount
            if (curatingAgentAmount > 0) {
                // Encode OLAS transfer function call for curating agent
                data = abi.encodeCall(IToken.transfer, (curatingAgent, curatingAgentAmount));
                // Concatenate multi send payload with the packed data of (operation, multisig address, value(0), payload length, payload)
                msPayload = bytes.concat(
                    msPayload, abi.encodePacked(ISafe.Operation.Call, olas, uint256(0), data.length, data)
                );
            }

            // Multisend call to execute all the payloads
            msPayload = abi.encodeCall(IMultiSend.multiSend, (msPayload));

            // Execute module call
            bool success =
                ISafe(multisig).execTransactionFromModule(multiSend, 0, msPayload, ISafe.Operation.DelegateCall);

            // Check for success
            if (!success) {
                revert ExecutionFailed(multiSend, msPayload);
            }
        } else if (stakingType == StakingType.STAKING_TYPE_OLAS_V2) {
            // Reward is already on address(this)

            // Approve olas for collector
            IToken(olas).approve(collector, fullCollectorAmount);
            // Collector top-up function call for REWARD operation
            ICollector(collector).topUpBalance(collectorAmount, REWARD);

            // Check for protocol amount
            if (protocolAmount > 0) {
                ICollector(collector).topUpProtocol(protocolAmount);
            }

            // Check for curating agent amount
            if (curatingAgentAmount > 0) {
                IToken(olas).transfer(curatingAgent, curatingAgentAmount);
            }
        } else {
            // This must never happen
            revert UnsupportedStakingType(uint8(stakingType));
        }

        emit RewardsDistributed(serviceId, multisig, collectorAmount, protocolAmount, curatingAgentAmount);
    }

    /// @dev Stakes OLAS into specified staking proxy contract if balance is enough for staking.
    /// @param stakingProxy Staking proxy address.
    /// @param serviceId Service Id: non-zero if service is owned by address(this) and could be reused, zero otherwise.
    /// @param agentId Agent Blueprint Id.
    /// @param configHash Config hash.
    /// @param agentInstance Agent instance address.
    function stake(address stakingProxy, uint256 serviceId, uint256 agentId, bytes32 configHash, address agentInstance)
        external
    {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Get proxy config value
        uint256 config = mapStakingProxyConfigs[stakingProxy];

        // Check for whitelisted staking proxy type
        if (config == 0) {
            revert ZeroValue();
        }

        // If staker is not owner - check for curating agent access
        if (msg.sender != owner) {
            // Get staking guard address and open access flag
            (address stakingGuard,,,,, bool openAccess) = unwrapStakingConfig(config);

            // Access is denied unless the proxy is explicitly open, or msg.sender is one of its curating agents.
            // Note the deny by default: a config carrying neither a staking guard nor the open access flag,
            // which is what an incomplete config batch produces, closes the proxy rather than opening it
            bool curatingAgentAccess = openAccess;

            // Check for msg.sender access
            if (!curatingAgentAccess) {
                // Get staking hash
                bytes32 stakingHash = keccak256(abi.encode(stakingGuard, stakingProxy));
                // Check access
                curatingAgentAccess = mapStakingGuardHashCuratingAgents[stakingHash][msg.sender];
            }

            // Check for access: whitelisted curating agent
            if (!curatingAgentAccess) {
                revert UnauthorizedAccount(msg.sender);
            }
        }

        // Check for zero value
        if (configHash == 0) {
            revert ZeroValue();
        }

        // Check for agent Id
        if (agentId == 0) {
            // If zero - fetch it from stakingProxy
            uint256[] memory agentIds = IStaking(stakingProxy).getAgentIds();

            // Check for length
            if (agentIds.length == 0) {
                revert ZeroValue();
            }

            // Assign agent Id
            agentId = agentIds[0];

            // This must never happen if staking proxy is setup correctly
            if (agentId == 0) {
                revert ZeroValue();
            }
        }

        // Get current unstaked balance
        uint256 balance = IToken(olas).balanceOf(address(this));
        uint256 minStakingDeposit = IStaking(stakingProxy).minStakingDeposit();
        // Note: for now max number of agent instances is 1
        uint256 fullStakingDeposit = minStakingDeposit * (1 + NUM_AGENT_INSTANCES);

        // Check for balance
        if (fullStakingDeposit > balance) {
            revert Overflow(fullStakingDeposit, balance);
        }

        // Get current staked balance and update it
        uint256 localStakedBalance = stakedBalance + fullStakingDeposit;
        stakedBalance = localStakedBalance;

        // Approve token for the serviceRegistryTokenUtility contract
        IToken(olas).approve(serviceRegistryTokenUtility, fullStakingDeposit);

        serviceId = _deployAndStake(stakingProxy, minStakingDeposit, serviceId, agentId, configHash, agentInstance);

        // Record service curating agent
        mapServiceIdCuratingAgents[serviceId] = msg.sender;

        emit ExternalServiceStaked(
            msg.sender, stakingProxy, serviceId, agentId, configHash, fullStakingDeposit, localStakedBalance
        );

        _locked = 1;
    }

    /// @dev Unstakes, if needed, and withdraws specified amounts from specified staking contracts.
    /// @param stakingProxy Staking proxy address.
    /// @param serviceId Service Id.
    /// @param operation Unstake operation type.
    function unstakeAndWithdraw(address stakingProxy, uint256 serviceId, bytes32 operation) external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check if service unstake is requested
        if (stakingProxy != address(0) && serviceId > 0) {
            // Get staking proxy available rewards amount
            uint256 availableRewards = IStaking(stakingProxy).availableRewards();

            // Check if service is evicted
            IStaking.StakingState stakingState = IStaking(stakingProxy).getStakingState(serviceId);

            // Check for unstaked state
            if (stakingState == IStaking.StakingState.Unstaked) {
                revert ZeroValue();
            }

            // Check for zero rewards balance and access: whitelisted managing agent or owner
            // msg.sender does not matter if rewards are no longer available, or if the service is evicted
            if (
                stakingState == IStaking.StakingState.Staked && availableRewards > 0
                    && !(mapManagingAgents[msg.sender] || msg.sender == owner)
            ) {
                revert UnauthorizedAccount(msg.sender);
            }

            // Calculate how many unstakes are needed
            uint256 minStakingDeposit = IStaking(stakingProxy).minStakingDeposit();
            uint256 fullStakingDeposit = minStakingDeposit * (1 + NUM_AGENT_INSTANCES);

            // Get current staked balance
            uint256 localStakedBalance = stakedBalance;

            // This must never happen because of how it was setup in first place
            if (fullStakingDeposit > localStakedBalance) {
                revert Overflow(fullStakingDeposit, localStakedBalance);
            }

            // Update staked balance
            localStakedBalance -= fullStakingDeposit;
            stakedBalance = localStakedBalance;

            // Unstake, terminate and unbond service
            uint256 reward = IStaking(stakingProxy).unstake(serviceId);
            IService(serviceManager).terminate(serviceId);
            IService(serviceManager).unbond(serviceId);

            // Pass access to address(this)
            IRecoveryModule(recoveryModule).recoverAccess(serviceId);

            if (reward > 0) {
                // Distribute leftover rewards, if not zero
                _distributeRewards(stakingProxy, serviceId, reward);
            }

            // Clear curating agent since service is unstaked, terminated and unbonded
            delete mapServiceIdCuratingAgents[serviceId];

            emit ExternalServiceUnstaked(msg.sender, stakingProxy, serviceId, fullStakingDeposit, localStakedBalance);
        }

        // Get current unstake requested amount
        uint256 unstakeRequestedAmount = mapUnstakeOperationRequestedAmounts[operation];

        // Check if requested amount is not zero
        if (unstakeRequestedAmount > 0) {
            // Get current balance
            uint256 amount = IToken(olas).balanceOf(address(this));
            // Check for zero balance
            if (amount == 0) {
                revert ZeroValue();
            }

            // Check if OLAS balance is not enough to cover requested unstake operation amount
            if (unstakeRequestedAmount > amount) {
                unstakeRequestedAmount -= amount;
                // Update unstake requested amount
                mapUnstakeOperationRequestedAmounts[operation] = unstakeRequestedAmount;
            } else {
                amount = unstakeRequestedAmount;
                mapUnstakeOperationRequestedAmounts[operation] = 0;
            }

            // Approve OLAS for collector to initiate L1 transfer for corresponding operation later by agents / operators
            IToken(olas).approve(collector, amount);

            // Request top-up by Collector for a specific unstake operation
            ICollector(collector).topUpBalance(amount, operation);

            emit Withdraw(msg.sender, operation, amount, unstakeRequestedAmount);
        }

        _locked = 1;
    }

    /// @dev Re-stakes evicted specified service Id.
    /// @param stakingProxy Staking proxy address.
    /// @param serviceId Service Id.
    function reStake(address stakingProxy, uint256 serviceId) external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check for zero address
        if (stakingProxy == address(0)) {
            revert ZeroAddress();
        }

        // Check for zero value
        if (serviceId == 0) {
            revert ZeroValue();
        }

        // Check if service is evicted
        IStaking.StakingState stakingState = IStaking(stakingProxy).getStakingState(serviceId);

        // Check for evicted state
        if (stakingState != IStaking.StakingState.Evicted) {
            revert ZeroValue();
        }

        // Check for access: service curating agent, managing agent, or owner
        if (!(mapServiceIdCuratingAgents[serviceId] == msg.sender || mapManagingAgents[msg.sender]
                    || msg.sender == owner)) {
            revert UnauthorizedAccount(msg.sender);
        }

        // Unstake service
        uint256 reward = IStaking(stakingProxy).unstake(serviceId);

        if (reward > 0) {
            // Distribute leftover rewards, if not zero
            _distributeRewards(stakingProxy, serviceId, reward);
        }

        // Approve service NFT for re-staking
        INFToken(serviceRegistry).approve(stakingProxy, serviceId);

        // Stake service
        IStaking(stakingProxy).stake(serviceId);

        emit ExternalServiceRestaked(msg.sender, stakingProxy, serviceId);

        _locked = 1;
    }

    /// @dev Sets staking proxy types.
    /// @param stakingProxies Set of staking proxies.
    /// @param configs Corresponding set of staking configs.
    function setStakingProxyConfigs(address[] memory stakingProxies, uint256[] memory configs) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Get number of proxies
        uint256 numProxies = stakingProxies.length;
        // Check for array length
        if (numProxies == 0 || numProxies != configs.length) {
            revert WrongArrayLength();
        }

        // Traverse staking proxies
        for (uint256 i = 0; i < numProxies; ++i) {
            // Check for zero address
            if (stakingProxies[i] == address(0)) {
                revert ZeroAddress();
            }

            // Check for zero value
            if (configs[i] == 0) {
                revert ZeroValue();
            }

            // Check proxy configs
            (
                address stakingGuard,
                uint256 collectorRewardFactor,
                uint256 protocolRewardFactor,
                uint256 curatingAgentRewardFactor,,
                bool openAccess
            ) = unwrapStakingConfig(configs[i]);

            // Staking access must be stated explicitly: either the proxy is governed by a staking guard curating
            // agent allowlist, or it is open to any account. A config with neither is ambiguous and is the way an
            // allowlisted proxy silently becomes permissionless; a config with both is contradictory
            if ((stakingGuard == address(0)) != openAccess) {
                revert WrongStakingAccess(stakingProxies[i], stakingGuard, openAccess);
            }

            // Check for collector and zero value
            if (collectorRewardFactor == 0) {
                revert ZeroValue();
            }

            // Check for total factor to be equal to MAX_REWARD_FACTOR (100%)
            uint256 totalFactor = collectorRewardFactor + protocolRewardFactor + curatingAgentRewardFactor;
            if (totalFactor != MAX_REWARD_FACTOR) {
                revert Overflow(totalFactor, MAX_REWARD_FACTOR);
            }

            mapStakingProxyConfigs[stakingProxies[i]] = configs[i];
        }

        emit SetStakingProxyConfigs(stakingProxies, configs);
    }

    /// @dev Sets managing agents statuses.
    /// @notice This is required such that unstake does not happen without a reason.
    /// @param managingAgents Set of managing agents.
    /// @param statuses Corresponding set of statuses: true / false.
    function setManagingAgents(address[] memory managingAgents, bool[] memory statuses) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Get number of agents
        uint256 numAgents = managingAgents.length;
        // Check for array length
        if (numAgents == 0 || numAgents != statuses.length) {
            revert WrongArrayLength();
        }

        // Traverse managing agents
        for (uint256 i = 0; i < numAgents; ++i) {
            // Check for zero address
            if (managingAgents[i] == address(0)) {
                revert ZeroAddress();
            }

            mapManagingAgents[managingAgents[i]] = statuses[i];
        }

        emit SetManagingAgentStatuses(managingAgents, statuses);
    }

    /// @dev Sets curating agents statuses.
    /// @notice This is required such that potential malicious agents do not stake for no reason.
    /// @notice Contract owner sets stakingProxy config, however this function call is for staking guards only.
    /// @param stakingProxy Staking proxy address.
    /// @param curatingAgents Set of curating agents.
    /// @param statuses Corresponding set of statuses: true / false.
    function setCuratingAgents(address stakingProxy, address[] memory curatingAgents, bool[] memory statuses) external {
        // Get number of agents
        uint256 numAgents = curatingAgents.length;
        // Check for array length
        if (numAgents == 0 || numAgents != statuses.length) {
            revert WrongArrayLength();
        }

        // Get proxy config value
        uint256 config = mapStakingProxyConfigs[stakingProxy];

        // Check for whitelisted staking proxy type
        if (config == 0) {
            revert ZeroValue();
        }

        // Get staking guard address
        (address stakingGuard,,,,,) = unwrapStakingConfig(config);

        // Check for access: only staking guard
        if (msg.sender != stakingGuard) {
            revert UnauthorizedAccount(msg.sender);
        }

        // Encode staking hash outside of the loop
        bytes32 stakingHash = keccak256(abi.encode(stakingGuard, stakingProxy));

        // Traverse curating agents
        for (uint256 i = 0; i < numAgents; ++i) {
            // Check for zero address
            if (curatingAgents[i] == address(0)) {
                revert ZeroAddress();
            }

            // Set curating agent status
            mapStakingGuardHashCuratingAgents[stakingHash][curatingAgents[i]] = statuses[i];
        }

        emit SetCuratingAgentStatuses(stakingGuard, stakingProxy, curatingAgents, statuses);
    }

    /// @dev Deposits OLAS for further staking.
    /// @param amount OLAS amount.
    /// @param operation Stake operation type.
    function deposit(uint256 amount, bytes32 operation) external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check for l2StakingProcessor to be a sender
        if (msg.sender != l2StakingProcessor) {
            revert UnauthorizedAccount(msg.sender);
        }

        // Get OLAS from l2StakingProcessor or any other account
        IToken(olas).transferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, operation, amount);

        _locked = 1;
    }

    /// @dev Requests withdraw via specified unstake operation, and request to add to unstake amount, if required.
    /// @param amount Specified unstake amount.
    /// @param operation Unstake operation type.
    function withdrawAndRequestUnstake(uint256 amount, bytes32 operation) external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check for l2StakingProcessor to be a sender
        if (msg.sender != l2StakingProcessor) {
            revert UnauthorizedAccount(msg.sender);
        }

        // Get current OLAS balance
        uint256 olasBalance = IToken(olas).balanceOf(address(this));
        // Get current staked balance
        uint256 localStakedBalance = stakedBalance;
        // Get overall amount
        uint256 totalBalance = olasBalance + localStakedBalance;

        // Check for overflow: this must never happen as checks are done on L1 side
        if (amount > totalBalance) {
            revert Overflow(amount, totalBalance);
        }

        uint256 unstakeRequestedAmount;

        // Check if OLAS balance is not enough to cover withdraw request
        if (amount > olasBalance) {
            unstakeRequestedAmount = amount - olasBalance;
            amount = olasBalance;

            mapUnstakeOperationRequestedAmounts[operation] += unstakeRequestedAmount;
        }

        // Check for zero amount
        if (amount > 0) {
            // Approve OLAS for collector to initiate L1 transfer for corresponding operation later by agents / operators
            IToken(olas).approve(collector, amount);

            // Request top-up by Collector for a specific unstake operation
            ICollector(collector).topUpBalance(amount, operation);
        }

        emit Withdraw(msg.sender, operation, amount, unstakeRequestedAmount);

        _locked = 1;
    }

    /// @dev Claims specified service rewards.
    /// @param stakingProxies Set of staking proxy addresses.
    /// @param serviceIds Corresponding set if service Ids.
    /// @return rewards Set of staking rewards.
    function claim(address[] memory stakingProxies, uint256[] memory serviceIds)
        external
        returns (uint256[] memory rewards)
    {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Get number of proxies
        uint256 numProxies = stakingProxies.length;
        // Check for correct array length
        if (numProxies == 0 || serviceIds.length != numProxies) {
            revert WrongArrayLength();
        }

        // Allocate rewards array
        rewards = new uint256[](numProxies);

        // Claim rewards
        for (uint256 i = 0; i < numProxies; ++i) {
            // Check for zero address
            if (stakingProxies[i] == address(0)) {
                revert ZeroAddress();
            }

            // Claim reward
            rewards[i] = IStaking(stakingProxies[i]).claim(serviceIds[i]);
        }

        // Distribute rewards
        for (uint256 i = 0; i < numProxies; ++i) {
            if (rewards[i] > 0) {
                _distributeRewards(stakingProxies[i], serviceIds[i], rewards[i]);
            }
        }

        emit Claimed(stakingProxies, serviceIds, rewards);

        _locked = 1;
    }

    /// @dev Wraps staking proxy config: staking access, reward factors and staking type value.
    /// @param stakingGuard Staking proxy proposer address. Zero address only together with openAccess.
    /// @param collectorRewardFactor Collector reward factor.
    /// @param protocolRewardFactor Protocol reward factor.
    /// @param curatingAgentRewardFactor Curating agent reward factor.
    /// @param stakingType Staking type.
    /// @param openAccess True if any account may stake into this proxy, false if the staking guard curating
    ///        agent allowlist governs it.
    function wrapStakingConfig(
        address stakingGuard,
        uint256 collectorRewardFactor,
        uint256 protocolRewardFactor,
        uint256 curatingAgentRewardFactor,
        StakingType stakingType,
        bool openAccess
    ) public pure returns (uint256 config) {
        // Staking config: openAccess 1 bit | stakingGuard 160 bits | collectorRewardFactor 16 bits
        //                 | protocolRewardFactor 16 bits | curatingAgentRewardFactor 16 bits | stakingType 8 bits
        // Note the uint256 cast of the staking guard: `uint160(stakingGuard) << 56` shifts within uint160 and
        // silently truncates the top 56 bits of the address
        config = uint8(stakingType) | curatingAgentRewardFactor << 8 | protocolRewardFactor << 24
            | collectorRewardFactor << 40 | uint256(uint160(stakingGuard)) << 56;

        if (openAccess) {
            config |= OPEN_ACCESS_MASK;
        }
    }

    /// @dev Unwraps staking proxy config: staking access, reward factors and staking type value.
    /// @param config Staking proxy config value.
    /// @return stakingGuard Staking proxy proposer address.
    /// @return collectorRewardFactor Collector reward factor.
    /// @return protocolRewardFactor Protocol reward factor.
    /// @return curatingAgentRewardFactor Curating agent reward factor.
    /// @return stakingType Staking type.
    /// @return openAccess True if any account may stake into this proxy.
    function unwrapStakingConfig(uint256 config)
        public
        pure
        returns (
            address stakingGuard,
            uint256 collectorRewardFactor,
            uint256 protocolRewardFactor,
            uint256 curatingAgentRewardFactor,
            StakingType stakingType,
            bool openAccess
        )
    {
        // Staking config: openAccess 1 bit | stakingGuard 160 bits | collectorRewardFactor 16 bits
        //                 | protocolRewardFactor 16 bits | curatingAgentRewardFactor 16 bits | stakingType 8 bits
        stakingGuard = address(uint160(config >> 56));
        collectorRewardFactor = uint16(config >> 40);
        protocolRewardFactor = uint16(config >> 24);
        curatingAgentRewardFactor = uint16(config >> 8);
        stakingType = StakingType(uint8(config));
        openAccess = (config & OPEN_ACCESS_MASK) != 0;
    }

    /// @dev Receives native funds for mock Service Registry minimal payments.
    receive() external payable {
        emit NativeTokenReceived(msg.value);
    }
}
