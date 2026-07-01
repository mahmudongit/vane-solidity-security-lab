// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {InsecureVault} from "../src/InsecureVault.sol";
import {VaultAttacker} from "../src/VaultAttacker.sol";

contract VaultAttackTest is Test {
    InsecureVault public vault;
    VaultAttacker public attacker;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public {
        vault = new InsecureVault();
        attacker = new VaultAttacker(address(vault));

        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
        vm.deal(address(attacker), 1 ether);
    }

    // Anyone can seize ownership
    function test_AnyoneCanSetOwner() public {
        vm.prank(alice);
        vault.setOwner(alice);
        assertEq(vault.owner(), alice);
    }

    // Anyone can drain the entire vault
    function test_AnyoneCanWithdrawAll() public {
        vm.prank(alice);
        vault.deposit{value: 3 ether}();

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.withdrawAll();

        assertEq(bob.balance, bobBefore + 3 ether);
        assertEq(vault.getBalance(), 0);
    }

    // Attacker contract takes ownership then drains everything
    function test_AttackerTakesOwnershipAndDrains() public {
        vm.prank(alice);
        vault.deposit{value: 5 ether}();
        vm.prank(bob);
        vault.deposit{value: 3 ether}();

        uint256 attackerBefore = address(attacker).balance;

        vm.prank(address(attacker));
        attacker.attack();

        assertEq(vault.owner(), address(attacker));
        assertEq(address(attacker).balance, attackerBefore + 8 ether);
        assertEq(vault.getBalance(), 0);
    }
}