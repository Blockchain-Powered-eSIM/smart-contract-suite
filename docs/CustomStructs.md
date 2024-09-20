# Solidity API

## DataBundleDetails

Data Bundle related details stored in the eSIM wallet

```solidity
struct DataBundleDetails {
  string dataBundleID;
  uint256 dataBundlePrice;
}
```

## WebAuthnSignature

```solidity
struct WebAuthnSignature {
  bytes authenticatorData;
  string clientDataJSON;
  uint256 challengeIndex;
  uint256 typeIndex;
  uint256 r;
  uint256 s;
}
```

## Call

```solidity
struct Call {
  address dest;
  uint256 value;
  bytes data;
}
```

