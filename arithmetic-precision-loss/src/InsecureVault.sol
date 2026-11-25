// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

/// @notice VULNERABLE ERC4626-style vault. Users deposit `asset` and receive shares.
///
/// Two things combine to make it exploitable:
///   1. totalAssets() is the vault's raw token balance, so ANYONE can change it by transferring tokens in.
///   2. The first deposit mints shares 1:1, and every conversion rounds DOWN with integer division.
///      With a tiny share supply, one share is worth a huge amount of assets, so a later depositor's
///      shares round down to zero (or to a fraction of what they paid for).
contract InsecureVault {
    MockERC20 public immutable asset;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address _asset) {
        asset = MockERC20(_asset);
    }

    /// @notice VULNERABLE: balance-based accounting. Tokens sent straight to the vault count as assets.
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        // VULNERABLE: 1 asset unit = 1 share, so shares have no extra precision.
        if (totalSupply == 0) return assets;

        // Multiplication happens first (correct order), but the result is still floored.
        // If assets * totalSupply < totalAssets the result is 0.
        return (assets * totalSupply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalSupply == 0) return shares;
        return (shares * totalAssets()) / totalSupply;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        // Shares are priced BEFORE the deposit lands, using the (manipulable) current balance.
        shares = convertToShares(assets);

        // VULNERABLE: nothing stops shares == 0. The depositor pays and receives nothing.
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
