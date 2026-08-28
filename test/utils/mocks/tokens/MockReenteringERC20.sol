// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {MockERC20} from "./MockERC20.sol";

/// @notice A token that calls back into a target while a transfer is in flight
/// @dev Stands in for the ERC-777 style callback. The re-entrant call is made once and its failure
///      is swallowed, so the test asserts on the outcome rather than on this token's own revert.
contract MockReenteringERC20 is MockERC20 {

    address public target;
    bytes public payload;
    bool public reentered;
    bool public reentryReverted;

    constructor(string memory _name, string memory _symbol, uint8 _decimals)
        MockERC20(_name, _symbol, _decimals)
    {}

    function setReentry(address _target, bytes calldata _payload) external {
        target = _target;
        payload = _payload;
        reentered = false;
        reentryReverted = false;
    }

    function _update(address _from, address _to, uint256 _value) internal override {
        super._update(_from, _to, _value);

        if(target == address(0) || reentered) return;

        reentered = true;
        (bool success,) = target.call(payload);
        reentryReverted = !success;
    }
}
