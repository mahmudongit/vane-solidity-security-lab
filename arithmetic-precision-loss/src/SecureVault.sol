// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

/// @notice FIXED vault: shares are tracked with extra precision.
///
/// What changed compared with InsecureVault:
///   * PRECISION = 1e18. The first deposit mints `assets * 1e18` shares, so one asset unit is
///     1e18 shares instead of 1. A share is now worth at most ~1e-18 of an asset unit.
///   * Conversions keep the multiply-before-divide order, so no precision is thrown away before the division.
///
/// Why this stops the attack: the victim only receives zero shares if
///     victimDeposit * totalSupply < totalAssets.
/// With 1:1 shares an attacker needed a donation of about `victimDeposit`.
/// With 1e18-scaled shares the donation must be about `victimDeposit * 1e18`, which is more than the
/// whole supply of any real token for any meaningful deposit. Below that threshold the victim's rounding
/// loss is less than the value of ONE share, which is a dust amount.
///
/// Limits (also in the report):
///   * It does not remove the problem for dust deposits or for donations above the threshold.
///   * assets * totalSupply must fit in 256 bits. Production code should use a full-precision mulDiv.
///   * OpenZeppelin pairs this "decimals offset" with virtual shares/assets for defense in depth.
contract SecureVault {
    MockERC20 public immutable asset;

    /// @dev Shares carry 18 more decimals of precision than the asset.
    uint256 public constant PRECISION = 1e18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address _asset) {
        asset = MockERC20(_asset);
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        // FIXED: scale the first mint so shares are far finer-grained than the asset.
        if (totalSupply == 0) return assets * PRECISION;

        // Multiply first, divide last. Still floors, so rounding favours the vault, but the loss is
        // now less than one share (a dust amount) instead of up to a whole asset unit's worth.
        return (assets * totalSupply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalSupply == 0) return shares / PRECISION;
        return (shares * totalAssets()) / totalSupply;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        shares = convertToShares(assets);
        asset.transferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[msg.sender] += shares;
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        asset.transfer(msg.sender, assets);
    }
}
