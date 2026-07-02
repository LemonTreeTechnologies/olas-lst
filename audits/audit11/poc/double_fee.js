/*global describe, beforeEach, it*/
//
// PoC (finding L-1): DOUBLE protocol fee on external V1 rewards (fee-model observation, not a theft)
// ================================================================================================
//
// WHAT THIS QUANTIFIES:
//   The external-V1 reward R is split ONCE by ExternalStakingDistributor._distributeRewards:
//       collectorAmount   = 80.0% * R   -> Collector via topUpBalance(collectorAmount, REWARD)
//       protocolAmount    = 17.5% * R   -> Collector.protocolBalance via topUpProtocol(protocolAmount)
//       curatingAgent     =  2.5% * R   -> paid out directly to the curating agent
//   So after ESD.claim, the Collector's REWARD-operation balance = collectorAmount (80% * R), and the
//   protocol has already taken its 17.5% * R.
//
//   Later, Collector.relayTokens(REWARD, ...) forwards that REWARD balance to L1 (to the Distributor,
//   which is where stOLAS-holder rewards go). But relayTokens applies protocolFactor A SECOND TIME to
//   the REWARD balance (Collector.sol lines 342-356):
//       protocolAmount2 = (rewardBalance * protocolFactor) / MAX_PROTOCOL_FACTOR
//                       = protocolFactor * (80% * R)
//       relayed to L1   = (80% * R) - protocolAmount2
//
//   Net effect with protocolFactor = 10% (1000):
//       total-to-protocol           = 17.5%*R (ESD split) + 10%*(80%*R) = 17.5%*R + 8%*R = 25.5%*R
//       total-to-stOLAS(Distributor)= 90% * (80%*R) = 72%*R   (instead of the 80%*R the ESD split intended)
//
//   The external reward is thus taxed TWICE: once by the ESD split (protocolAmount) and once by the
//   Collector.protocolFactor on relay. The stOLAS-holder share drops from the intended 80% to 72%.
//
// NOTE FOR THE TEAM (this is a fee-MODEL question, not a bug/theft claim):
//   This is NOT a theft or an attacker path — every wei stays inside the protocol (it just moves the
//   extra 8%*R from the stOLAS-holder rewards bucket into Collector.protocolBalance, which the owner
//   controls via fundExternal). It MAY be entirely intended (protocolFactor is a deliberate,
//   owner-set fee, and it is legitimately applied to unstake/other operations too). The observation
//   is only that, FOR THE EXTERNAL-V1 REWARD PATH, protocolFactor stacks on top of the ESD's own
//   protocolAmount split, so the effective protocol take on external rewards is higher than either
//   number alone. Whether the double application is intended is a question for the team. This test
//   PASSES by asserting exactly the arithmetic it measured -- it is a documented measurement.
//
const { expect } = require("chai");
const { ethers } = require("hardhat");
const helpers = require("@nomicfoundation/hardhat-network-helpers");
const safeContracts = require("@gnosis.pm/safe-contracts");

