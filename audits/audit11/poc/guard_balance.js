/*global describe, beforeEach, it*/
//
// PoC (finding I-1): external-V1 reward custody — a Safe-controlling staker cannot capture protocol funds
// =========================================================================================
//
// BACKGROUND — the hypothesis under test:
//   Hypothesis: an account that stakes an external V1 service (permitted for
//   ANY caller when the proxy config's stakingGuard == address(0)) becomes the sole owner of the
//   service Safe and can therefore steal the V1 staking reward, because the MultisigGuard never
//   checks the multisig's OLAS balance.
//
//   This does NOT hold, because of who controls the reward. The V1 staking proxy gates claim/unstake to
//   the *service owner recorded inside the proxy* (StakingTokenV1._claim, line 717:
//   `if (msg.sender != sInfo.owner) revert OwnerOnly(...)`), and that recorded owner is the ESD
//   itself (the ESD is the account that calls `IStaking(stakingProxy).stake(serviceId)` in
//   `_deployAndStake`, so `sInfo.owner = msg.sender = ESD`). Consequently the reward is only ever
//   moved onto the service Safe *inside* the atomic `ESD.claim` -> proxy.claim -> _withdraw(multisig)
//   -> ESD._distributeRewards() call. There is no standing, attacker-drainable reward sitting on the
//   Safe between transactions: the same atomic call that pays the reward onto the Safe immediately
//   splits it 80% collector / 17.5% protocol / 2.5% curating-agent and empties the Safe.
//
//   The attacker owning the Safe can indeed sweep *whatever is on the Safe* — but after ESD.claim
//   that is ~0. The attacker's only real gain is the legitimate 2.5% curating-agent cut, which is
//   theirs by design because they staked the service (mapServiceIdCuratingAgents[serviceId] =
//   msg.sender = the staker). The protocol keeps >= 97.5%.
//
// WHAT THIS TEST PROVES DETERMINISTICALLY, ON THE REAL CONTRACTS (real StakingTokenV1, real ESD,
// real Collector, real Gnosis Safe + real MultisigGuard) — NO mocks beyond what setUp already uses:
//   1. The attacker CANNOT force the reward onto the Safe on their own: proxy.claim /
//      proxy.checkpointAndClaim / proxy.unstake all revert OwnerOnly for the attacker (only the ESD,
//      the recorded owner, may call them).
//   2. The real, permissionless ESD.claim distributes the reward correctly:
//         Collector OLAS      += ~80% + ~17.5%  (collectorAmount via topUpBalance + protocolAmount via topUpProtocol)
//         Collector.protocolBalance += ~17.5%   (the protocol's share)
//         curatingAgent(attacker) += ~2.5%      (their legitimate staker cut)
//      The attacker does NOT receive more than that 2.5%.
//   3. After ESD.claim there is ~0 OLAS on the Safe. The attacker's REAL guard-checked
//      execTransaction sweeping the Safe moves ~0 — there is nothing to steal.
//   4. Conclusion: attacker total OLAS gain over the whole scenario <= 2.5% + dust; protocol
//      (Collector + protocolBalance) kept >= 97.5%. The "drain" is a no-op on protocol funds.
//
const { expect } = require("chai");
const { ethers } = require("hardhat");
const helpers = require("@nomicfoundation/hardhat-network-helpers");
const safeContracts = require("@gnosis.pm/safe-contracts");

