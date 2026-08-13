// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockESIMWallet.sol";

/// @notice One deployed wallet pair for the stateless fuzz files to aim at.
/// @dev Deployed once in setUp rather than per run. Nothing in these files changes protocol state
///      on the paths being fuzzed, so a fresh deployment per run would only pay the cost.
///
///      Deliberately no vm.ffi anywhere below this. WebAuthnSigner spawns a node process per call,
///      which at these run counts is unusable, and none of the malformed-input cases need a
///      signature that verifies. The valid-signature cases are unit tests.
abstract contract FuzzBase is DeployerBase {

    MockDeviceWallet internal fuzzDeviceWallet;
    MockESIMWallet internal fuzzESIMWallet;

    /// @dev The header the signature format reserves: one version byte and six validUntil bytes.
    ///      Matches SIGNATURE_HEADER_LENGTH in Account4337, which is private there.
    uint256 internal constant SIGNATURE_HEADER_LENGTH = 7;

    /// @dev The shortest signature either entry point will look past. Both return early on
    ///      `length <= SIGNATURE_HEADER_LENGTH + 32`, so 40 is the first length that gets decoded.
    uint256 internal constant SHORTEST_DECODED_SIGNATURE = SIGNATURE_HEADER_LENGTH + 32 + 1;

    /// @dev Identifiers are capped at 64 bytes at every binding site, so the fuzz sweeps a little
    ///      past that rather than into the kilobytes.
    uint256 internal constant MAX_FUZZED_IDENTIFIER_LENGTH = 80;

    /// @notice Deploys the wallet pair every fuzz file works against
    function _deployFuzzWallets() internal {
        string[] memory deviceUniqueIdentifiers = new string[](1);
        bytes32[2][] memory listOfKeys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        deviceUniqueIdentifiers[0] = customDeviceUniqueIdentifiers[0];
        listOfKeys[0] = pubKey1;
        salts[0] = 31337;
        deposits[0] = 0;

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(
            deviceUniqueIdentifiers,
            listOfKeys,
            salts,
            deposits
        );

        fuzzDeviceWallet = MockDeviceWallet(payable(wallets[0].deviceWallet));
        fuzzESIMWallet = MockESIMWallet(payable(wallets[0].eSIMWallet));

        // A bind never carries ETH access, so the owner grants it here. The pull path is what most
        // of these suites are measuring, and it is closed until this call.
        vm.prank(address(fuzzDeviceWallet));
        fuzzDeviceWallet.toggleAccessToETH(address(fuzzESIMWallet), true);
    }

    /// @notice Builds a string of the requested byte length out of a repeating filler
    /// @dev Identifier length is what the bounds care about, not the characters, so the content is
    ///      arbitrary as long as the length is exact.
    /// @param _length How many bytes the returned string should hold
    function _stringOfLength(uint256 _length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(_length);
        for (uint256 i = 0; i < _length; ++i) {
            buffer[i] = bytes1(uint8(97 + (i % 26)));
        }
        return string(buffer);
    }
}
