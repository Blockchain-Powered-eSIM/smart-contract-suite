// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";

/// @notice Drives test/utils/ffi/webauthn-signer.js so a test can obtain a WebAuthn assertion over
///         a challenge it chooses.
/// @dev A captured assertion cannot be reused for a different challenge. The challenge is embedded
///      in the clientDataJSON that the P256 signature covers, so any test that changes how the
///      challenge is derived has to sign again rather than edit a fixture. This shells out through
///      `vm.ffi`, which is enabled in foundry.toml.
library WebAuthnSigner {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string private constant NODE = "node";
    string private constant SCRIPT = "test/utils/ffi/webauthn-signer.js";

    /// @notice The P256 public key the harness signs with, in the shape a wallet is deployed with.
    function publicKey() internal returns (bytes32[2] memory) {
        string[] memory args = new string[](3);
        args[0] = NODE;
        args[1] = SCRIPT;
        args[2] = "pubkey";

        (bytes32 x, bytes32 y) = abi.decode(vm.ffi(args), (bytes32, bytes32));
        return [x, y];
    }

    /// @notice An ABI encoded WebAuthnSignature over `challenge`, in the form the wallet expects as
    ///         the body of a version 1 signature.
    function sign(bytes memory challenge) internal returns (bytes memory) {
        string[] memory args = new string[](4);
        args[0] = NODE;
        args[1] = SCRIPT;
        args[2] = "sign";
        args[3] = vm.toString(challenge);

        return vm.ffi(args);
    }
}
