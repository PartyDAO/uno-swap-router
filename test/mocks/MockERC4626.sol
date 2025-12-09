// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { ERC4626 } from "solmate/src/tokens/ERC4626.sol";

contract MockERC4626 is ERC4626 {
    constructor(ERC20 _asset) ERC4626(_asset, "Mock Vault", "MVLT") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

