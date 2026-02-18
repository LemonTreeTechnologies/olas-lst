# Audit 7 - External Staking Implementation

**Audit Date:** December 29, 2024  
**Commit Range:** `d7db0db` to `2d32914` (inclusive)  
**Branch:** `stake_external`  
**Tag:** `v0.2.0-pre-internal-audit`  
**Repository:** `https://github.com/LemonTreeTechnologies/olas-lst`

## Objectives

This audit focuses on the security review of the external staking implementation, which introduces:
- New `ExternalStakingDistributor` contract for distributing OLAS across external staking contracts
- Modifications to `Depository`, `Treasury`, `Collector`, and bridging contracts to support external staking
- Integration with Safe multisig contracts for service management

## Scope

The audit reviewed all changes between commits `d7db0db` (main branch) and `2d32914` (HEAD), including:
- 1 new contract: `ExternalStakingDistributor.sol` (787 lines)
- 9 modified contracts
- 2 modified test files
- 1 documentation update

## Findings
### Critical. The "create vs. update" flag in _deployAndStake is reversed.
```
    function _deployAndStake(
        address stakingProxy,
        uint256 minStakingDeposit,
        uint256 serviceId,
        uint256 agentId,
        bytes32 configHash,
        address agentInstance
    ) internal returns (uint256) {
        // Get service creation flag
        bool createService = serviceId > 0 ? true : false; # condition ? value_if_true : value_if_false
        ->  serviceId > 0 -> createService = true
        ->
        if (createService) { // if serviceId > 0
            // Create a service owned by this contract
            serviceId = IService(serviceManager)
                .create(address(this), olas, configHash, agentIds, agentParams, uint32(THRESHOLD));
        } else {
            // Update service owned by this contract
            IService(serviceManager).update(olas, configHash, agentIds, agentParams, uint32(THRESHOLD), serviceId);
        }
    Fix: bool createService = (serviceId == 0); ?
```
[x] Fixed

### Critical. Incorrect mapServiceIdCuratingAgents entry in stake for serviceId == 0
```
/// @param serviceId Service Id: non-zero if service is owned by address(this) and could be reused, zero otherwise.
    function stake(address stakingProxy, uint256 serviceId, uint256 agentId, bytes32 configHash, address agentInstance)
    
    mapServiceIdCuratingAgents[serviceId] = msg.sender;
    serviceId = _deployAndStake(..., serviceId, ...);

    Problem: If serviceId == 0 (creating a new service), the entry is made to key 0, and the real serviceId appears after _deployAndStake. As a result: for the new service, mapServiceIdCuratingAgents[realServiceId] will remain zero, and mapServiceIdCuratingAgents[0] will be equal to some address (curator).
```
[x] Fixed

### Critical? abi.encodePacked(address(0))
```
    _deployAndStake(...)
    address multisig; // zero!
        if (createService) {
            // Create multisig with address(this) as module and swap owners to agentInstance
            _createMultisigWithSelfAsModule(agentInstance);

            // Deploy service via same address multisig
            multisig = IService(serviceManager).deploy(serviceId, safeSameAddressMultisig, abi.encodePacked(multisig)); // abi.encodePacked(address(0)) ?!
    ...
    Comment needed.
```
[x] Fixed

### Medium. changeRewardFactors() is only available before initialize
```
function changeRewardFactors(
        uint256 _collectorRewardFactor,
        uint256 _protocolRewardFactor,
        uint256 _curatingAgentRewardFactor
    ) public {
        if (owner != address(0)) {
            revert AlreadyInitialized();
        }
    Should the owner be able to change this later?
```
[x] Fixed

[Security Audit Report](findings/security-audit-report.md)


