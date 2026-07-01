// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract SecureVaultAccessControl is AccessControl {
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");
    bytes32 public constant DRAIN_ROLE = keccak256("DRAIN_ROLE");

    mapping(address => uint256) public balances;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(WITHDRAW_ROLE, msg.sender);
        _grantRole(DRAIN_ROLE, msg.sender);
    }

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdrawAll() external onlyRole(WITHDRAW_ROLE) {
        uint256 bal = address(this).balance;
        (bool success, ) = msg.sender.call{value: bal}("");
        require(success, "Transfer failed");
    }

    function emergencyDrain() external onlyRole(DRAIN_ROLE) {
        uint256 bal = address(this).balance;
        (bool success, ) = msg.sender.call{value: bal}("");
        require(success, "Transfer failed");
    }

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }
}