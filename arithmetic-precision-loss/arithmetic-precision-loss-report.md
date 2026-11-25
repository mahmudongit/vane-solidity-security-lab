# Security Audit Report: Arithmetic Precision Loss in an ERC4626-Style Vault (First-Depositor Inflation Attack)

**Auditor:** Vane (@vanebuilds_)
**Scope:** `InsecureVault.sol` (vulnerable), `InflationAttacker.sol` (attacker), `SecureVault.sol` (fix)
**Classification:** Arithmetic Precision Loss / Rounding / Share Price Manipulation
**Status:** ⚠️ Pending `forge test`. Expected values below come from an integer-exact Python model of both vaults; replace this line with the result once the suite has been run.

---

## 1. Executive Summary

`InsecureVault` mints shares 1:1 for the first deposit, rounds every conversion **down**, and values the vault by its raw token balance. An attacker deposits 1 wei to become the only shareholder, then **donates** tokens straight to the vault. One share is now worth thousands of tokens, so a later depositor's shares round down to **zero** (or to a fraction of what they paid for). The attacker redeems their share and takes the victim's deposit.

The fix scales shares to **18 extra decimals of precision** and keeps the multiply-before-divide order. A share becomes worth about 1e-18 of an asset unit, so rounding can only cost a depositor less than one share, which is dust.

