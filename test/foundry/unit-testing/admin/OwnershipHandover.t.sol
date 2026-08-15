// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Errors} from "contracts/Errors.sol";
import {ProtocolAdmin} from "contracts/admin/ProtocolAdmin.sol";

import "test/utils/AdminBase.sol";

/// @notice Taking ownership, holding it, and giving it up again.
/// @dev Three destinations are reachable when this contract is retired: another admin contract, a
///      multisig holding the owner slot directly, or an ordinary account. All three go through the
///      same two-step handover, and each has its own test below because the failure that matters
///      is a handover that half completes.
///
///      Rotating the signer set is deliberately not one of them. That is a role change inside this
///      contract and the four protocol contracts keep the same owner throughout, which is covered
///      in `ProtocolAdmin.t.sol`.
contract OwnershipHandoverTest is AdminBase {

    function test_accept_isOpenToAnyoneOnceTheOfferIsMade() public {
        ProtocolAdmin next = _deployReplacement(7 days);
        address[] memory targets = _ownedContracts();

        _offerAllFourTo(address(next));

        vm.prank(outsider);
        next.acceptOwnershipBatch(targets);

        assertEq(registry.owner(), address(next));
        assertEq(eSIMWalletFactory.owner(), address(next));
    }

    /// @dev The offer is the decision, so accepting is not a privilege. What it must never do is
    ///      take something that was not offered.
    function test_accept_rejectsATargetThatOfferedNothing() public {
        ProtocolAdmin next = _deployReplacement(7 days);
        address[] memory targets = _ownedContracts();

        vm.expectRevert(
            abi.encodeWithSelector(ProtocolAdmin.OwnershipNotOffered.selector, address(registry))
        );
        next.acceptOwnershipBatch(targets);
    }

    /// @dev All four or none. A batch that took the first two would leave the deployment owned by
    ///      two different addresses with no record of which is which.
    function test_accept_takesNothingWhenOneTargetInTheBatchOfferedNothing() public {
        ProtocolAdmin next = _deployReplacement(7 days);
        address[] memory targets = _ownedContracts();

        bytes memory data = abi.encodeCall(Ownable2StepUpgradeable.transferOwnership, (address(next)));
        _runThroughTheDelay(address(registry), data, bytes32(uint256(1)));
        _runThroughTheDelay(address(lazyWalletRegistry), data, bytes32(uint256(2)));

        vm.expectRevert(
            abi.encodeWithSelector(ProtocolAdmin.OwnershipNotOffered.selector, address(deviceWalletFactory))
        );
        next.acceptOwnershipBatch(targets);

        assertEq(registry.owner(), address(protocolAdmin), "the first two must not have moved");
    }

    /// @dev A destination that never accepts leaves ownership where it is. That is what makes a
    ///      mistyped address recoverable rather than terminal.
    function test_handover_leavesOwnershipInPlaceUntilTheDestinationAccepts() public {
        _offerAllFourTo(outsider);

        assertEq(registry.owner(), address(protocolAdmin));
        assertEq(registry.pendingOwner(), outsider);

        // The offer is retractable for as long as it stands
        _runThroughTheDelay(
            address(registry),
            abi.encodeCall(Ownable2StepUpgradeable.transferOwnership, (address(protocolAdmin))),
            bytes32(uint256(9))
        );

        assertEq(registry.pendingOwner(), address(protocolAdmin));
        assertEq(registry.owner(), address(protocolAdmin));
    }

    /// @dev Replacing the admin contract with a differently configured one. The old contract stops
    ///      being owner the moment the new one accepts, and no proxy is redeployed.
    function test_handover_movesToAReplacementAdminContract() public {
        ProtocolAdmin next = _deployReplacement(7 days);
        address[] memory targets = _ownedContracts();

        _offerAllFourTo(address(next));
        next.acceptOwnershipBatch(targets);

        for(uint256 i = 0; i < targets.length; ++i) {
            assertEq(Ownable2StepUpgradeable(targets[i]).owner(), address(next));
        }

        // The retired contract can no longer reach anything, including through its guardian
        vm.prank(guardian);
        vm.expectRevert();
        protocolAdmin.unpauseInstantly(address(registry));

        vm.prank(eSIMWalletAdmin);
        registry.pause();

        // The replacement can, because the same guardian holds the role there too
        vm.prank(guardian);
        next.unpauseInstantly(address(registry));

        assertFalse(registry.paused());
    }

    /// @dev A multisig taking the owner slot directly, with no timelock in front of it. Reachable
    ///      on purpose, because the delay has to be something the protocol can choose to stop
    ///      paying for.
    function test_handover_movesToAnAccountHoldingTheOwnerSlotDirectly() public {
        _offerAllFourTo(user5);

        address[] memory targets = _ownedContracts();
        vm.startPrank(user5);
        for(uint256 i = 0; i < targets.length; ++i) {
            Ownable2StepUpgradeable(targets[i]).acceptOwnership();
        }
        vm.stopPrank();

        assertEq(registry.owner(), user5);

        vm.prank(user5);
        registry.setDefaultDataBundlePriceCap(6 ether);
        assertEq(registry.defaultDataBundlePriceCap(), 6 ether);
    }

    /// @dev None of the four will let their owner walk away, so a handover cannot end with nobody
    ///      holding the slot.
    function test_handover_cannotEndWithNoOwnerAtAll() public {
        bytes memory data = abi.encodeCall(Ownable.renounceOwnership, ());
        _schedule(address(registry), data, bytes32(0));

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        vm.expectRevert();
        protocolAdmin.execute(address(registry), 0, data, bytes32(0), bytes32(0));

        assertEq(registry.owner(), address(protocolAdmin));
    }

    function test_handover_rejectsATransferProposedByAnyoneButTheAdminContract() public {
        vm.prank(upgradeManager);
        vm.expectRevert();
        registry.transferOwnership(outsider);

        vm.prank(proposer);
        vm.expectRevert();
        registry.transferOwnership(outsider);
    }

    /// @dev The asymmetry the design has to live with. The admin key trips the pause because it is
    ///      the one watching, and the owner clears it. Moving only the owner leaves the hot key
    ///      able to stop the protocol without being able to hold it stopped.
    function test_pause_staysWithTheAdminKeyWhileTheReleaseMovesToTheContract() public {
        vm.prank(eSIMWalletAdmin);
        registry.pause();
        assertTrue(registry.paused());

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert();
        registry.unpause();

        vm.prank(address(protocolAdmin));
        vm.expectRevert();
        registry.pause();

        vm.prank(guardian);
        protocolAdmin.unpauseInstantly(address(registry));

        assertFalse(registry.paused());
    }

    /// @dev Scheduling a release rather than taking it instantly is legal and is the wrong thing to
    ///      do. Recorded here so the delay on this particular call is never mistaken for a safety
    ///      property.
    function test_pause_canAlsoBeReleasedThroughTheDelayIfNobodyIsInAHurry() public {
        vm.prank(eSIMWalletAdmin);
        registry.pause();

        _runThroughTheDelay(address(registry), abi.encodeCall(registry.unpause, ()), bytes32(0));

        assertFalse(registry.paused());
    }

    function test_accept_emitsOncePerTarget() public {
        ProtocolAdmin next = _deployReplacement(7 days);
        address[] memory targets = _ownedContracts();

        _offerAllFourTo(address(next));

        for(uint256 i = 0; i < targets.length; ++i) {
            vm.expectEmit(true, false, false, false, address(next));
            emit ProtocolAdmin.OwnershipAccepted(targets[i]);
        }

        next.acceptOwnershipBatch(targets);
    }

    function test_accept_doesNothingForAnEmptyBatch() public {
        ProtocolAdmin next = _deployReplacement(7 days);

        next.acceptOwnershipBatch(new address[](0));

        assertEq(registry.owner(), address(protocolAdmin));
    }

    /// @notice Offers all four contracts to one address, in a single operation
    function _offerAllFourTo(address _destination) private {
        address[] memory targets = _ownedContracts();
        uint256[] memory values = new uint256[](4);
        bytes[] memory payloads = new bytes[](4);

        for(uint256 i = 0; i < targets.length; ++i) {
            payloads[i] = abi.encodeCall(Ownable2StepUpgradeable.transferOwnership, (_destination));
        }

        vm.prank(proposer);
        protocolAdmin.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        protocolAdmin.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));
    }
}
