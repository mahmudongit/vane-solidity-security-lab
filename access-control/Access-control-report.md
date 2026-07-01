# Security Audit Report: Missing Access Control in InsecureVault

**Auditor:** Vane (@vanebuilds_)  
**Date:** June 2026  
**Scope:** `InsecureVault.sol` — Ownership & Withdrawal functionality  
**Classification:** Access Control Vulnerability  
**Status:** ✅ Mitigated & Verified

---

## 1. Executive Summary

A **critical access control vulnerability** was identified in `InsecureVault.sol`. Three sensitive functions — `setOwner()`, `withdrawAll()`, and `emergencyDrain()` — lack any authorization checks, allowing **any external address** to seize ownership of the contract and drain its entire ETH balance.

Two independent mitigations were implemented and verified via Foundry:
- **OpenZeppelin Ownable** — single-owner model with `onlyOwner` modifier
- **OpenZeppelin AccessControl** — role-based model with `WITHDRAW_ROLE` and `DRAIN_ROLE`

Both mitigations successfully prevent unauthorized ownership transfer and fund drainage while preserving core deposit functionality.

---

## 2. Vulnerability Details

### 2.1 Affected Contract
- **File:** `src/InsecureVault.sol`
- **Contract:** `InsecureVault`
- **Functions:** `setOwner()`, `withdrawAll()`, `emergencyDrain()`

### 2.2 Vulnerable Code

```solidity
// InsecureVault.sol

// ❌ No access control — anyone can become owner
function setOwner(address _owner) external {
    owner = _owner;
}

// ❌ No access control — anyone can drain the entire vault
function withdrawAll() external {
    uint256 bal = address(this).balance;
    (bool success, ) = msg.sender.call{value: bal}("");
    require(success, "Transfer failed");
}

// ❌ No access control — anyone can drain to "owner"
function emergencyDrain() external {
    uint256 bal = address(this).balance;
    (bool success, ) = owner.call{value: bal}("");
    require(success, "Transfer failed");
}
```

### 2.3 Root Cause

The contract defines an `owner` state variable in the constructor but **never enforces ownership** on any state-changing function. This is a classic **missing access control** vulnerability (SWC-106).

The three functions represent distinct attack vectors:

1. **`setOwner()`** — Ownership takeover. Any caller can reassign `owner` to themselves, gaining implicit authority over `emergencyDrain()` (which sends funds to the `owner` address).
2. **`withdrawAll()`** — Direct fund theft. Any caller can withdraw the **entire contract balance** to their own address.
3. **`emergencyDrain()`** — Indirect fund theft. Any caller can force the contract to send all ETH to the current `owner` address — which they may have already set to themselves via `setOwner()`.

---

## 3. Proof of Concept

### 3.1 Attack Contract

The attacker contract (`VaultAttacker` in `src/VaultAttacker.sol`) executes a two-step exploit in a single transaction:

```solidity
contract VaultAttacker {
    InsecureVault public vault;

    constructor(address _vault) {
        vault = InsecureVault(_vault);
    }

    // Step 1: seize ownership  |  Step 2: drain everything
    function attack() external {
        vault.setOwner(address(this));
        vault.withdrawAll();
    }

    receive() external payable {}
}
```

### 3.2 Foundry Test: Exploit Verification

**Test:** `test_AttackerTakesOwnershipAndDrains()` in `test/VaultAttackTest.t.sol`

**Setup:**
- Alice deposits 5 ETH
- Bob deposits 3 ETH
- **Total vault balance: 8 ETH**

**Execution:**
```solidity
vm.prank(address(attacker));
attacker.attack();
```

**Result:**
| Metric | Value |
|--------|-------|
| Attacker profit | **+8 ETH** (entire vault balance) |
| Vault remaining balance | **0 ETH** |
| Vault owner | **`address(attacker)`** |
| Alice & Bob funds | **Completely stolen** |

**Assertion (passing):**
```solidity
assertEq(vault.owner(), address(attacker));
assertEq(address(attacker).balance, attackerBefore + 8 ether);
assertEq(vault.getBalance(), 0);
```

### 3.3 Additional Exploit Vectors Verified

**Test:** `test_AnyoneCanSetOwner()`
- Alice (unrelated user) calls `setOwner(alice)`
- `vault.owner()` immediately becomes Alice
- **No signature, no prior authorization, no role required**

**Test:** `test_AnyoneCanWithdrawAll()`
- Alice deposits 3 ETH
- Bob (who never deposited) calls `withdrawAll()`
- Bob receives Alice's 3 ETH
- **Complete loss of depositor funds with zero attacker capital**

> **Impact:** Total loss of all ETH held by the contract. Any user can become owner and/or drain funds at will.

---

## 4. Impact Assessment

| Factor | Rating | Notes |
|--------|--------|-------|
| **Severity** | 🔴 **Critical** | Complete loss of all contract-held ETH |
| **Likelihood** | **Certain** | No access control = exploitation is trivial and guaranteed |
| **Attack Cost** | **0 ETH** | Attacker does not need to deposit; can drain without any prior interaction |
| **Affected Users** | **All depositors** | Every ETH in the contract is accessible to any address |
| **Preconditions** | **None** | Public external functions, no modifiers, no checks |

