// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract SimpleBankFixCEI {

    mapping(address => uint256) public balances;

    // Deposit ETH into the bank
    function deposit() external payable {
        require(msg.value >= 1 ether, "Minimum deposit is 1 ETH");

        balances[msg.sender] += msg.value;
    }

    function withdraw() external {

    uint256 bal = balances[msg.sender];

    require(bal >= 1 ether, "Insufficient balance");

    // EFFECTS FIRST
    balances[msg.sender] = 0;

    // INTERACTION LAST
    (bool success, ) = msg.sender.call{value: bal}("");
    require(success, "Transfer failed");
    }

    // Check contract balance
    function getBankBalance() external view returns(uint256) {
        return address(this).balance;
    }
}