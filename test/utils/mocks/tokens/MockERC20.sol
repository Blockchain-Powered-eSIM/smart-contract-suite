// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A plain ERC-20 with the decimals set per instance
/// @dev Decimals are a constructor argument because the payment path converts cents into a token's
///      own smallest unit, so a suite that only ever saw 18 would not exercise the conversion.
contract MockERC20 is ERC20 {

    uint8 private immutable _tokenDecimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) ERC20(_name, _symbol) {
        _tokenDecimals = _decimals;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}
