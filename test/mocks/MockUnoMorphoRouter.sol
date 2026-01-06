// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockUnoMorphoRouter {
    using SafeERC20 for IERC20;

    IERC20 public ASSET;
    IERC4626 public VAULT;

    address public lastCaller;
    address public lastReceiver;
    uint256 public lastAssets;
    uint256 public lastShares;

    constructor(IERC20 asset_, IERC4626 vault_) {
        ASSET = asset_;
        VAULT = vault_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        lastCaller = msg.sender;
        lastReceiver = receiver;
        lastAssets = assets;

        ASSET.safeTransferFrom(msg.sender, address(this), assets);
        ASSET.safeIncreaseAllowance(address(VAULT), assets);
        shares = VAULT.deposit(assets, receiver);
        lastShares = shares;
    }
}
