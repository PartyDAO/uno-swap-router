// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import { Script, console2 } from "forge-std/src/Script.sol";
import { UnoRouterV2 } from "../src/UnoRouterV2.sol";
import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployUnoRouterV2 is Script {
    address constant EXPECTED_DEPLOYER = 0xc58f56E576EE22c627F66921e7b0b7e535ef20Db;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envAddress("OWNER");
        address permit2 = vm.envAddress("PERMIT2");

        require(deployer == EXPECTED_DEPLOYER, "Deployer must be original UnoRouter deployer");

        address[] memory swapTargets = _parseSwapTargets(vm.envOr("SWAP_TARGETS", string("")));

        vm.startBroadcast(deployerKey);

        UnoRouterV2 implementation = new UnoRouterV2(ISignatureTransfer(permit2));

        bytes memory initData = abi.encodeWithSelector(UnoRouterV2.initialize.selector, owner, swapTargets);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        console2.log("UnoRouterV2 implementation", address(implementation));
        console2.log("UnoRouterV2 proxy", address(proxy));

        vm.stopBroadcast();
    }

    function _parseSwapTargets(string memory targetsCsv) internal pure returns (address[] memory) {
        bytes memory b = bytes(targetsCsv);
        if (b.length == 0) {
            return new address[](0);
        }

        // Count commas to size the array
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == bytes1(",")) {
                count++;
            }
        }

        address[] memory targets = new address[](count);
        uint256 idx = 0;
        uint256 start = 0;
        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == bytes1(",")) {
                targets[idx] = _parseAddress(_slice(b, start, i));
                idx++;
                start = i + 1;
            }
        }
        return targets;
    }

    function _slice(bytes memory data, uint256 start, uint256 end) internal pure returns (bytes memory) {
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = data[i];
        }
        return out;
    }

    function _parseAddress(bytes memory strBytes) internal pure returns (address parsed) {
        require(strBytes.length == 42, "INVALID_ADDRESS_LENGTH");
        uint256 addr;
        for (uint256 i = 2; i < 42; i++) {
            uint256 digit = uint8(strBytes[i]);
            if (digit >= 48 && digit <= 57) {
                digit -= 48;
            } else if (digit >= 65 && digit <= 70) {
                digit -= 55;
            } else if (digit >= 97 && digit <= 102) {
                digit -= 87;
            } else {
                revert("INVALID_ADDRESS_CHAR");
            }
            addr = (addr << 4) | digit;
        }
        parsed = address(uint160(addr));
    }
}