| Metric | Value |
|---|---|
| Vulnerability | Share-price inflation through rounding to zero (donation attack) |
| Severity | Critical for any vault holding user funds with an empty or near-empty start |
| Attacker cost (lab) | 1 wei deposit + a donation that is recovered on redeem |
| Attacker profit (lab) | 10,000 tokens (the victim's entire deposit) |
| Preconditions | Vault is empty or has a tiny supply; `totalAssets()` uses the raw token balance; the attacker can act before the victim's deposit; no zero-share check |

---

## 2. Vulnerability Overview

### What is precision loss?

Solidity has no decimals. `7 / 10` is `0`. Any division throws away the remainder, so a calculation that is exact on paper can lose value in integers. In a vault, that lost value belongs to someone.

### How vault shares work

```
shares = assets * totalSupply / totalAssets
```

If the vault holds 1,000 tokens and 1,000 shares exist, a 100-token deposit mints 100 shares. The number of shares is rounded **down**, so the depositor can lose up to one share's worth of value.

That rounding is harmless when a share is worth a tiny amount. It is catastrophic when one share is worth thousands of tokens.

### Why a donation breaks it

`totalAssets()` is `asset.balanceOf(address(this))`. Transferring tokens to the vault changes it without minting any shares. An attacker who owns 1 share can raise the price of that share to any amount they can afford:

1. Attacker deposits **1 wei** and receives **1 share**.
2. Attacker transfers **10,000 tokens** directly to the vault. `totalAssets` is now 10,000e18 + 1 with 1 share outstanding.
3. Victim deposits **10,000 tokens**: `shares = 10,000e18 * 1 / (10,000e18 + 1) = 0`.
4. The victim's tokens are taken and **no shares are minted**.
5. Attacker redeems 1 share and receives everything: 20,000e18 + 1.

---

## 3. Vulnerable Contract: InsecureVault

**File:** `src/InsecureVault.sol`

```solidity
function totalAssets() public view returns (uint256) {
    return asset.balanceOf(address(this));      // VULNERABLE: anyone can change this
}

function convertToShares(uint256 assets) public view returns (uint256) {
    if (totalSupply == 0) return assets;        // VULNERABLE: 1 asset unit = 1 share
    return (assets * totalSupply) / totalAssets();   // floors; can be 0
}

function deposit(uint256 assets) external returns (uint256 shares) {
    shares = convertToShares(assets);           // priced before the deposit lands
    asset.transferFrom(msg.sender, address(this), assets);   // VULNERABLE: no `shares > 0` check
    totalSupply += shares;
    balanceOf[msg.sender] += shares;
}
```

**Root cause:** shares have no more precision than the asset, so one share can be worth an arbitrarily large amount once the balance is inflated. Combined with floor rounding and no zero-share check, a depositor can pay and receive nothing.

---

## 4. Attack Contract: InflationAttacker

**File:** `src/InflationAttacker.sol`

| Phase | Action | Vault state after |
|---|---|---|
| 1. Front-run | `setup(1, donation)`: deposit 1 wei, then transfer `donation` tokens directly to the vault | 1 share outstanding, `totalAssets` = donation + 1 |
| 2. Victim | Victim deposits | `shares = victimDeposit * 1 / (donation + 1)`; 0 when `victimDeposit <= donation` |
| 3. Back-run | `cashOut()`: redeem every share | Attacker receives the whole vault |

The donation is **not a loss** for the attacker. They hold (almost) all of the shares, so they get it back on redeem. What they need is enough capital in hand to make the donation at the time of the victim's transaction. A single-transaction flash loan does not span the victim's separate transaction, so this variant needs real capital.

---

## 5. Proof of Concept

**File:** `test/PrecisionLoss.t.sol`

### 5.1 Total theft on the vulnerable vault

```solidity
attackerI.setup(1, 10_000e18);                       // 1 share, then donate 10,000
uint256 victimShares = insecure.deposit(10_000e18);  // victim deposits 10,000
assertEq(victimShares, 0);                           // ...and gets nothing
uint256 received = attackerI.cashOut();
assertEq(received - (10_000e18 + 1), 10_000e18);     // profit == the victim's whole deposit
```

### 5.2 Smaller donation, still a large loss

With a donation of 5,000 tokens and a victim deposit of 10,000, the victim receives 1 share instead of about 2. Redeeming returns 7,500 tokens: a **2,500 token (25%) loss**, which is exactly the attacker's profit.

### 5.3 Same attack against the fixed vault

```solidity
attackerS.setup(1, 10_000e18);                       // attacker gets 1e18 shares for 1 wei
uint256 victimShares = secure.deposit(10_000e18);
assertEq(victimShares, 999_999_999_999_999_999);     // about 1e18 shares, not zero
// victim redeems 10,000e18 - 5,000 wei; attacker nets 5,000 wei
```

The victim loses **5,000 wei** (5e-15 of one token). The attacker's "profit" is the same 5,000 wei after locking up 10,000 tokens.

### 5.4 The threshold moves by a factor of 1e18

The victim receives zero shares when `victimDeposit * totalSupply < totalAssets`. With a 1e6-wei deposit:

| Vault | Donation that gives the victim 1 share | Donation that gives the victim 0 shares |
|---|---|---|
| Insecure | 999,999 | 1,000,000 (= deposit) |
| Secure | 1e24 - 1 | 1e24 (= deposit × 1e18) |

For a one-token deposit the secure vault needs a donation of about 1e36 wei, more than the supply of any real token.

### 5.5 Fuzz tests on the fixed vault

- `testFuzz_Secure_InflationAttackNeverProfitable`: for any attacker deposit up to 1e24, donation up to 1e30 and victim deposit of at least one token, the victim always receives shares, loses at most 0.001% of the deposit, and the attacker gains at most 0.001% of it.
- `testFuzz_Secure_RoundTripNeverProfits`: depositing and immediately redeeming never returns more than was deposited (rounding always favours the vault).

The first property was checked against both vaults in the model: **0 violations in 400,000 samples on the fixed vault** (worst relative loss 1e-6) and **66,403 violations in 100,000 samples on the insecure vault** (loss up to 100%), so the property detects the bug.

---

## 6. Impact Assessment

| Factor | Rating | Notes |
|---|---|---|
| Severity | Critical | Total loss of the first victim's deposit |
| Likelihood | High for new or empty vaults | The attacker only needs capital and the ability to act before the victim |
| Attack cost | The donation (recovered) plus gas | Profit equals the victim's deposit |
| Affected users | Early depositors | A seeded vault with a large supply is far harder to manipulate |

### Real-World Parallels

Both incidents below were **Compound v2 forks**, not ERC4626 vaults, but they share the same root cause: a donation inflates the exchange rate of an empty market and rounding then lets the attacker extract value.

| Incident | Date | Chain | Reported loss | What happened |
|---|---|---|---|---|
| Hundred Finance | April 15, 2023 | Optimism | about $7M | Attacker inflated the exchange rate of an empty hWBTC market by donating WBTC (PeckShield reported 200 WBTC), then exploited a rounding error when redeeming |
| Sonne Finance | May 14, 2024 | Optimism | about $20M | A "known donation attack" on Compound v2 forks, exploiting a newly listed market with no supply |

Loss figures differ slightly between sources, so treat them as approximate. Sonne's post-mortem also reports that about $6.5M of the remaining funds was saved by adding roughly $100 worth of VELO to the markets, which is a concrete example of why seeding matters.

---

## 7. Mitigation Analysis

### 7.1 Fix: higher-precision shares, multiply before divide

**File:** `src/SecureVault.sol`

```solidity
uint256 public constant PRECISION = 1e18;

function convertToShares(uint256 assets) public view returns (uint256) {
    if (totalSupply == 0) return assets * PRECISION;          // 1 asset unit = 1e18 shares
    return (assets * totalSupply) / totalAssets();            // multiply first, divide last
}
```

**Why it works:** rounding can only remove less than one share, and one share is now worth about 1e-18 of an asset unit. To zero out a victim the attacker needs a donation of at least `victimDeposit × 1e18`.

### 7.2 Why "multiply before divide" alone is not enough

The vulnerable vault **already multiplies first**, and it is still exploitable. The ordering matters (`(7 / 10) * 3 = 0`, but `7 * 3 / 10 = 2`, see `test_MultiplyBeforeDivide_KeepsPrecision`), but the attack works because of share granularity, not operation order. The scaling is what changes the outcome.

### 7.3 Limits of this fix

1. **Dust deposits and huge donations.** If the donation reaches `victimDeposit × 1e18`, the attack works again. For tiny deposits this threshold can be reachable.
2. **Overflow.** `assets * totalSupply` must fit in 256 bits. With 1e18 scaling this holds for the tested ranges, but production code should use a full-precision `mulDiv`.
3. **Division by zero** if shares exist but `totalAssets()` is zero.
4. **Donation to an empty vault.** The first depositor receives the donated balance as a windfall, because first-mint pricing ignores it.
5. **Balance-based accounting** is still manipulable. The fix limits the damage but does not remove the ability to change `totalAssets()`.

### 7.4 Other mitigations (not implemented here)

- **Virtual shares and assets.** OpenZeppelin's ERC4626 pairs a decimals offset (the idea implemented here) with virtual shares and assets. Its documentation describes the offset as tuning how profitable the attack is.
- **Revert on zero shares**, so a deposit that would mint nothing fails instead of taking funds.
- **Dead shares / minimum first deposit**, permanently locking a small initial supply.
- **Internal accounting** for `totalAssets` instead of reading the raw balance.
- **Seed the vault at deployment.** A small initial deposit protected Sonne's remaining markets.

---

## 8. Test Results

| Test | Vault | Expected result |
|---|---|---|
| `test_Insecure_FirstDepositorInflation_StealsVictimDeposit` | Vulnerable | Victim gets 0 shares; attacker profit = 10,000e18 |
| `test_Insecure_PartialDonation_VictimLosesQuarter` | Vulnerable | Victim redeems 7,500e18 of a 10,000e18 deposit |
| `test_Insecure_HonestDepositors_GetFairShares` | Vulnerable | Honest users are unaffected without an attacker |
| `test_Secure_SameAttack_VictimKeepsFunds` | Fixed | Victim gets 999,999,999,999,999,999 shares and loses 5,000 wei |
| `test_ThresholdMovesByPrecisionFactor` | Both | Zero-share threshold is `deposit` vs `deposit × 1e18` |
| `test_Secure_HonestDepositors_GetFairShares` | Fixed | Proportional shares, exact redemptions |
| `test_MultiplyBeforeDivide_KeepsPrecision` | n/a | `0` vs `2` |
| `testFuzz_Secure_InflationAttackNeverProfitable` | Fixed | Loss and gain at most 0.001% of the deposit |
| `testFuzz_Secure_RoundTripNeverProfits` | Fixed | Round trip never returns more than deposited |

The expected values come from an integer-exact Python model of both vaults. They have **not** yet been confirmed by running `forge test` (default fuzz runs are set to 1,000 in `foundry.toml`). Run it and update the status line at the top of this report.

---

## 9. Recommendations

1. Never let share precision equal asset precision in a vault. Scale shares (decimals offset) and add virtual shares/assets.
2. Revert when a deposit would mint zero shares.
3. Do not price shares from a raw token balance that anyone can change.
4. Seed new vaults and markets with a real initial deposit before they accept user funds.
5. Use full-precision `mulDiv` for share math and check that multiplication cannot overflow.
6. Write fuzz tests that assert a bound on user loss, not only that the code runs.

---

## 10. References

- Sonne Finance post-mortem: https://medium.com/@SonneFinance/post-mortem-sonne-finance-exploit-12f3daa82b06
- Hundred Finance analyses: https://medium.com/numen-cyber-labs/hundred-finance-exploited-for-7-million-in-latest-attack-95c1b5905c22 and https://medium.com/chainlight/patch-thursday-security-risks-due-to-exchange-rate-manipulation-of-ibtoken-ebf8e8cb165a
- OpenZeppelin, "A Novel Defense Against ERC4626 Inflation Attacks": https://www.openzeppelin.com/news/a-novel-defense-against-erc4626-inflation-attacks

---

*Report prepared by Vane. Educational lab module. Do not deploy the vulnerable contracts with real funds.*