### Real-World Parallels
Missing access control is one of the most common and costly vulnerability classes:
- **Parity Multisig Hack (2017):** Unprotected `initWallet()` allowed attacker to become owner of ~500K ETH
- **Cover Protocol (2020):** Unprotected `deposit()` reward manipulation led to ~$4M loss
- **Indexed Finance (2021):** Unprotected `setPool()` allowed attacker to drain pools via compromised controller
- **Audius (2022):** Unprotected governance contract allowed attacker to seize control and drain ~$6M

---

## 5. Mitigation Analysis

Two fixes were implemented and independently verified. Both preserve the deposit functionality and protect all withdrawal paths.

### 5.1 Fix A: OpenZeppelin Ownable

**File:** `src/SecureVaultOwnable.sol`

**Change:** Inherit from `Ownable` and apply `onlyOwner` to all sensitive functions.

```solidity
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SecureVaultOwnable is Ownable {
    constructor() Ownable(msg.sender) {}

    function withdrawAll() external onlyOwner {
        uint256 bal = address(this).balance;
        (bool success, ) = msg.sender.call{value: bal}("");
        require(success, "Transfer failed");
    }

    function emergencyDrain() external onlyOwner {
        uint256 bal = address(this).balance;
        (bool success, ) = owner().call{value: bal}("");
        require(success, "Transfer failed");
    }
}
```

**Mechanism:** The `onlyOwner` modifier reverts if `msg.sender != owner()`. The owner is set once in the constructor and cannot be changed without an explicit ownership transfer function (which OpenZeppelin provides securely).

**Test Results:**
- `test_Ownable_OnlyOwnerCanWithdraw()` — owner successfully withdraws 3 ETH deposited by Alice
- `test_Ownable_RevertIfNotOwner()` — Alice's attempt to call `withdrawAll()` reverts with an access control error

**Gas Impact:** Minimal. `Ownable` stores a single `address` and performs one `==` comparison per protected call.

**Best For:** Single-admin contracts, treasury vaults, personal projects, and protocols with a clear singular authority.

---

### 5.2 Fix B: OpenZeppelin AccessControl

**File:** `src/SecureVaultAccessControl.sol`

**Change:** Inherit from `AccessControl`, define granular roles, and apply `onlyRole` modifiers.

```solidity
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract SecureVaultAccessControl is AccessControl {
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");
    bytes32 public constant DRAIN_ROLE = keccak256("DRAIN_ROLE");

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(WITHDRAW_ROLE, msg.sender);
        _grantRole(DRAIN_ROLE, msg.sender);
    }

    function withdrawAll() external onlyRole(WITHDRAW_ROLE) {
        // ...
    }

    function emergencyDrain() external onlyRole(DRAIN_ROLE) {
        // ...
    }
}
```

**Mechanism:** `AccessControl` maintains a mapping of `role => account => bool`. The `onlyRole` modifier checks if `msg.sender` has been granted the specific role. The `DEFAULT_ADMIN_ROLE` holder can grant or revoke other roles dynamically.

**Test Results:**
- `test_ACL_OnlyAuthorizedCanWithdraw()` — owner (who has `WITHDRAW_ROLE`) successfully withdraws
- `test_ACL_RevertIfUnauthorized()` — Alice's unauthorized call reverts
- `test_ACL_GrantRoleWorks()` — owner grants `WITHDRAW_ROLE` to Alice; Alice can then withdraw her own deposit

**Gas Impact:** Slightly higher than `Ownable` due to `keccak256` role hashing and mapping lookups, but negligible in practice (~100–200 gas per call).

**Best For:** Multi-sig treasuries, DAOs, protocols with separated responsibilities (e.g., one role for withdrawal, another for emergency actions), and any system requiring role delegation without full ownership transfer.

---

### 5.3 Mitigation Comparison

| Criteria | Ownable | AccessControl |
|----------|---------|---------------|
| **Simplicity** | Minimal (1 owner) | Moderate (role definitions + grants) |
| **Flexibility** | Low (single owner) | High (multiple roles, delegable) |
| **Role Separation** | ❌ None | ✅ Withdraw vs Drain vs Admin |
| **Ownership Transfer** | `transferOwnership()` | `grantRole()` / `revokeRole()` |
| **Gas Overhead** | ~2,100 gas (SLOAD owner) | ~2,200–2,500 gas (mapping lookup) |
| **Upgrade Path** | Must transfer whole ownership | Can add/remove individual roles |
| **Best For** | Personal/small projects | Production DeFi, DAOs, teams |

**Recommendation:**
- For **this vault contract**, `Ownable` is sufficient if only one entity should ever control withdrawals.
- For **production multi-user protocols**, `AccessControl` is strongly preferred because it enables:
  - **Separation of duties** (treasury manager vs emergency responder)
  - **Granular revocation** (remove one compromised key without transferring everything)
  - **DAO compatibility** (grant roles to timelock contracts or multi-sigs)

