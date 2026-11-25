# Arithmetic Precision Loss

An ERC4626-style vault rounds share conversions down and values itself by its raw token balance. A first-depositor inflation (donation) attack makes the next depositor's shares round to zero.

## Files

| Path | Role |
|---|---|
| `src/InsecureVault.sol` | Vulnerable: 1:1 shares, balance-based accounting, no zero-share check |
| `src/InflationAttacker.sol` | Attacker: deposit 1 wei, donate, redeem after the victim |
| `src/SecureVault.sol` | Fixed: shares carry 18 extra decimals, multiply before divide |
| `src/MockERC20.sol` | Test token |
| `test/PrecisionLoss.t.sol` | Exploit, fix, threshold, ordering and fuzz tests |
| `arithmetic-precision-loss-report.md` | Full write-up |

## Running

```bash
forge install foundry-rs/forge-std
forge test -vvv
forge test --match-test testFuzz --fuzz-runs 10000
```

This module has no OpenZeppelin dependency.
