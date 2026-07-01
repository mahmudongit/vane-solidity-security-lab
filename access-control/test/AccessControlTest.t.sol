// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SecureVaultOwnable} from "../src/SecureVaultOwnable.sol";
import {SecureVaultAccessControl} from "../src/SecureVaultAccessControl.sol";

contract AccessControlTest is Test {
    SecureVaultOwnable public ownableVault;
    SecureVaultAccessControl public aclVault;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.prank(owner);
        ownableVault = new SecureVaultOwnable();

        vm.prank(owner);
        aclVault = new SecureVaultAccessControl();

        vm.deal(alice, 10 ether);
        vm.deal(owner, 10 ether);
    }

    // --- Ownable fix ---

    function test_Ownable_OnlyOwnerCanWithdraw() public {
        vm.prank(alice);
        ownableVault.deposit{value: 3 ether}();

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        ownableVault.withdrawAll();

        assertEq(owner.balance, ownerBefore + 3 ether);
    }

    function test_Ownable_RevertIfNotOwner() public {
        vm.prank(alice);
        ownableVault.deposit{value: 1 ether}();

        vm.prank(alice);
        vm.expectRevert();
        ownableVault.withdrawAll();
    }

    // --- AccessControl fix ---

    function test_ACL_OnlyAuthorizedCanWithdraw() public {
        vm.prank(alice);
        aclVault.deposit{value: 3 ether}();

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        aclVault.withdrawAll();

        assertEq(owner.balance, ownerBefore + 3 ether);
    }

    function test_ACL_RevertIfUnauthorized() public {
        vm.prank(alice);
        aclVault.deposit{value: 1 ether}();

        vm.prank(alice);
        vm.expectRevert();
        aclVault.withdrawAll();
    }

    function test_ACL_GrantRoleWorks() public {
        
    // Grant alice the WITHDRAW_ROLE (as owner)
    vm.startPrank(owner);
    aclVault.grantRole(aclVault.WITHDRAW_ROLE(), alice);
    vm.stopPrank();

    // Alice deposits
    vm.prank(alice);
    aclVault.deposit{value: 2 ether}();

    // Alice withdraws (she now has the role)
    uint256 aliceBefore = alice.balance;
    vm.prank(alice);
    aclVault.withdrawAll();

    assertEq(alice.balance, aliceBefore + 2 ether);
    }
}