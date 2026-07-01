// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract InsecureVault {
    address public owner;
    mapping(address => uint256) public balances;

    constructor() {
        owner = msg.sender;
    }

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    // VULNERABLE: no access control — anyone can become owner
    function setOwner(address _owner) external {
        owner = _owner;
    }

    // VULNERABLE: no access control — anyone can drain the entire vault
    function withdrawAll() external {
        uint256 bal = address(this).balance;
        (bool success, ) = msg.sender.call{value: bal}("");
        require(success, "Transfer failed");
    }

    // VULNERABLE: no access control — anyone can drain to "owner"
    function emergencyDrain() external {
        uint256 bal = address(this).balance;
        (bool success, ) = owner.call{value: bal}("");
        require(success, "Transfer failed");
    }

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }
}