// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {MockERC20} from "./MockERC20.sol";

/// @notice A token that burns a cut of every transfer, so less arrives than was sent
/// @dev The protocol does not support these. This exists to pin what happens when one is added to
///      the currency table anyway.
contract MockFeeOnTransferERC20 is MockERC20 {

    uint256 private constant BPS_DENOMINATOR = 10_000;

    uint256 public immutable feeBps;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint256 _feeBps)
        MockERC20(_name, _symbol, _decimals)
    {
        feeBps = _feeBps;
    }

    /// @dev Minting and burning go through untouched, so a balance can be set up exactly.
    function _update(address _from, address _to, uint256 _value) internal override {
        if(_from == address(0) || _to == address(0)) {
            super._update(_from, _to, _value);
            return;
        }

        uint256 fee = (_value * feeBps) / BPS_DENOMINATOR;
        super._update(_from, _to, _value - fee);
        if(fee != 0) super._update(_from, address(0), fee);
    }
}
