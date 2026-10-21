# Solidity API

## IPausable

Minimal view of the pause a guardian is allowed to raise and release

Both, because a guardian does both without waiting, even while the admin key is suspended.

### pause

```solidity
function pause() external
```

Stops the protocol's guarded purchase and pull paths

### unpause

```solidity
function unpause() external
```

Clears the pause

