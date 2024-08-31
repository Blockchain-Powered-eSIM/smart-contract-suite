pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

/// @notice Data Bundle related details stored in the eSIM wallet
struct DataBundleDetails {
    string dataBundleID;
    uint256 dataBundlePrice;
}

/// @notice Details related to eSIM purchased by the fiat user
struct ESIMDetails {
    DataBundleDetails[] history;
}

/// @notice Struct to store list of all eSIMs associated with a device
struct AssociatedESIMIdentifiers {
    string[] eSIMIdentifiers;
}
