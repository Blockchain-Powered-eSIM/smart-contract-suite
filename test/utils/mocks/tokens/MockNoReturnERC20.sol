// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

/// @notice A token whose `transfer` returns nothing, the way USDT does
/// @dev Written out rather than inherited, because the missing return value is the whole point and
///      no ERC-20 base can express it. Every path that moves one of these has to use SafeERC20.
contract MockNoReturnERC20 {

    error NotEnoughBalance(uint256 balance, uint256 amount);

    string public constant name = "No Return Token";
    string public constant symbol = "NRT";
    uint8 public constant decimals = 6;

    mapping(address account => uint256 amount) public balanceOf;

    function mint(address _to, uint256 _amount) external {
        balanceOf[_to] += _amount;
    }

    function transfer(address _to, uint256 _amount) external {
        uint256 balance = balanceOf[msg.sender];
        if(balance < _amount) revert NotEnoughBalance(balance, _amount);

        balanceOf[msg.sender] = balance - _amount;
        balanceOf[_to] += _amount;
    }
}
