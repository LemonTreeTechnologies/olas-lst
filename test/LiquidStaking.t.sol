// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Test.sol";

import {LiquidStakingBase} from "./LiquidStakingBase.sol";

contract LiquidStakingTest is LiquidStakingBase {
    function testMultipleStakesUnstakes() public {
        console.log("=== Multiple Stakes-Unstakes Test ===");

        uint256 snapshot = vm.snapshot();

        console.log("L1");

        uint256 olasAmount = (MIN_STAKING_DEPOSIT * 5) / 4;
        uint256 numStakes = 18;

        uint256[] memory chainIds = _fillArray(GNOSIS_CHAIN_ID, numStakes);
        address[] memory stakingInstances = _fillArray(address(stakingTokenInstance), numStakes);
        bytes[] memory bridgePayloads = _fillArray(BRIDGE_PAYLOAD, numStakes);
        uint256[] memory values = _fillArray(0, numStakes);

        // Iterate over deposits
        for (uint256 i = 0; i < 1; i++) {
            console.log("Stake-Unstake iteration:", i);

            // Increase stake a bit every iteration
            olasAmount += 1;
            uint256 amountToStake = olasAmount * numStakes;

            // Approve and preview
            vm.prank(deployer);
            olas.approve(address(depository), amountToStake);
            uint256 previewAmount = st.previewDeposit(amountToStake);

            // Track totals before deposit
            uint256 stTotalAssetsBefore = st.totalAssets();
            uint256 stBalanceBefore = st.balanceOf(deployer);

            // Deposit
            vm.prank(deployer);
            depository.deposit(amountToStake, chainIds, stakingInstances, bridgePayloads, values);

            // Validate totalAssets increased by exact deposited OLAS
            uint256 stTotalAssetsAfter = st.totalAssets();
            uint256 stTotalAssetsAfterDiff = stTotalAssetsAfter - stTotalAssetsBefore;
            assertEq(stTotalAssetsAfterDiff, amountToStake, "totalAssets did not increase by deposited amount");

            // Validate stOLAS minted equals previewDeposit
            uint256 stBalanceAfter = st.balanceOf(deployer);
            uint256 stBalanceDiff = stBalanceAfter - stBalanceBefore;
            assertEq(stBalanceDiff, previewAmount, "minted stOLAS != previewDeposit");

            // Preview redeem of just-minted shares should be ~amountToStake (allow tiny rounding)
            uint256 redeemPreview = st.previewRedeem(stBalanceDiff);
            uint256 delta = amountToStake - redeemPreview;
            require(delta < 10, "previewRedeem deviates too much");

            uint256 stBalance = st.balanceOf(deployer);
            console.log("User stOLAS balance now:", stBalance);
            console.log("OLAS total assets on stOLAS:", stTotalAssetsAfter);

            uint256 veBalance = ve.getVotes(address(lock));
            console.log("Protocol current veOLAS balance:", veBalance);

            console.log("L2");

            console.log("OLAS rewards available on L2 staking contract:", stakingTokenInstance.availableRewards());

            // Increase the time for the livenessPeriod
            console.log("Wait for liveness period to pass");
            skip(LIVENESS_PERIOD);

            // Call the checkpoint
            console.log("Calling checkpoint by agent or manually");
            vm.prank(agent);
            stakingTokenInstance.checkpoint();

            uint256[] memory stakedServiceIds = stakingManager.getStakedServiceIds(address(stakingTokenInstance));
            console.log("Number of staked services in StakingManager:", stakedServiceIds.length);
            uint256 numStakedServices = stakingTokenInstance.getNumServiceIds();
            assertEq(numStakedServices, stakedServiceIds.length);

            // Check sync of staked balances on both chains
            uint256 stakedBalanceL1 = st.stakedBalance();
            uint256 stakedBalanceL2 = FULL_STAKE_DEPOSIT * stakedServiceIds.length;
            uint256 stakeBalanceRemainder = stakingManager.mapStakingProxyBalances(address(stakingTokenInstance));
            stakedBalanceL2 = stakedBalanceL2 + stakeBalanceRemainder;
            assertEq(stakedBalanceL1, stakedBalanceL2);
        }

        console.log("Test completed successfully");

        vm.revertTo(snapshot);
    }
}
