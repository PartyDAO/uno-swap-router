// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import { Script } from "forge-std/src/Script.sol";
import { console } from "forge-std/src/console.sol";
import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UnoRouterV2 } from "src/UnoRouterV2.sol";

contract DeployUnoRouterV2 is Script {
    function run() public {
        // Permit2 canonical address
        ISignatureTransfer permit2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

        // Swap targets (same as UnoRouter production targets)
        // TODO: Update with actual production swap target addresses
        address[] memory swapTargets = new address[](1);
        swapTargets[0] = 0x091AD9e2e6e5eD44c1c66dB50e49A601F9f36cF6; // Example: Uniswap Swap Router

        // Owner address (deployer or multisig)
        address owner = msg.sender; // TODO: Update with actual owner/multisig address

        vm.startBroadcast();

        // Deploy implementation
        UnoRouterV2 implementation = new UnoRouterV2();

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(UnoRouterV2.initialize, (permit2, owner, swapTargets));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        UnoRouterV2 router = UnoRouterV2(address(proxy));

        vm.stopBroadcast();

        console.log("UnoRouterV2 implementation deployed at:", address(implementation));
        console.log("UnoRouterV2 proxy deployed at:", address(router));
    }
}

