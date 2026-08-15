// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IStakeManager} from "@account-abstraction/contracts/interfaces/IStakeManager.sol";

/// @notice Stand-in for the EntryPoint's deposit and stake accounting
contract MockStakeManager is IStakeManager {
    mapping(address => DepositInfo) private deposits;

    /// @notice Get deposit info for the specified account
    /// @param account The account to query
    /// @return info Full deposit information of the given account
    function getDepositInfo(address account)
        external
        view
        override
        returns (DepositInfo memory info)
    {
        return deposits[account];
    }

    /// @notice Get account balance for gas payment
    /// @param account The account to query
    /// @return The deposit amount of the account
    function balanceOf(address account)
        external
        view
        override
        returns (uint256)
    {
        return deposits[account].deposit;
    }

    /// @notice Add to the deposit of the given account
    /// @param account The account to add to
    function depositTo(address account) public payable override {
        // The ETH stays here. The real EntryPoint holds a deposit until the account withdraws it
        // or an operation spends it, so forwarding it on would credit the deposit and hand the
        // account the money as well, and leave withdrawTo spending ETH this contract never kept.
        deposits[account].deposit += msg.value;

        emit Deposited(account, deposits[account].deposit);
    }

    /// @notice Add to the account's stake and set the unstake delay
    /// @param _unstakeDelaySec The new lock duration before withdrawal
    function addStake(uint32 _unstakeDelaySec) external payable override {
        DepositInfo storage info = deposits[msg.sender];
        info.stake += uint112(msg.value);
        info.staked = true;
        info.unstakeDelaySec = _unstakeDelaySec;
        emit StakeLocked(msg.sender, info.stake, _unstakeDelaySec);
    }

    /// @notice Start the unlock delay on the caller's stake
    function unlockStake() external override {
        DepositInfo storage info = deposits[msg.sender];
        require(info.staked, "No active stake");
        info.withdrawTime = uint48(block.timestamp + info.unstakeDelaySec);
        info.staked = false;
        emit StakeUnlocked(msg.sender, info.withdrawTime);
    }

    /// @notice Withdraw from the unlocked stake once the delay has passed
    /// @param withdrawAddress The address to send withdrawn value
    function withdrawStake(address payable withdrawAddress) external override {
        DepositInfo storage info = deposits[msg.sender];
        require(!info.staked, "Stake is locked");
        require(block.timestamp >= info.withdrawTime, "Unlock delay not passed");

        uint256 amount = info.stake;
        info.stake = 0;
        withdrawAddress.transfer(amount);
        emit StakeWithdrawn(msg.sender, withdrawAddress, amount);
    }

    /// @notice Withdraw from the deposit
    /// @param withdrawAddress The address to send withdrawn value
    /// @param withdrawAmount The amount to withdraw
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external override {
        require(deposits[msg.sender].deposit >= withdrawAmount, "Insufficient deposit");

        deposits[msg.sender].deposit -= withdrawAmount;
        withdrawAddress.transfer(withdrawAmount);
        emit Withdrawn(msg.sender, withdrawAddress, withdrawAmount);
    }

    /// @notice Treats a plain transfer as a deposit for the sender
    receive() external payable {
        depositTo(msg.sender);
    }
}
