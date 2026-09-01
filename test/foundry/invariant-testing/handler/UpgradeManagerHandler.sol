// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {HandlerBase, HandlerConfig} from "test/foundry/invariant-testing/handler/HandlerBase.sol";

/// @notice Everything the upgrade manager is allowed to do.
/// @dev One key owns all four singletons and both factories, and a factory owns the beacon its
///      wallets point at, so this actor can move every wallet in the protocol in one call. The
///      campaign gives it the two beacons, the pause release and the price ceiling, which is the
///      part of that reach a running protocol would actually use.
///
///      Each beacon entry point swaps to a second implementation and back. Both alternatives
///      subclass the production contract and add a view helper, so what a wallet runs afterwards
///      is the same logic on the same storage. The point is not that the new implementation
///      behaves differently, it is that a live wallet keeps its state and its bindings across the
///      swap and that every invariant still holds on the other side of one.
contract UpgradeManagerHandler is HandlerBase {

    /// @notice Implementation the device wallet beacon starts on
    address internal immutable deviceWalletImplV1;

    /// @notice Implementation the device wallet beacon swaps to
    address internal immutable deviceWalletImplV2;

    /// @notice Implementation the eSIM wallet beacon starts on
    address internal immutable eSIMWalletImplV1;

    /// @notice Implementation the eSIM wallet beacon swaps to
    address internal immutable eSIMWalletImplV2;

    /// @param config What every handler shares
    /// @param _deviceWalletImplV2 Second device wallet implementation to swap between
    /// @param _eSIMWalletImplV2 Second eSIM wallet implementation to swap between
    constructor(HandlerConfig memory config, address _deviceWalletImplV2, address _eSIMWalletImplV2)
        HandlerBase(config)
    {
        deviceWalletImplV1 = config.deviceWalletFactory.getCurrentDeviceWalletImplementation();
        eSIMWalletImplV1 = config.eSIMWalletFactory.getCurrentESIMWalletImplementation();
        deviceWalletImplV2 = _deviceWalletImplV2;
        eSIMWalletImplV2 = _eSIMWalletImplV2;
    }

    /// @notice The upgrade manager releases a pause the admin tripped
    function unpauseProtocol() external counted {
        vm.prank(upgradeManager);
        try registry.unpause() {
            state.recordCall("unpauseProtocol");
        } catch {
            state.recordRevert("unpauseProtocol");
        }
    }

    /// @notice The upgrade manager nominates the admin's successor, or withdraws a nomination
    /// @dev An owner call rather than an admin one, which is what stops a compromised admin key
    ///      from being the only thing able to remove itself. The nomination alternates between the
    ///      two admin addresses rather than picking a fresh one, so the role can travel and come
    ///      back; a one-way rotation onto an address that never hands it back would leave every
    ///      admin path unreachable for the rest of the run.
    ///
    ///      Reads `adminOfRecord` rather than `eSIMWalletAdmin()` for the alternation. The
    ///      accessor answers zero while a nomination is outstanding, so alternating on it would
    ///      keep nominating the same address and the role would never reach the successor.
    /// @param revoke Whether to nominate the sitting admin, which withdraws any outstanding request
    function requestAdminUpdate(bool revoke) external counted {
        address current = registry.adminOfRecord();
        address nominee = revoke ? current : (current == admin ? adminSuccessor : admin);

        vm.prank(upgradeManager);
        try registry.requestAdminUpdate(nominee) {
            state.recordCall("requestAdminUpdate");
        } catch {
            state.recordRevert("requestAdminUpdate");
        }
    }

    /// @notice The upgrade manager suspends the admin's powers protocol-wide
    /// @dev The state worth reaching is every admin entry point refusing its own key while the
    ///      address is still on the books, which is what a live incident looks like. The campaign
    ///      lifts it again through `enableAdmin`, so a run that suspends early still exercises the
    ///      admin paths afterwards.
    function disableAdmin() external counted {
        vm.prank(upgradeManager);
        try registry.disableAdmin() {
            state.recordCall("disableAdmin");
        } catch {
            state.recordRevert("disableAdmin");
        }
    }

    /// @notice The upgrade manager hands a suspended admin its powers back
    function enableAdmin() external counted {
        vm.prank(upgradeManager);
        try registry.enableAdmin() {
            state.recordCall("enableAdmin");
        } catch {
            state.recordRevert("enableAdmin");
        }
    }

    /// @notice The upgrade manager sets the ceiling wallets fall back to when they hold none
    /// @dev Picked off a ladder rather than bounded over a range, because a range wide enough to be
    ///      interesting would rarely land on the values worth exercising. Zero is on the ladder on
    ///      purpose: `setDefaultPriceCapUSDCents` refuses it, so that entry is what exercises the
    ///      rejection rather than the ceiling. The top of the ladder sits above what the admin can
    ///      charge, so the ceiling is sometimes binding and sometimes not.
    /// @param seed Chooses the ceiling
    function setDefaultPriceCap(uint256 seed) external counted {
        // Zero is in the ladder so a run reaches the registry's refusal of it.
        uint64[4] memory ladder = [uint64(0), 1, 1_000, 100_000_000];
        uint64 cap = ladder[bound(seed, 0, 3)];

        vm.prank(upgradeManager);
        try registry.setDefaultPriceCapUSDCents(cap) {
            state.recordCall("setDefaultPriceCap");
        } catch {
            state.recordRevert("setDefaultPriceCap");
        }
    }

    /// @notice Every device wallet in the protocol moves to the other implementation at once
    /// @param toV2 Which of the two implementations to point the beacon at
    function upgradeDeviceWalletBeacon(bool toV2) external counted {
        address target = toV2 ? deviceWalletImplV2 : deviceWalletImplV1;

        vm.prank(upgradeManager);
        try deviceWalletFactory.updateDeviceWalletImplementation(target) returns (address) {
            state.recordCall("upgradeDeviceWalletBeacon");
        } catch {
            state.recordRevert("upgradeDeviceWalletBeacon");
        }
    }

    /// @notice Every eSIM wallet in the protocol moves to the other implementation at once
    /// @param toV2 Which of the two implementations to point the beacon at
    function upgradeESIMWalletBeacon(bool toV2) external counted {
        address target = toV2 ? eSIMWalletImplV2 : eSIMWalletImplV1;

        vm.prank(upgradeManager);
        try eSIMWalletFactory.updateESIMWalletImplementation(target) returns (address) {
            state.recordCall("upgradeESIMWalletBeacon");
        } catch {
            state.recordRevert("upgradeESIMWalletBeacon");
        }
    }
}