describe("PoC (I-1): a Safe-controlling staker cannot capture protocol funds on external-V1", function () {
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

    it("attacker can only take the 2.5% curator cut; proxy claim/unstake are ESD-owner-gated; Safe holds ~0 to drain", async function () {
        this.timeout(1600000);
        const eth = (x) => ethers.utils.formatEther(x);
        const olasAmount = minStakingDeposit.mul(8); // 80,000 OLAS of protocol funds into the ESD
        const attacker = signers[1];

        console.log("\n============================================================");
        console.log(" PoC (I-1): a Safe-controlling staker cannot capture protocol funds on external-V1");
        console.log("============================================================");

        // ---- Fund the ExternalStakingDistributor with PROTOCOL OLAS (deposit -> depositExternal) ----
        await olas.approve(depository.address, initSupply);
        await depository.deposit(olasAmount, [], [], [], []);
        await depository.setExternalStakingDistributorChainIds([gnosisChainId], [externalStakingDistributor.address]);
        await depository.depositExternal([gnosisChainId], [olasAmount], [bridgePayload], [0]);
        const esdFunded = await olas.balanceOf(externalStakingDistributor.address);
        console.log("[setup] ESD protocol OLAS balance:", eth(esdFunded));
        expect(esdFunded).to.equal(olasAmount);

        // ---- Deploy a V1 staking proxy with stakingGuard == address(0) (permissionless staking) ----
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

        // V1 config with stakingGuard = AddressZero, 80% collector / 17.5% protocol / 2.5% curatingAgent
        const cfgV1 = await externalStakingDistributor.wrapStakingConfig(AddressZero, 8000, 1750, 250, 0);
        await externalStakingDistributor.setStakingProxyConfigs([proxyV1], [cfgV1]);
        const [cfgGuard] = await externalStakingDistributor.unwrapStakingConfig(cfgV1);
        console.log("[setup] V1 proxy stakingGuard:", cfgGuard, "(address(0) => ANY caller may stake)");
        expect(cfgGuard).to.equal(AddressZero);

        // Fund the V1 proxy with rewards to distribute
        await olas.approve(proxyV1, stakingSupply);
        await proxyV1Inst.deposit(stakingSupply);

        // ---- ATTACKER stakes the service with agentInstance = attacker (deposit comes from ESD protocol OLAS) ----
        await externalStakingDistributor.connect(attacker).stake(proxyV1, 0, 0, defaultHash, attacker.address);

        // The attacker is the curating agent recorded for this service (their legitimate 2.5% cut).
        const curatingAgent = await externalStakingDistributor.mapServiceIdCuratingAgents(serviceId);
        console.log("[setup] recorded curatingAgent for the service:", curatingAgent, "(== attacker; their 2.5% is legit)");
        expect(curatingAgent).to.equal(attacker.address);

        // ---- The service Safe is owned SOLELY by the attacker; ESD + guard are modules, guard set ----
        const service = await serviceRegistry.getService(serviceId);
        const multisig = service.multisig;
        const multisigV1 = await ethers.getContractAt("GnosisSafe", multisig);
        const owners = await multisigV1.getOwners();
        const threshold = await multisigV1.getThreshold();
        console.log("[safe]  service multisig:", multisig);
        console.log("[safe]  owners:", owners, " threshold:", threshold.toString());
        expect(owners[0]).to.equal(attacker.address);
        expect(threshold).to.equal(1);

        // ---- Confirm the proxy records the ESD (NOT the attacker) as sInfo.owner ----
        const sInfo = await proxyV1Inst.mapServiceInfo(serviceId);
        console.log("[proxy] StakingTokenV1 sInfo.owner:", sInfo.owner, "(== ESD, the claim/unstake authority)");
        expect(sInfo.owner).to.equal(externalStakingDistributor.address);

        // ---- Accrue a REAL V1 staking reward. Bump the multisig nonce (liveness) as owner, then checkpoint. ----
        let nonce = await multisigV1.nonce();
        await safeContracts.executeTxWithSigners(multisigV1, {
            to: multisig, value: 0, data: multisigV1.interface.encodeFunctionData("getThreshold", []),
            operation: 0, safeTxGas: 0, baseGas: 0, gasPrice: 0, gasToken: AddressZero, refundReceiver: AddressZero, nonce
        }, [attacker]);
        await helpers.time.increase(maxInactivity);
        await proxyV1Inst.checkpoint();

        const reward = await proxyV1Inst.calculateStakingReward(serviceId);
        console.log("[reward] real accrued V1 reward for the service:", eth(reward), "OLAS");
        expect(reward).to.be.gt(0);

        // =====================================================================================
        // ASSERTION 1: the attacker CANNOT force the reward onto the Safe on their own.
        // proxy.claim / proxy.checkpointAndClaim / proxy.unstake are gated to sInfo.owner == ESD.
        // =====================================================================================
        console.log("\n--- ASSERTION 1: attacker cannot force the reward onto the Safe (OwnerOnly gates) ---");
        await expect(proxyV1Inst.connect(attacker).claim(serviceId)).to.be.reverted;
        console.log("[gate]  proxyV1.claim(serviceId) as attacker              : REVERTED (OwnerOnly)");
        await expect(proxyV1Inst.connect(attacker).checkpointAndClaim(serviceId)).to.be.reverted;
        console.log("[gate]  proxyV1.checkpointAndClaim(serviceId) as attacker  : REVERTED (OwnerOnly)");
        await expect(proxyV1Inst.connect(attacker).unstake(serviceId)).to.be.reverted;
        console.log("[gate]  proxyV1.unstake(serviceId) as attacker            : REVERTED (OwnerOnly)");

        // Sanity: reward is still unpaid, Safe still holds 0 OLAS (nothing landed).
        expect(await olas.balanceOf(multisig)).to.equal(0);
        console.log("[gate]  multisig OLAS after failed attacker claims        :", eth(await olas.balanceOf(multisig)), "OLAS (reward never landed)");

        // =====================================================================================
        // ASSERTION 2: the real permissionless ESD.claim distributes correctly.
        // Measure Collector OLAS gain, Collector.protocolBalance gain, and the attacker's (curator) gain.
        // =====================================================================================
        console.log("\n--- ASSERTION 2: real ESD.claim distributes 80% collector / 17.5% protocol / 2.5% curator ---");
        const attackerBefore = await olas.balanceOf(attacker.address);
        const collectorBefore = await olas.balanceOf(collector.address);
        const protocolBalBefore = await collector.protocolBalance();

        // Anyone (here: the attacker themselves) may call the permissionless ESD.claim.
        await externalStakingDistributor.connect(attacker).claim([proxyV1], [serviceId]);

        const attackerAfterClaim = await olas.balanceOf(attacker.address);
        const collectorAfter = await olas.balanceOf(collector.address);
        const protocolBalAfter = await collector.protocolBalance();

        const collectorGain = collectorAfter.sub(collectorBefore);         // collectorAmount + protocolAmount (both land on Collector)
        const protocolGain = protocolBalAfter.sub(protocolBalBefore);      // protocol's 17.5% (accounted in protocolBalance)
        const curatorGain = attackerAfterClaim.sub(attackerBefore);        // attacker == curatingAgent -> 2.5%

        // Intended split of R
        const intendedCollector = reward.mul(8000).div(10000);            // 80%
        const intendedProtocol = reward.mul(1750).div(10000);             // 17.5%
        const intendedCurator = reward.sub(intendedCollector).sub(intendedProtocol); // 2.5%
        const intendedCollectorTotal = intendedCollector.add(intendedProtocol);      // Collector OLAS receives 97.5%

        console.log("[claim] Collector OLAS received (collector 80% + protocol 17.5%):", eth(collectorGain), "OLAS");
        console.log("[claim] Collector.protocolBalance increased by (protocol 17.5%) :", eth(protocolGain), "OLAS");
        console.log("[claim] curatingAgent(attacker) OLAS received (their 2.5% cut)  :", eth(curatorGain), "OLAS");
        console.log("        --- intended split of R =", eth(reward), "OLAS ---");
        console.log("        collector 80.0%  :", eth(intendedCollector), "OLAS");
        console.log("        protocol  17.5%  :", eth(intendedProtocol), "OLAS");
        console.log("        curator    2.5%  :", eth(intendedCurator), "OLAS");

        // Collector OLAS balance rose by ~97.5% of R (collectorAmount + protocolAmount).
        expect(collectorGain).to.equal(intendedCollectorTotal);
        // protocolBalance rose by exactly the 17.5% protocol share.
        expect(protocolGain).to.equal(intendedProtocol);
        // The attacker (as curating agent) got ONLY the 2.5% cut -- not more.
        expect(curatorGain).to.equal(intendedCurator);
        expect(curatorGain.mul(10000).div(reward)).to.be.lte(250); // <= 2.5%

        // =====================================================================================
        // ASSERTION 3: after ESD.claim there is ~0 on the Safe -> the "drain" moves ~0.
        // =====================================================================================
        console.log("\n--- ASSERTION 3: no standing reward on the Safe; attacker's drain moves ~0 ---");
        const multisigAfterClaim = await olas.balanceOf(multisig);
        console.log("[drain] multisig OLAS after ESD.claim (nothing to steal):", eth(multisigAfterClaim), "OLAS");
        expect(multisigAfterClaim).to.be.lte(ethers.BigNumber.from(10)); // dust <= a few wei

        // The attacker, as sole Safe owner, runs a REAL guard-checked execTransaction sweeping the Safe.
        const attackerBeforeDrain = await olas.balanceOf(attacker.address);
        nonce = await multisigV1.nonce();
        const drainResp = await safeContracts.executeTxWithSigners(multisigV1, {
            to: olas.address, value: 0,
            data: olas.interface.encodeFunctionData("transfer", [attacker.address, multisigAfterClaim]),
            operation: 0, safeTxGas: 0, baseGas: 0, gasPrice: 0, gasToken: AddressZero, refundReceiver: AddressZero, nonce
        }, [attacker]);
        const drainRcpt = await drainResp.wait();
        const drained = (await olas.balanceOf(attacker.address)).sub(attackerBeforeDrain);
        console.log("[drain] attacker execTransaction status:", drainRcpt.status === 1 ? "SUCCESS (guard did NOT block)" : "FAILED");
        console.log("[drain] attacker drained from Safe: ~0  (actual:", eth(drained), "OLAS)");
        expect(drainRcpt.status).to.equal(1);            // the guard genuinely permits the owner-sweep...
        expect(drained).to.be.lte(ethers.BigNumber.from(10)); // ...but there is ~0 to sweep -> no theft

        // =====================================================================================
        // ASSERTION 4 (conclusion): attacker total gain <= 2.5% + dust; protocol kept >= 97.5%.
        // =====================================================================================
        console.log("\n--- ASSERTION 4: conclusion ---");
        const attackerTotalGain = (await olas.balanceOf(attacker.address)).sub(attackerBefore);
        const protocolKept = collectorGain; // 97.5% of R now held by the Collector (collector + protocol shares)
        console.log("[concl] attacker TOTAL OLAS gain over the whole scenario:", eth(attackerTotalGain), "OLAS");
        console.log("[concl] protocol (Collector) kept                       :", eth(protocolKept), "OLAS");
        console.log("[concl] attacker share of R:", attackerTotalGain.mul(10000).div(reward).toString(),
            "bps  |  protocol share of R:", protocolKept.mul(10000).div(reward).toString(), "bps");

        // attacker total <= 2.5% + a few wei dust
        expect(attackerTotalGain).to.be.lte(intendedCurator.add(ethers.BigNumber.from(10)));
        // protocol kept >= 97.5%
        expect(protocolKept).to.be.gte(intendedCollectorTotal);
        expect(protocolKept.mul(10000).div(reward)).to.be.gte(9750); // >= 97.5%

        console.log("\n DISPROOF PASSED: the attack does NOT steal protocol funds. Attacker gets only the legit 2.5%");
        console.log(" curator cut; Collector/protocol keep >= 97.5%; the Safe holds ~0 after the atomic ESD.claim.\n");
    });
});
