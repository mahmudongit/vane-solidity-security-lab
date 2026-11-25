// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {InsecureVault} from "../src/InsecureVault.sol";
import {SecureVault} from "../src/SecureVault.sol";
import {InflationAttacker, IVault} from "../src/InflationAttacker.sol";

contract PrecisionLossTest is Test {
    MockERC20 public asset;
    InsecureVault public insecure;
    SecureVault public secure;
    InflationAttacker public attackerI; // attacks the insecure vault
    InflationAttacker public attackerS; // attacks the secure vault

    address victim = makeAddr("victim");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant PRECISION = 1e18;

    function setUp() public {
        asset = new MockERC20("Asset", "AST");
        insecure = new InsecureVault(address(asset));
        secure = new SecureVault(address(asset));
        attackerI = new InflationAttacker(address(insecure), address(asset));
        attackerS = new InflationAttacker(address(secure), address(asset));

        address[3] memory users = [victim, alice, bob];
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            asset.approve(address(insecure), type(uint256).max);
            asset.approve(address(secure), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------
    // 1. VULNERABLE: the victim receives 0 shares and loses everything
    // ---------------------------------------------------------------
    function test_Insecure_FirstDepositorInflation_StealsVictimDeposit() public {
        uint256 victimDeposit = 10_000e18;
        uint256 donation = 10_000e18;

        asset.mint(address(attackerI), donation + 1); // 1 wei deposit + the donation
        asset.mint(victim, victimDeposit);

        // Front-run: attacker becomes the only shareholder (1 share), then donates to inflate the price
        attackerI.setup(1, donation);

        // Victim deposits 10,000 tokens. shares = 10,000e18 * 1 / (10,000e18 + 1) = 0 (rounded down)
        vm.prank(victim);
        uint256 victimShares = insecure.deposit(victimDeposit);
        assertEq(victimShares, 0);

        // Back-run: attacker redeems their single share for the entire vault
        uint256 received = attackerI.cashOut();
        assertEq(received, donation + victimDeposit + 1);

        // Attacker spent 1 + donation and got back donation + victim's deposit + 1
        uint256 attackerCost = donation + 1;
        assertEq(received - attackerCost, victimDeposit); // profit == the victim's entire deposit

        assertEq(insecure.balanceOf(victim), 0); // the victim owns nothing
        assertEq(asset.balanceOf(address(insecure)), 0); // the vault is empty
    }

    // ---------------------------------------------------------------
    // 2. VULNERABLE: even a smaller donation takes a large cut
    // ---------------------------------------------------------------
    function test_Insecure_PartialDonation_VictimLosesQuarter() public {
        uint256 victimDeposit = 10_000e18;
        uint256 donation = 5_000e18;

        asset.mint(address(attackerI), donation + 1);
        asset.mint(victim, victimDeposit);

        attackerI.setup(1, donation);

        // shares = 10,000e18 / (5,000e18 + 1) = 1.99.. rounds down to 1 (a fair deal would be about 2)
        vm.prank(victim);
        uint256 victimShares = insecure.deposit(victimDeposit);
        assertEq(victimShares, 1);

        // Victim owns 1 of 2 shares of a 15,000 pool: redeems 7,500 for a 10,000 deposit
        vm.prank(victim);
        uint256 victimOut = insecure.redeem(victimShares);
        assertEq(victimOut, 7_500e18);

        uint256 received = attackerI.cashOut();
        assertEq(received - (donation + 1), 2_500e18); // attacker's profit == victim's loss
    }

    // ---------------------------------------------------------------
    // 3. VULNERABLE vault works for honest users (the bug needs an attacker)
    // ---------------------------------------------------------------
    function test_Insecure_HonestDepositors_GetFairShares() public {
        asset.mint(alice, 1_000e18);
        asset.mint(bob, 500e18);

        vm.prank(alice);
        uint256 aliceShares = insecure.deposit(1_000e18);
        vm.prank(bob);
        uint256 bobShares = insecure.deposit(500e18);

        assertEq(aliceShares, 1_000e18);
        assertEq(bobShares, 500e18);

        vm.prank(alice);
        assertEq(insecure.redeem(aliceShares), 1_000e18);
        vm.prank(bob);
        assertEq(insecure.redeem(bobShares), 500e18);
    }

    // ---------------------------------------------------------------
    // 4. FIXED: the same attack leaves the victim with (almost) everything
    // ---------------------------------------------------------------
    function test_Secure_SameAttack_VictimKeepsFunds() public {
        uint256 victimDeposit = 10_000e18;
        uint256 donation = 10_000e18;

        asset.mint(address(attackerS), donation + 1);
        asset.mint(victim, victimDeposit);

        attackerS.setup(1, donation); // attacker gets 1e18 shares for 1 wei

        // shares = 10,000e18 * 1e18 / (10,000e18 + 1) = 999,999,999,999,999,999 (about 1e18, NOT zero)
        vm.prank(victim);
        uint256 victimShares = secure.deposit(victimDeposit);
        assertEq(victimShares, 999_999_999_999_999_999);

        vm.prank(victim);
        uint256 victimOut = secure.redeem(victimShares);

        // The victim loses 5,000 wei (5e-15 of one token): less than the value of one share
        assertEq(victimOut, victimDeposit - 5_000);

        attackerS.cashOut();
        uint256 attackerOut = asset.balanceOf(address(attackerS));

        // The attacker's "profit" is the same 5,000 wei of rounding dust, after locking up 10,000 tokens
        assertEq(attackerOut - (donation + 1), 5_000);
        assertLt(attackerOut - (donation + 1), 1e6);
    }

    // ---------------------------------------------------------------
    // 5. FIXED: the attack threshold moves from "deposit" to "deposit * 1e18"
    // ---------------------------------------------------------------
    function test_ThresholdMovesByPrecisionFactor() public {
        uint256 victimDeposit = 1e6;

        // Insecure vault: a donation equal to the deposit is enough to zero out the victim
        assertEq(_victimShares(false, victimDeposit, victimDeposit - 1), 1);
        assertEq(_victimShares(false, victimDeposit, victimDeposit), 0);

        // Secure vault: the donation must be deposit * 1e18 (1e24 here, 1e18 times larger)
        assertEq(_victimShares(true, victimDeposit, victimDeposit * PRECISION - 1), 1);
        assertEq(_victimShares(true, victimDeposit, victimDeposit * PRECISION), 0);
    }

    // ---------------------------------------------------------------
    // 6. FIXED: honest users still get exact, proportional shares
    // ---------------------------------------------------------------
    function test_Secure_HonestDepositors_GetFairShares() public {
        asset.mint(alice, 1_000e18);
        asset.mint(bob, 500e18);

        vm.prank(alice);
        uint256 aliceShares = secure.deposit(1_000e18);
        vm.prank(bob);
        uint256 bobShares = secure.deposit(500e18);

        assertEq(aliceShares, 1_000e18 * PRECISION);
        assertEq(bobShares * 2, aliceShares); // Bob deposited half, so he holds half as many shares

        vm.prank(alice);
        assertEq(secure.redeem(aliceShares), 1_000e18);
        vm.prank(bob);
        assertEq(secure.redeem(bobShares), 500e18);
    }

    // ---------------------------------------------------------------
    // 7. The ordering lesson: multiply before you divide
    // ---------------------------------------------------------------
    function test_MultiplyBeforeDivide_KeepsPrecision() public {
        uint256 assets = 7;
        uint256 totalSupply = 3;
        uint256 totalAssets = 10;

        uint256 divideFirst = (assets / totalAssets) * totalSupply; // 7 / 10 = 0, then 0 * 3 = 0
        uint256 multiplyFirst = (assets * totalSupply) / totalAssets; // 21 / 10 = 2

        assertEq(divideFirst, 0);
        assertEq(multiplyFirst, 2);
    }

    // ---------------------------------------------------------------
    // 8. FUZZ (fixed vault): no inflation attack gains or costs more than dust
    //    Domain: victim deposits >= 1 token, donation <= 1e30 wei. The attack needs a donation
    //    >= victimDeposit * 1e18 >= 1e36, so everything in this domain is below the threshold.
    // ---------------------------------------------------------------
    function testFuzz_Secure_InflationAttackNeverProfitable(
        uint256 attackerDeposit,
        uint256 donation,
        uint256 victimDeposit
    ) public {
        attackerDeposit = bound(attackerDeposit, 1, 1e24);
        donation = bound(donation, 0, 1e30);
        victimDeposit = bound(victimDeposit, 1e18, 1e24);

        uint256 attackerCost = attackerDeposit + donation;
        asset.mint(address(attackerS), attackerCost);
        asset.mint(victim, victimDeposit);

        attackerS.setup(attackerDeposit, donation);

        vm.startPrank(victim);
        uint256 victimShares = secure.deposit(victimDeposit);
        assertGt(victimShares, 0); // the victim is never left with zero shares
        uint256 victimOut = secure.redeem(victimShares);
        vm.stopPrank();

        attackerS.cashOut();
        uint256 attackerOut = asset.balanceOf(address(attackerS));

        // Victim loses at most 0.001% of the deposit
        uint256 victimLoss = victimDeposit > victimOut ? victimDeposit - victimOut : 0;
        assertLe(victimLoss * 100_000, victimDeposit);

        // Attacker gains at most 0.001% of the victim's deposit
        uint256 attackerProfit = attackerOut > attackerCost ? attackerOut - attackerCost : 0;
        assertLe(attackerProfit * 100_000, victimDeposit);
    }

    // ---------------------------------------------------------------
    // 9. FUZZ (fixed vault): depositing and redeeming immediately never returns more than you put in
    // ---------------------------------------------------------------
    function testFuzz_Secure_RoundTripNeverProfits(uint256 seedDeposit, uint256 donation, uint256 amount) public {
        seedDeposit = bound(seedDeposit, 1, 1e24);
        donation = bound(donation, 0, 1e30);
        amount = bound(amount, 1, 1e24);

        asset.mint(address(attackerS), seedDeposit + donation);
        attackerS.setup(seedDeposit, donation); // gives the vault an arbitrary existing state

        asset.mint(alice, amount);
        vm.startPrank(alice);
        uint256 shares = secure.deposit(amount);
        uint256 out = secure.redeem(shares);
        vm.stopPrank();

        assertLe(out, amount); // rounding always favours the vault
    }

    // ---------------------------------------------------------------
    // helper: fresh vault + attacker, returns the shares a victim would receive
    // ---------------------------------------------------------------
    function _victimShares(bool useSecure, uint256 victimDeposit, uint256 donation) internal returns (uint256 shares) {
        address vaultAddr =
            useSecure ? address(new SecureVault(address(asset))) : address(new InsecureVault(address(asset)));
        InflationAttacker atk = new InflationAttacker(vaultAddr, address(asset));

        asset.mint(address(atk), donation + 1);
        atk.setup(1, donation);

        asset.mint(address(this), victimDeposit);
        asset.approve(vaultAddr, victimDeposit);
        shares = IVault(vaultAddr).deposit(victimDeposit);
    }
}
