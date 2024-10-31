// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@account-abstraction/contracts/interfaces/IStakeManager.sol";

contract MockStakeManager is IStakeManager {
    mapping(address => DepositInfo) private deposits;

    /**
     * Get deposit info for the specified account.
     * @param account The account to query.
     * @return info Full deposit information of the given account.
     */
    function getDepositInfo(address account)
        external
        view
        override
        returns (DepositInfo memory info)
    {
        return deposits[account];
    }

    /**
     * Get account balance for gas payment.
     * @param account The account to query.
     * @return The deposit amount of the account.
     */
    function balanceOf(address account)
        external
        view
        override
        returns (uint256)
    {
        return deposits[account].deposit;
    }

    /**
     * Add to the deposit of the given account.
     * Emits a Deposited event.
     * @param account The account to add to.
     */
    function depositTo(address account) external payable override {
        deposits[account].deposit += msg.value;
        emit Deposited(account, deposits[account].deposit);
    }

    /**
     * Add to the account's stake and set unstake delay.
     * @param _unstakeDelaySec The new lock duration before withdrawal.
     */
    function addStake(uint32 _unstakeDelaySec) external payable override {
        DepositInfo storage info = deposits[msg.sender];
        info.stake += uint112(msg.value);
        info.staked = true;
        info.unstakeDelaySec = _unstakeDelaySec;
        emit StakeLocked(msg.sender, info.stake, _unstakeDelaySec);
    }

    /**
     * Attempt to unlock the stake.
     * Emits a StakeUnlocked event.
     */
    function unlockStake() external override {
        DepositInfo storage info = deposits[msg.sender];
        require(info.staked, "No active stake");
        info.withdrawTime = uint48(block.timestamp + info.unstakeDelaySec);
        info.staked = false;
        emit StakeUnlocked(msg.sender, info.withdrawTime);
    }

    /**
     * Withdraw from the unlocked stake after the delay.
     * Emits a StakeWithdrawn event.
     * @param withdrawAddress The address to send withdrawn value.
     */
    function withdrawStake(address payable withdrawAddress) external override {
        DepositInfo storage info = deposits[msg.sender];
        require(!info.staked, "Stake is locked");
        require(block.timestamp >= info.withdrawTime, "Unlock delay not passed");

        uint256 amount = info.stake;
        info.stake = 0;
        withdrawAddress.transfer(amount);
        emit StakeWithdrawn(msg.sender, withdrawAddress, amount);
    }

    /**
     * Withdraw from the deposit.
     * Emits a Withdrawn event.
     * @param withdrawAddress The address to send withdrawn value.
     * @param withdrawAmount The amount to withdraw.
     */
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external override {
        require(deposits[msg.sender].deposit >= withdrawAmount, "Insufficient deposit");

        deposits[msg.sender].deposit -= withdrawAmount;
        withdrawAddress.transfer(withdrawAmount);
        emit Withdrawn(msg.sender, withdrawAddress, withdrawAmount);
    }
}
