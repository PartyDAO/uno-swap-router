// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import { Test } from "forge-std/src/Test.sol";

import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Permit2 } from "src/utils/Permit2HelperUpgradeable.sol";
import { UnoRouterV2, SwapParams, FeeToken } from "src/UnoRouterV2.sol";
import { MockDEX } from "test/mocks/MockDEX.sol";

contract UnoRouterV2Test is Test {
    address owner;
    address user;
    uint256 userPrivateKey;
    UnoRouterV2 router;
    MockDEX dex;
    ISignatureTransfer permit2;
    ERC20 usdce;
    ERC20 wld;

    bytes32 public constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    bytes32 public constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    function setUp() public {
        vm.createSelectFork(vm.envString("WORLDCHAIN_RPC_URL"), 20_916_118);

        owner = makeAddr("owner");
        (user, userPrivateKey) = makeAddrAndKey("user");

        // Use Permit2 contract on Worldchain
        permit2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

        // Deploy mock DEX on the forked network
        dex = new MockDEX();

        // Deploy UnoRouterV2 (upgradeable pattern)
        UnoRouterV2 implementation = new UnoRouterV2();
        address[] memory swapTargets = new address[](1);
        swapTargets[0] = address(dex);
        bytes memory initData = abi.encodeCall(UnoRouterV2.initialize, (permit2, owner, swapTargets));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        router = UnoRouterV2(address(proxy));

        // USDC.e on Worldchain
        usdce = ERC20(0x79A02482A880bCE3F13e09Da970dC34db4CD24d1);

        // WLD token on Worldchain
        wld = ERC20(0x2cFc85d8E48F8EAB294be644d9E25C3030863003);

        // Fund accounts with ETH and tokens
        deal(user, 100 ether);
        deal(address(usdce), user, 1000e6);
        deal(address(wld), user, 1000e18);
        deal(address(usdce), address(dex), 1_000_000e6);
        deal(address(wld), address(dex), 1_000_000e18);
        deal(address(dex), 1_000_000 ether);

        // Approve Permit2 for token transfers
        vm.startPrank(user);
        usdce.approve(address(permit2), type(uint256).max);
        wld.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    // TODO: Add test cases for:
    // - fillQuoteTokenToToken (existing UnoRouter function)
    // - fillQuoteEthToToken (existing UnoRouter function)
    // - fillQuoteTokenToEth (existing UnoRouter function)
    // - fillQuoteTokenToTokenAndSend (new function)
    // - fillQuoteTokenToTokenAndDeposit (new function)
    // - Admin functions (updateSwapTargets, withdrawToken, withdrawEth)
    // - Revert cases
}

