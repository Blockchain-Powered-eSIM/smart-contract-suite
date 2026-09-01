// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {LazyWalletRegistryHandler} from "./LazyWalletRegistryHandler.sol";
import {RegistryHandler} from "./RegistryHandler.sol";
import {DeviceWalletHandler} from "./DeviceWalletHandler.sol";
import {DeviceWalletFactoryHandler} from "./DeviceWalletFactoryHandler.sol";
import {ESIMWalletHandler} from "./ESIMWalletHandler.sol";
import {ESIMWalletFactoryHandler} from "./ESIMWalletFactoryHandler.sol";
import {PaymentAdapterHandler} from "./PaymentAdapterHandler.sol";

/// @notice Inherits from all the handlers to expose all entry points in a single contract.
///         Manages environment changes (e.g. current actor, current token, mocks setup, etc.).
abstract contract Handlers is
    LazyWalletRegistryHandler,
    RegistryHandler,
    DeviceWalletHandler,
    DeviceWalletFactoryHandler,
    ESIMWalletHandler,
    ESIMWalletFactoryHandler,
    PaymentAdapterHandler
{
    function setCurrentActor(uint256 entropy) public {
        actor = actors[entropy % actors.length];
    }
}