describe("PoC (L-1): double protocol fee on external V1 rewards (ESD split + Collector.protocolFactor)", function () {
    let serviceRegistry, serviceRegistryTokenUtility, serviceManager, olas, st, gnosisSafe, gnosisSafeL2,
        gnosisSafeProxyFactory, safeModuleInitializer, fallbackHandler, multiSend, gnosisSafeMultisig,
        gnosisSafeSameAddressMultisig, recoveryModule, safeMultisigWithRecoveryModule, externalActivityChecker,
        stakingFactory, stakingVerifier, lock, distributor, unstakeRelayer, depository, treasury, collector,
        beacon, activityModule, stakingManager, externalStakingDistributor, multisigGuard,
        stakingTokenImplementation, externalStakingTokenImplementationV1, externalStakingTokenImplementationV2,
        stakingTokenInstance, gnosisDepositProcessorL1, gnosisStakingProcessorL2, activityChecker, operatorWhitelist,
        bridgeRelayer;
    let signers, deployer, agent, bytecodeHash;

    const AddressZero = ethers.constants.AddressZero;
    const HashZero = ethers.constants.HashZero;
    const oneDay = 86400;
    const defaultHash = "0x" + "5".repeat(64);
    const regDeposit = ethers.utils.parseEther("10000");
    const serviceId = 1;
    const agentId = 1;
    const agentIds = [agentId];
    const livenessPeriod = oneDay;
    const initSupply = "5" + "0".repeat(26);
    const livenessRatio = "1";
    const externalLivenessRatio = "1" + "0".repeat(12);
    const maxNumServices = 100;
    const minStakingDeposit = regDeposit;
    const fullStakeDeposit = regDeposit.mul(2);
    const timeForEmissions = 30 * oneDay;
    let serviceParams = {
        metadataHash: defaultHash, maxNumServices, rewardsPerSecond: "5" + "0".repeat(14), minStakingDeposit,
        minNumStakingPeriods: 0, maxNumInactivityPeriods: 0, numAgentInstances: 1, livenessPeriod, timeForEmissions,
        agentIds, threshold: 0, configHash: HashZero, proxyHash: HashZero, serviceRegistry: AddressZero,
        activityChecker: AddressZero, serviceRegistryTokenUtility: AddressZero, stakingToken: AddressZero,
        stakingManager: AddressZero
    };
    const apyLimit = ethers.utils.parseEther("3");
    const lockFactor = 100;
    const chainId = 31337;
    const gnosisChainId = 100;
    const stakingSupply = fullStakeDeposit.mul(ethers.BigNumber.from(maxNumServices));
    const bridgePayload = "0x";
    const rewardOperation = "0x0b9821ae606ebc7c79bf3390bdd3dc93e1b4a7cda27aad60646e7b88ff55b001";
    const unstakeOperation = "0x8ca9a95e41b5eece253c93f5b31eed1253aed6b145d8a6e14d913fdf8e732293";
    const unstakeRetiredOperation = "0x9065ad15d9673159e4597c86084aff8052550cec93c5a6e44b3f1dba4c8731b3";

    beforeEach(async function () {
        signers = await ethers.getSigners();
        deployer = signers[0];
        agent = signers[0];

        const ServiceRegistry = await ethers.getContractFactory("ServiceRegistryL2");
        serviceRegistry = await ServiceRegistry.deploy("Service Registry L2", "SERVICE", "https://localhost/service/");
        await serviceRegistry.deployed();
        serviceParams.serviceRegistry = serviceRegistry.address;

        const ServiceRegistryTokenUtility = await ethers.getContractFactory("ServiceRegistryTokenUtility");
        serviceRegistryTokenUtility = await ServiceRegistryTokenUtility.deploy(serviceRegistry.address);
        await serviceRegistryTokenUtility.deployed();
        serviceParams.serviceRegistryTokenUtility = serviceRegistryTokenUtility.address;

        const OperatorWhitelist = await ethers.getContractFactory("OperatorWhitelist");
        operatorWhitelist = await OperatorWhitelist.deploy(serviceRegistry.address);
        await operatorWhitelist.deployed();

        const ServiceManager = await ethers.getContractFactory("ServiceManager");
        serviceManager = await ServiceManager.deploy(serviceRegistry.address, serviceRegistryTokenUtility.address);
        await serviceManager.deployed();
        let proxyData = serviceManager.interface.encodeFunctionData("initialize", []);
        const ServiceManagerProxy = await ethers.getContractFactory("ServiceManagerProxy");
        const serviceManagerProxy = await ServiceManagerProxy.deploy(serviceManager.address, proxyData);
        await serviceManagerProxy.deployed();
        serviceManager = await ethers.getContractAt("ServiceManager", serviceManagerProxy.address);

        const GnosisSafe = await ethers.getContractFactory("GnosisSafe");
        gnosisSafe = await GnosisSafe.deploy();
        await gnosisSafe.deployed();
        const GnosisSafeL2 = await ethers.getContractFactory("GnosisSafeL2");
        gnosisSafeL2 = await GnosisSafeL2.deploy();
        await gnosisSafeL2.deployed();
        const GnosisSafeProxyFactory = await ethers.getContractFactory("GnosisSafeProxyFactory");
        gnosisSafeProxyFactory = await GnosisSafeProxyFactory.deploy();
        await gnosisSafeProxyFactory.deployed();
        const SafeToL2Setup = await ethers.getContractFactory("SafeToL2Setup");
        safeModuleInitializer = await SafeToL2Setup.deploy();
        await safeModuleInitializer.deployed();
        const FallbackHandler = await ethers.getContractFactory("DefaultCallbackHandler");
        fallbackHandler = await FallbackHandler.deploy();
        await fallbackHandler.deployed();
        const MultiSend = await ethers.getContractFactory("MultiSendCallOnly");
        multiSend = await MultiSend.deploy();
        await multiSend.deployed();
        const GnosisSafeProxy = await ethers.getContractFactory("GnosisSafeProxy");
        const gnosisSafeProxy = await GnosisSafeProxy.deploy(gnosisSafe.address);
        await gnosisSafeProxy.deployed();
        const bytecode = await ethers.provider.getCode(gnosisSafeProxy.address);
        bytecodeHash = ethers.utils.keccak256(bytecode);
        const GnosisSafeMultisig = await ethers.getContractFactory("GnosisSafeMultisig");
        gnosisSafeMultisig = await GnosisSafeMultisig.deploy(gnosisSafe.address, gnosisSafeProxyFactory.address);
        await gnosisSafeMultisig.deployed();
        const GnosisSafeSameAddressMultisig = await ethers.getContractFactory("GnosisSafeSameAddressMultisig");
        gnosisSafeSameAddressMultisig = await GnosisSafeSameAddressMultisig.deploy(bytecodeHash);
        await gnosisSafeSameAddressMultisig.deployed();
        const RecoveryModule = await ethers.getContractFactory("RecoveryModule");
        recoveryModule = await RecoveryModule.deploy(multiSend.address, serviceRegistry.address);
        await recoveryModule.deployed();
        const SafeMultisigWithRecoveryModule = await ethers.getContractFactory("SafeMultisigWithRecoveryModule");
        safeMultisigWithRecoveryModule = await SafeMultisigWithRecoveryModule.deploy(gnosisSafe.address,
            gnosisSafeProxyFactory.address, recoveryModule.address);
        await safeMultisigWithRecoveryModule.deployed();

        const ERC20Token = await ethers.getContractFactory("ERC20Token");
        olas = await ERC20Token.deploy();
        await olas.deployed();
        serviceParams.stakingToken = olas.address;
        await olas.mint(deployer.address, initSupply);

        const VE = await ethers.getContractFactory("MockVE");
        const ve = await VE.deploy(olas.address);
        await ve.deployed();
        const SToken = await ethers.getContractFactory("stOLAS");
        st = await SToken.deploy(olas.address);
        await st.deployed();
        const Lock = await ethers.getContractFactory("Lock");
        lock = await Lock.deploy(olas.address, ve.address);
        await lock.deployed();
        const LockProxy = await ethers.getContractFactory("Proxy");
        let initPayload = lock.interface.encodeFunctionData("initialize", []);
        const lockProxy = await LockProxy.deploy(lock.address, initPayload);
        await lockProxy.deployed();
        lock = await ethers.getContractAt("Lock", lockProxy.address);
        await olas.transfer(lock.address, ethers.utils.parseEther("1"));
        await lock.setGovernorAndCreateFirstLock(deployer.address);

        const Distributor = await ethers.getContractFactory("Distributor");
        distributor = await Distributor.deploy(olas.address, st.address, lock.address);
        await distributor.deployed();
        const DistributorProxy = await ethers.getContractFactory("Proxy");
        initPayload = distributor.interface.encodeFunctionData("initialize", [lockFactor]);
        const distributorProxy = await DistributorProxy.deploy(distributor.address, initPayload);
        await distributorProxy.deployed();
        distributor = await ethers.getContractAt("Distributor", distributorProxy.address);

        const UnstakeRelayer = await ethers.getContractFactory("UnstakeRelayer");
        unstakeRelayer = await UnstakeRelayer.deploy(olas.address, st.address);
        await unstakeRelayer.deployed();
        const UnstakeRelayerProxy = await ethers.getContractFactory("Proxy");
        initPayload = unstakeRelayer.interface.encodeFunctionData("initialize", []);
        const unstakeRelayerProxy = await UnstakeRelayerProxy.deploy(unstakeRelayer.address, initPayload);
        await unstakeRelayerProxy.deployed();
        unstakeRelayer = await ethers.getContractAt("UnstakeRelayer", unstakeRelayerProxy.address);

        const Depository = await ethers.getContractFactory("Depository");
        depository = await Depository.deploy(olas.address, st.address);
        await depository.deployed();
        const DepositoryProxy = await ethers.getContractFactory("Proxy");
        initPayload = depository.interface.encodeFunctionData("initialize", []);
        const depositoryProxy = await DepositoryProxy.deploy(depository.address, initPayload);
        await depositoryProxy.deployed();
        depository = await ethers.getContractAt("Depository", depositoryProxy.address);
        await depository.changeProductType(2);

        const Treasury = await ethers.getContractFactory("Treasury");
        treasury = await Treasury.deploy(olas.address, st.address, depository.address);
        await treasury.deployed();
        const TreasuryProxy = await ethers.getContractFactory("Proxy");
        initPayload = treasury.interface.encodeFunctionData("initialize", [0]);
        const treasuryProxy = await TreasuryProxy.deploy(treasury.address, initPayload);
        await treasuryProxy.deployed();
        treasury = await ethers.getContractAt("Treasury", treasuryProxy.address);

        await st.initialize(treasury.address, depository.address, distributor.address, unstakeRelayer.address);
        await depository.changeTreasury(treasury.address);

        const StakingVerifier = await ethers.getContractFactory("StakingVerifier");
        stakingVerifier = await StakingVerifier.deploy(olas.address, serviceRegistry.address,
            serviceRegistryTokenUtility.address, minStakingDeposit, timeForEmissions, maxNumServices, apyLimit);
        await stakingVerifier.deployed();
        const StakingFactory = await ethers.getContractFactory("StakingFactory");
        stakingFactory = await StakingFactory.deploy(stakingVerifier.address);
        await stakingFactory.deployed();

        const Collector = await ethers.getContractFactory("Collector");
        collector = await Collector.deploy(olas.address);
        await collector.deployed();
        const CollectorProxy = await ethers.getContractFactory("Proxy");
        initPayload = collector.interface.encodeFunctionData("initialize", []);
        const collectorProxy = await CollectorProxy.deploy(collector.address, initPayload);
        await collectorProxy.deployed();
        collector = await ethers.getContractAt("Collector", collectorProxy.address);

        const ActivityModule = await ethers.getContractFactory("ActivityModule");
        activityModule = await ActivityModule.deploy(olas.address, collector.address, multiSend.address);
        await activityModule.deployed();
        const Beacon = await ethers.getContractFactory("Beacon");
        beacon = await Beacon.deploy(activityModule.address);
        await beacon.deployed();

        const StakingManager = await ethers.getContractFactory("StakingManager");
        stakingManager = await StakingManager.deploy(olas.address, serviceManager.address, stakingFactory.address,
            safeModuleInitializer.address, gnosisSafeL2.address, beacon.address, collector.address, agentId, defaultHash);
        await stakingManager.deployed();
        const StakingManagerProxy = await ethers.getContractFactory("Proxy");
        initPayload = stakingManager.interface.encodeFunctionData("initialize", [gnosisSafeMultisig.address,
            gnosisSafeSameAddressMultisig.address, fallbackHandler.address]);
        const stakingManagerProxy = await StakingManagerProxy.deploy(stakingManager.address, initPayload);
        await stakingManagerProxy.deployed();
        stakingManager = await ethers.getContractAt("StakingManager", stakingManagerProxy.address);
        serviceParams.stakingManager = stakingManager.address;
        await deployer.sendTransaction({to: stakingManager.address, value: ethers.utils.parseEther("1")});

        const ExternalStakingDistributor = await ethers.getContractFactory("ExternalStakingDistributor");
        externalStakingDistributor = await ExternalStakingDistributor.deploy(olas.address, serviceManager.address,
            safeMultisigWithRecoveryModule.address, gnosisSafeSameAddressMultisig.address, fallbackHandler.address,
            multiSend.address, collector.address);
        await externalStakingDistributor.deployed();
        const ExternalStakingDistributorProxy = await ethers.getContractFactory("Proxy");
        initPayload = externalStakingDistributor.interface.encodeFunctionData("initialize", []);
        const externalStakingDistributorProxy = await ExternalStakingDistributorProxy.deploy(externalStakingDistributor.address, initPayload);
        await externalStakingDistributorProxy.deployed();
        externalStakingDistributor = await ethers.getContractAt("ExternalStakingDistributor", externalStakingDistributorProxy.address);
        await deployer.sendTransaction({to: externalStakingDistributor.address, value: ethers.utils.parseEther("1")});

        const MultisigGuard = await ethers.getContractFactory("MultisigGuard");
        multisigGuard = await MultisigGuard.deploy(serviceRegistryTokenUtility.address, externalStakingDistributor.address);
        await multisigGuard.deployed();
        const multisigGuardProxy = await ExternalStakingDistributorProxy.deploy(multisigGuard.address,
            multisigGuard.interface.encodeFunctionData("initialize", []));
        await multisigGuardProxy.deployed();
        multisigGuard = await ethers.getContractAt("MultisigGuard", multisigGuardProxy.address);

        const BridgeRelayer = await ethers.getContractFactory("BridgeRelayer");
        bridgeRelayer = await BridgeRelayer.deploy(olas.address);
        await bridgeRelayer.deployed();
        const GnosisDepositProcessorL1 = await ethers.getContractFactory("GnosisDepositProcessorL1");
        gnosisDepositProcessorL1 = await GnosisDepositProcessorL1.deploy(olas.address, depository.address,
            bridgeRelayer.address, bridgeRelayer.address);
        await gnosisDepositProcessorL1.deployed();
        const GnosisStakingProcessorL2 = await ethers.getContractFactory("GnosisStakingProcessorL2");
        gnosisStakingProcessorL2 = await GnosisStakingProcessorL2.deploy(olas.address, stakingManager.address,
            externalStakingDistributor.address, collector.address, bridgeRelayer.address, bridgeRelayer.address,
            gnosisDepositProcessorL1.address, chainId);
        await gnosisStakingProcessorL2.deployed();

        await collector.changeStakingManager(stakingManager.address);
        await collector.changeStakingProcessorL2(gnosisStakingProcessorL2.address);
        await stakingManager.changeStakingProcessorL2(gnosisStakingProcessorL2.address);
        await externalStakingDistributor.changeStakingProcessorL2(gnosisStakingProcessorL2.address);
        await externalStakingDistributor.changeMultisigGuard(multisigGuard.address);
        await gnosisDepositProcessorL1.setL2StakingProcessor(gnosisStakingProcessorL2.address);
        await depository.setDepositProcessorChainIds([gnosisDepositProcessorL1.address], [gnosisChainId]);

        const ActivityChecker = await ethers.getContractFactory("ModuleActivityChecker");
        activityChecker = await ActivityChecker.deploy(livenessRatio);
        await activityChecker.deployed();
        serviceParams.activityChecker = activityChecker.address;

        const StakingTokenLocked = await ethers.getContractFactory("StakingTokenLocked");
        stakingTokenImplementation = await StakingTokenLocked.deploy();
        await stakingTokenImplementation.deployed();
        await stakingVerifier.setImplementationsStatuses([stakingTokenImplementation.address], [true], true);
        initPayload = stakingTokenImplementation.interface.encodeFunctionData("initialize", [serviceParams]);
        let tx = await stakingFactory.createStakingInstance(stakingTokenImplementation.address, initPayload);
        let res = await tx.wait();
        const stakingTokenAddress = "0x" + res.logs[0].topics[2].slice(26);
        stakingTokenInstance = await ethers.getContractAt("StakingTokenLocked", stakingTokenAddress);

        const ExternalActivityChecker = await ethers.getContractFactory("StakingActivityChecker");
        externalActivityChecker = await ExternalActivityChecker.deploy(externalLivenessRatio);
        await externalActivityChecker.deployed();
        const StakingTokenV1 = await ethers.getContractFactory("StakingTokenV1");
        externalStakingTokenImplementationV1 = await StakingTokenV1.deploy();
        await externalStakingTokenImplementationV1.deployed();
        const StakingTokenV2 = await ethers.getContractFactory("StakingToken");
        externalStakingTokenImplementationV2 = await StakingTokenV2.deploy();
        await externalStakingTokenImplementationV2.deployed();
        await stakingVerifier.setImplementationsStatuses([externalStakingTokenImplementationV1.address,
            externalStakingTokenImplementationV2.address], [true, true], true);

        await serviceRegistry.changeManager(serviceManager.address);
        await serviceRegistryTokenUtility.changeManager(serviceManager.address);
        await serviceRegistry.changeMultisigPermission(gnosisSafeMultisig.address, true);
        await serviceRegistry.changeMultisigPermission(gnosisSafeSameAddressMultisig.address, true);
        await serviceRegistry.changeMultisigPermission(recoveryModule.address, true);

        await olas.approve(stakingTokenAddress, stakingSupply);
        await stakingTokenInstance.deposit(stakingSupply);
        await depository.createAndActivateStakingModels([gnosisChainId], [stakingTokenAddress], [fullStakeDeposit],
            [maxNumServices]);
        await collector.setOperationReceivers([rewardOperation, unstakeOperation, unstakeRetiredOperation],
            [distributor.address, treasury.address, unstakeRelayer.address]);
    });

    it("external reward is taxed twice: ESD split (17.5%) + Collector.protocolFactor (10% of the 80%) -> stOLAS share = 72% not 80%", async function () {
        this.timeout(1600000);
        const eth = (x) => ethers.utils.formatEther(x);
        const olasAmount = minStakingDeposit.mul(8); // 80,000 OLAS of protocol funds into the ESD

        console.log("\n============================================================");
        console.log(" PoC (L-1): double protocol fee on external V1 rewards (fee-MODEL observation)");
        console.log("============================================================");

        // ---- Set Collector protocol factor = 10% (1000 / 10000) ----
        await collector.changeProtocolFactor(1000);
        const protocolFactor = await collector.protocolFactor();
        console.log("[setup] Collector.protocolFactor:", protocolFactor.toString(), "( = 10.0% )");
        expect(protocolFactor).to.equal(1000);

        // ---- Fund the ExternalStakingDistributor with PROTOCOL OLAS ----
        await olas.approve(depository.address, initSupply);
        await depository.deposit(olasAmount, [], [], [], []);
        await depository.setExternalStakingDistributorChainIds([gnosisChainId], [externalStakingDistributor.address]);
        await depository.depositExternal([gnosisChainId], [olasAmount], [bridgePayload], [0]);

        // ---- Deploy a V1 staking proxy (stakingGuard 0) and stake an external service ----
        let externalServiceParams = {
            metadataHash: defaultHash, maxNumServices: 3, rewardsPerSecond: "5" + "0".repeat(14),
            minStakingDeposit: regDeposit, minNumStakingPeriods: 3, maxNumInactivityPeriods: 3, livenessPeriod: 10,
            timeForEmissions: 100, numAgentInstances: 1, agentIds, threshold: 0, configHash: HashZero,
            proxyHash: bytecodeHash, serviceRegistry: serviceRegistry.address, activityChecker: externalActivityChecker.address
        };
        const maxInactivity = externalServiceParams.maxNumInactivityPeriods * livenessPeriod + 1;
        let initPayload = externalStakingTokenImplementationV1.interface.encodeFunctionData("initialize",
            [externalServiceParams, serviceRegistryTokenUtility.address, olas.address]);
        let tx = await stakingFactory.createStakingInstance(externalStakingTokenImplementationV1.address, initPayload);
        let res = await tx.wait();
        const proxyV1 = "0x" + res.logs[0].topics[2].slice(26);
        const proxyV1Inst = await ethers.getContractAt("StakingTokenV1", proxyV1);

        // 80% collector / 17.5% protocol / 2.5% curatingAgent
        const cfgV1 = await externalStakingDistributor.wrapStakingConfig(AddressZero, 8000, 1750, 250, 0);
        await externalStakingDistributor.setStakingProxyConfigs([proxyV1], [cfgV1]);
        await olas.approve(proxyV1, stakingSupply);
        await proxyV1Inst.deposit(stakingSupply);

        // deployer stakes (owner path); msg.sender is recorded as curatingAgent
        await externalStakingDistributor.stake(proxyV1, 0, 0, defaultHash, deployer.address);
        const service = await serviceRegistry.getService(serviceId);
        const multisig = service.multisig;
        const multisigV1 = await ethers.getContractAt("GnosisSafe", multisig);

        // ---- Accrue a REAL V1 reward R ----
        let nonce = await multisigV1.nonce();
        await safeContracts.executeTxWithSigners(multisigV1, {
            to: multisig, value: 0, data: multisigV1.interface.encodeFunctionData("getThreshold", []),
            operation: 0, safeTxGas: 0, baseGas: 0, gasPrice: 0, gasToken: AddressZero, refundReceiver: AddressZero, nonce
        }, [deployer]);
        await helpers.time.increase(maxInactivity);
        await proxyV1Inst.checkpoint();
        const reward = await proxyV1Inst.calculateStakingReward(serviceId); // = R
        console.log("[reward] real accrued V1 reward R:", eth(reward), "OLAS");
        expect(reward).to.be.gt(0);

        // =====================================================================================
        // STEP 1: run the REAL ESD.claim. This applies the FIRST fee (the ESD split):
        //   Collector REWARD-operation balance = collectorAmount = 80% * R
        //   Collector.protocolBalance          += protocolAmount = 17.5% * R   (fee #1)
        //   curatingAgent(deployer)            += 2.5% * R
        // =====================================================================================
        const protocolBalBeforeClaim = await collector.protocolBalance();
        await externalStakingDistributor.claim([proxyV1], [serviceId]);

        // Collector REWARD-operation balance after the ESD split
        const rewardRB = await collector.mapOperationReceiverBalances(rewardOperation);
        const collectorRewardBalance = rewardRB.balance;                                  // = collectorAmount = 80% * R
        const protocolFromESD = (await collector.protocolBalance()).sub(protocolBalBeforeClaim); // = protocolAmount = 17.5% * R

        // Intended split constants for reporting
        const collectorAmount = reward.mul(8000).div(10000);   // 80% R
        const protocolAmountESD = reward.mul(1750).div(10000); // 17.5% R  (fee #1)
        console.log("\n--- STEP 1: after real ESD.claim (fee #1 = the ESD split) ---");
        console.log("[esd]   Collector REWARD-operation balance (collectorAmount = 80% R):", eth(collectorRewardBalance), "OLAS");
        console.log("[esd]   Collector.protocolBalance from ESD split (protocolAmount 17.5% R) [FEE #1]:", eth(protocolFromESD), "OLAS");
        expect(collectorRewardBalance).to.equal(collectorAmount);
        expect(protocolFromESD).to.equal(protocolAmountESD);

        // =====================================================================================
        // STEP 2: run the REAL Collector.relayTokens(REWARD). This applies the SECOND fee
        //   (protocolFactor on the REWARD balance) before relaying the remainder to L1:
        //   protocolAmount2 = protocolFactor * (80% * R) = 10% * 80% R = 8% R          (fee #2)
        //   relayed to L1 (Distributor = stOLAS holders) = 90% * (80% R) = 72% R
        // =====================================================================================
        const distributorBefore = await olas.balanceOf(distributor.address); // L1 receiver for REWARD
        const protocolBalBeforeRelay = await collector.protocolBalance();

        await collector.relayTokens(rewardOperation, bridgePayload);

        const relayedToDistributor = (await olas.balanceOf(distributor.address)).sub(distributorBefore); // to stOLAS holders
        const protocolFromRelay = (await collector.protocolBalance()).sub(protocolBalBeforeRelay);        // fee #2

        // Expected arithmetic
        const protocolAmount2 = collectorRewardBalance.mul(protocolFactor).div(10000); // 10% * 80% R = 8% R
        const relayedExpected = collectorRewardBalance.sub(protocolAmount2);           // 72% R

        console.log("\n--- STEP 2: after real Collector.relayTokens(REWARD) (fee #2 = protocolFactor on the 80% R) ---");
        console.log("[relay] protocolFactor take on the REWARD balance (10% * 80% R) [FEE #2]:", eth(protocolFromRelay), "OLAS");
        console.log("[relay] relayed to L1 Distributor (stOLAS-holder rewards) = 90% * 80% R  :", eth(relayedToDistributor), "OLAS");
        expect(protocolFromRelay).to.equal(protocolAmount2);
        expect(relayedToDistributor).to.equal(relayedExpected);

        // =====================================================================================
        // TALLY: total-to-protocol vs total-to-stOLAS-holders, expressed against R.
        // =====================================================================================
        const totalToProtocol = protocolFromESD.add(protocolFromRelay);  // 17.5% R + 8% R = 25.5% R
        const totalToStOLAS = relayedToDistributor;                      // 72% R
        const intendedStOLAS = collectorAmount;                          // 80% R  (what the ESD split earmarked for stOLAS)

        // Basis points of R
        const bps = (x) => x.mul(10000).div(reward).toString();

        console.log("\n------------------------------------------------------------");
        console.log(" TALLY (as a share of the external reward R =", eth(reward), "OLAS)");
        console.log("   total-to-protocol   = protocolAmount(ESD 17.5%R) + protocolFactor*collectorAmount(10%*80%R)");
        console.log("                       =", eth(protocolFromESD), "+", eth(protocolFromRelay), "=", eth(totalToProtocol),
            "OLAS  (", bps(totalToProtocol), "bps =", (Number(bps(totalToProtocol)) / 100).toFixed(2) + "% )");
        console.log("   total-to-stOLAS     = 90% * 80% R                =", eth(totalToStOLAS),
            "OLAS  (", bps(totalToStOLAS), "bps =", (Number(bps(totalToStOLAS)) / 100).toFixed(2) + "% )");
        console.log("   intended-to-stOLAS  = 80% R (the ESD split)      =", eth(intendedStOLAS),
            "OLAS  (", bps(intendedStOLAS), "bps = 80.00% )");
        console.log("------------------------------------------------------------");
        const stOLASPct = (Number(bps(totalToStOLAS)) / 100).toFixed(2);
        console.log(" external reward is taxed twice (ESD split + Collector.protocolFactor); stOLAS-holder share = "
            + stOLASPct + "% vs intended 80%");
        console.log("------------------------------------------------------------");

        // =====================================================================================
        // NON-FAILING RECORD (this is a documented MEASUREMENT, not a bug-claim):
        // assert exactly the arithmetic we measured so the test PASSES.
        // =====================================================================================
        // fee #1 = 17.5% R
        expect(bps(protocolFromESD)).to.equal("1750");
        // fee #2 = 10% of 80% R = 8% R
        expect(bps(protocolFromRelay)).to.equal("800");
        // total-to-protocol = 25.5% R
        expect(bps(totalToProtocol)).to.equal("2550");
        // total-to-stOLAS = 72% R (down from the intended 80% R)
        expect(bps(totalToStOLAS)).to.equal("7200");
        expect(bps(intendedStOLAS)).to.equal("8000");
        // conservation: every wei stays inside the protocol (no leakage) --
        // R = curator(2.5%) + protocol(25.5%) + stOLAS(72.0%)
        const curator = reward.sub(collectorAmount).sub(protocolAmountESD); // 2.5% R
        expect(totalToProtocol.add(totalToStOLAS).add(curator)).to.equal(reward);
        console.log(" conservation check: curator 2.5% + protocol 25.5% + stOLAS 72.0% == R (no funds leave the protocol)");

        console.log("\n MEASUREMENT RECORDED: fee-model question for the team -- protocolFactor stacks on the ESD's own");
        console.log(" protocolAmount split for external-V1 rewards. This may be intended; it is NOT a theft.\n");
    });
});