---

## 6. Code Diff

### Before (Vulnerable)
```solidity
contract InsecureVault {
    address public owner;

    // ❌ No access control
    function setOwner(address _owner) external {
        owner = _owner;
    }

    // ❌ No access control
    function withdrawAll() external {
        uint256 bal = address(this).balance;
        (bool success, ) = msg.sender.call{value: bal}("");
        require(success, "Transfer failed");
    }

    // ❌ No access control
    function emergencyDrain() external {
        uint256 bal = address(this).balance;
        (bool success, ) = owner.call{value: bal}("");
        require(success, "Transfer failed");
    }
}
```

### After (AccessControl Fix)
```solidity
contract SecureVaultAccessControl is AccessControl {
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");
    bytes32 public constant DRAIN_ROLE = keccak256("DRAIN_ROLE");

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(WITHDRAW_ROLE, msg.sender);
        _grantRole(DRAIN_ROLE, msg.sender);
    }

    // ✅ Role-restricted
    function withdrawAll() external onlyRole(WITHDRAW_ROLE) {
        uint256 bal = address(this).balance;
        (bool success, ) = msg.sender.call{value: bal}("");
        require(success, "Transfer failed");
    }

    // ✅ Role-restricted
    function emergencyDrain() external onlyRole(DRAIN_ROLE) {
        uint256 bal = address(this).balance;
        (bool success, ) = msg.sender.call{value: bal}("");
        require(success, "Transfer failed");
    }
}
```

---

## 7. Additional Security Notes

1. **`setOwner()` Anti-Pattern:** The original `setOwner()` function is dangerous even *with* access control. OpenZeppelin's `Ownable2Step` is preferred because it requires the **new owner to accept** ownership, preventing accidental transfers to dead addresses or typos.

2. **`withdrawAll()` Risk:** Both fixes retain a function that sends the **entire contract balance** to a single address. In production, consider:
   - Per-user withdrawal (`withdraw(uint256 amount)`) so users only claim their own deposits
   - A `maxWithdrawal` rate limit to reduce blast radius
   - A timelock or multi-sig requirement for `emergencyDrain()`

3. **Reentrancy Reminder:** The fixed contracts still use `call{value:...}`. While access control prevents *unauthorized* calls, it does not prevent a *authorized but malicious* owner from being a reentrancy attacker. Apply **Checks-Effects-Interactions** or `nonReentrant` alongside access control for defense in depth.

4. **Event Emission:** Neither the vulnerable nor fixed contracts emit events for deposits, withdrawals, or ownership changes. Production contracts should emit:
   ```solidity
   event Deposit(address indexed user, uint256 amount);
   event Withdrawal(address indexed recipient, uint256 amount);
   event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
   ```
   Events are critical for off-chain monitoring and incident response.

5. **Zero-Value Checks:** `withdrawAll()` sends `address(this).balance` even if it is `0`. While not harmful, adding `require(bal > 0, "No funds")` prevents unnecessary external calls and improves gas efficiency.

---

## 8. References

- [SWC-106: Unprotected SELFDESTRUCT Instruction / Missing Access Control](https://swcregistry.io/docs/SWC-106/)
- [OpenZeppelin: Ownable](https://docs.openzeppelin.com/contracts/5.x/api/access#Ownable)
- [OpenZeppelin: AccessControl](https://docs.openzeppelin.com/contracts/5.x/api/access#AccessControl)
- [Consensys Smart Contract Best Practices: Access Control](https://consensys.github.io/smart-contract-best-practices/development-recommendations/precautions/authorization/)
- [Solidity Docs: Function Modifiers](https://docs.soliditylang.org/en/latest/contracts.html#function-modifiers)
- [OpenZeppelin: Ownable2Step](https://docs.openzeppelin.com/contracts/5.x/api/access#Ownable2Step) — safer ownership transfer pattern

---

## 9. Conclusion

`InsecureVault.sol` contained a **critical access control vulnerability** that allowed any external address to seize ownership and drain all depositor funds. The vulnerability was successfully reproduced via Foundry, then mitigated using two industry-standard approaches:

1. **OpenZeppelin Ownable** — simple, single-owner protection
2. **OpenZeppelin AccessControl** — flexible, role-based protection with delegation support

All tests pass. The contract is **secure against unauthorized access** in its current form.

> **For production deployment**, it is recommended to:
> - Use `AccessControl` (or `Ownable2Step`) for ownership management
> - Add `nonReentrant` to all ETH-transferring functions
> - Emit events for all state-changing operations
> - Implement per-user withdrawal limits instead of global `withdrawAll()`
> - Conduct a full protocol audit before managing real user funds

---

*Report prepared by Vane — Smart Contract Security Focused Developer*  
*Available for security audits and ERC20/ERC721/ERC1155 development.*  
*X: [@vanebuilds_](https://x.com/vanebuilds_) | GitHub: [mahmudongit](https://github.com/mahmudongit)*
