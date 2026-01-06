// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import { Test } from "forge-std/src/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { UnoRouterV2, SwapParams, FeeToken } from "../src/UnoRouterV2.sol";
import { UnoRouter } from "../src/UnoRouter.sol";
import { FeeToken as LegacyFeeToken } from "../src/BaseAggregator.sol";
import { Permit2 } from "../src/Permit2Helper.sol";
import { MockDEX } from "./mocks/MockDEX.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC4626 } from "./mocks/MockERC4626.sol";
import { MockPermit2 } from "./mocks/MockPermit2.sol";
import { MockUnoMorphoRouter } from "./mocks/MockUnoMorphoRouter.sol";

contract UnoRouterV2Test is Test {
    address internal owner;
    address internal user;
    uint256 internal userPrivateKey;

    UnoRouterV2 internal router;
    MockDEX internal dex;
    MockPermit2 internal permit2;
    MockERC20 internal usdce;
    MockERC20 internal wld;
    MockERC4626 internal vault;

    struct Env {
        UnoRouter legacy;
        UnoRouterV2 v2;
        MockDEX dex;
        MockERC20 usdce;
        MockERC20 wld;
        MockERC4626 vault;
        MockPermit2 permit2;
    }

    function setUp() public {
        owner = makeAddr("owner");
        (user, userPrivateKey) = makeAddrAndKey("user");

        // Deploy Permit2 mock locally
        permit2 = new MockPermit2();

        // Deploy mocks
        dex = new MockDEX();
        usdce = new MockERC20("USD Coin", "USDC", 6);
        wld = new MockERC20("Worldcoin", "WLD", 18);
        vault = new MockERC4626(ERC20(address(usdce)));

        // Seed liquidity for DEX
        usdce.mint(address(dex), 1_000_000e6);
        wld.mint(address(dex), 1_000_000e18);
        vm.deal(address(dex), 1_000_000 ether);

        // Mint tokens to user
        usdce.mint(user, 10_000e6);
        wld.mint(user, 10_000e18);
        vm.deal(user, 100 ether);

        // Approve Permit2 for user tokens
        vm.startPrank(user);
        usdce.approve(address(permit2), type(uint256).max);
        wld.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        // Deploy UnoRouterV2 implementation and proxy
        address[] memory targets = new address[](1);
        targets[0] = address(dex);

        UnoRouterV2 impl = new UnoRouterV2(ISignatureTransfer(address(permit2)));
        bytes memory initData = abi.encodeWithSelector(UnoRouterV2.initialize.selector, owner, targets);
        router = UnoRouterV2(payable(address(new ERC1967Proxy(address(impl), initData))));

        // Seed router with balances to test fee withdrawals
        usdce.mint(address(router), 1000e6);
        vm.deal(address(router), 10 ether);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _makePermit(address, uint256, uint256 nonce) internal view returns (Permit2 memory permit) {
        uint256 deadline = block.timestamp + 1 hours;
        // MockPermit2 ignores signature content; empty signature is sufficient.
        permit = Permit2({ nonce: nonce, deadline: deadline, signature: "" });
    }

    function _defaultParamsInputFee(
        uint256 sellAmount,
        uint256 feeAmount,
        uint256 buyAmount
    )
        internal
        view
        returns (SwapParams memory)
    {
        bytes memory swapCallData = abi.encodeWithSignature(
            "swapTokensForTokens(address,address,uint256,uint256)",
            address(usdce),
            address(wld),
            sellAmount - feeAmount,
            buyAmount
        );
        return SwapParams({
            sellToken: IERC20(address(usdce)),
            buyToken: IERC20(address(wld)),
            target: payable(address(dex)),
            swapCallData: swapCallData,
            sellAmount: sellAmount,
            feeToken: FeeToken.INPUT,
            feeAmount: feeAmount
        });
    }

    function _defaultParamsOutputFee(
        uint256 sellAmount,
        uint256 feeAmount,
        uint256 buyAmount
    )
        internal
        view
        returns (SwapParams memory)
    {
        bytes memory swapCallData = abi.encodeWithSignature(
            "swapTokensForTokens(address,address,uint256,uint256)", address(usdce), address(wld), sellAmount, buyAmount
        );
        return SwapParams({
            sellToken: IERC20(address(usdce)),
            buyToken: IERC20(address(wld)),
            target: payable(address(dex)),
            swapCallData: swapCallData,
            sellAmount: sellAmount,
            feeToken: FeeToken.OUTPUT,
            feeAmount: feeAmount
        });
    }

    function _deployEnv() internal returns (Env memory e) {
        e.permit2 = new MockPermit2();
        e.dex = new MockDEX();
        e.usdce = new MockERC20("USD Coin", "USDC", 6);
        e.wld = new MockERC20("Worldcoin", "WLD", 18);
        e.vault = new MockERC4626(ERC20(address(e.usdce)));

        // Seed liquidity for DEX
        e.usdce.mint(address(e.dex), 1_000_000e6);
        e.wld.mint(address(e.dex), 1_000_000e18);
        vm.deal(address(e.dex), 1_000_000 ether);

        // Mint tokens to user
        e.usdce.mint(user, 10_000e6);
        e.wld.mint(user, 10_000e18);
        vm.deal(user, 100 ether);

        // Approve Permit2 for user tokens
        vm.startPrank(user);
        e.usdce.approve(address(e.permit2), type(uint256).max);
        e.wld.approve(address(e.permit2), type(uint256).max);
        vm.stopPrank();

        address[] memory targets = new address[](1);
        targets[0] = address(e.dex);

        e.legacy = new UnoRouter(owner, targets, ISignatureTransfer(address(e.permit2)));
        UnoRouterV2 impl = new UnoRouterV2(ISignatureTransfer(address(e.permit2)));
        bytes memory initData = abi.encodeWithSelector(UnoRouterV2.initialize.selector, owner, targets);
        e.v2 = UnoRouterV2(payable(address(new ERC1967Proxy(address(impl), initData))));

        // Seed router balances for fee withdrawals
        e.usdce.mint(address(e.v2), 1000e6);
        vm.deal(address(e.v2), 10 ether);
        e.usdce.mint(address(e.legacy), 1000e6);
        vm.deal(address(e.legacy), 10 ether);
    }

    struct Delta {
        int256 userSell;
        int256 userBuy;
        int256 routerSell;
        int256 routerBuy;
        int256 userEth;
        int256 routerEth;
    }

    function _delta(address sell, address buy, address routerAddr) internal view returns (Delta memory d) {
        d.userSell = int256(IERC20(sell).balanceOf(user));
        d.userBuy = int256(IERC20(buy).balanceOf(user));
        d.routerSell = int256(IERC20(sell).balanceOf(routerAddr));
        d.routerBuy = int256(IERC20(buy).balanceOf(routerAddr));
        d.userEth = int256(user.balance);
        d.routerEth = int256(routerAddr.balance);
    }

    function _subtract(Delta memory afterD, Delta memory beforeD) internal pure returns (Delta memory r) {
        r.userSell = afterD.userSell - beforeD.userSell;
        r.userBuy = afterD.userBuy - beforeD.userBuy;
        r.routerSell = afterD.routerSell - beforeD.routerSell;
        r.routerBuy = afterD.routerBuy - beforeD.routerBuy;
        r.userEth = afterD.userEth - beforeD.userEth;
        r.routerEth = afterD.routerEth - beforeD.routerEth;
    }

    // ---------------------------------------------------------------------
    // Tests: swap + send
    // ---------------------------------------------------------------------

    function test_fillQuoteTokenToTokenAndSend_inputFee_success() public {
        uint256 sellAmount = 10e6;
        uint256 feeAmount = 1e6;
        uint256 buyAmount = 10e18;
        SwapParams memory params = _defaultParamsInputFee(sellAmount, feeAmount, buyAmount);
        Permit2 memory permit = _makePermit(address(usdce), sellAmount, 0);

        uint256 userSellBefore = usdce.balanceOf(user);
        uint256 userBuyBefore = wld.balanceOf(user);
        uint256 routerSellBefore = usdce.balanceOf(address(router));

        vm.startPrank(user);
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.FillQuoteTokenToToken(
            address(usdce),
            address(wld),
            user,
            address(dex),
            sellAmount - feeAmount,
            buyAmount,
            FeeToken.INPUT,
            feeAmount
        );
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.FillQuoteAndSend(address(wld), buyAmount, user);

        router.fillQuoteTokenToTokenAndSend(params, user, permit);
        vm.stopPrank();

        assertEq(usdce.balanceOf(user), userSellBefore - sellAmount, "sell debited from user");
        assertEq(wld.balanceOf(user), userBuyBefore + buyAmount, "buy credited to user");
        assertEq(usdce.balanceOf(address(router)), routerSellBefore + feeAmount, "router kept input fee");
        assertEq(wld.balanceOf(address(router)), 0, "router holds no buy token");
    }

    function test_fillQuoteTokenToTokenAndSend_outputFee_success() public {
        uint256 sellAmount = 10e6;
        uint256 feeAmount = 2e18;
        uint256 buyAmount = 10e18;
        SwapParams memory params = _defaultParamsOutputFee(sellAmount, feeAmount, buyAmount);
        Permit2 memory permit = _makePermit(address(usdce), sellAmount, 1);

        uint256 userBuyBefore = wld.balanceOf(user);

        vm.startPrank(user);
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.FillQuoteTokenToToken(
            address(usdce), address(wld), user, address(dex), sellAmount, buyAmount, FeeToken.OUTPUT, feeAmount
        );
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.FillQuoteAndSend(address(wld), buyAmount - feeAmount, user);

        router.fillQuoteTokenToTokenAndSend(params, user, permit);
        vm.stopPrank();

        assertEq(wld.balanceOf(user), userBuyBefore + buyAmount - feeAmount, "user receives net output");
        assertEq(wld.balanceOf(address(router)), feeAmount, "router keeps output fee");
    }

    function test_fillQuoteTokenToTokenAndSend_revert_targetNotApproved() public {
        uint256 sellAmount = 10e6;
        SwapParams memory params = SwapParams({
            sellToken: IERC20(address(usdce)),
            buyToken: IERC20(address(wld)),
            target: payable(address(0xdead)),
            swapCallData: bytes(""),
            sellAmount: sellAmount,
            feeToken: FeeToken.INPUT,
            feeAmount: 0
        });
        Permit2 memory permit = _makePermit(address(usdce), sellAmount, 2);

        vm.startPrank(user);
        vm.expectRevert();
        router.fillQuoteTokenToTokenAndSend(params, user, permit);
        vm.stopPrank();
    }

    function test_fillQuoteTokenToTokenAndSend_revert_feeExceedsOutput() public {
        uint256 sellAmount = 10e6;
        uint256 feeAmount = 20e18;
        uint256 buyAmount = 1e18;
        SwapParams memory params = _defaultParamsOutputFee(sellAmount, feeAmount, buyAmount);
        Permit2 memory permit = _makePermit(address(usdce), sellAmount, 3);

        vm.startPrank(user);
        vm.expectRevert(UnoRouterV2.FeeExceedsOutput.selector);
        router.fillQuoteTokenToTokenAndSend(params, user, permit);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Tests: swap + deposit
    // ---------------------------------------------------------------------

    function test_fillQuoteTokenToTokenAndDeposit_inputFee_success() public {
        uint256 sellAmount = 10e18; // WLD
        uint256 feeAmount = 1e18;
        uint256 buyAmount = 10e6; // USDC (vault asset)
        // Swap WLD -> USDC
        bytes memory swapCallData = abi.encodeWithSignature(
            "swapTokensForTokens(address,address,uint256,uint256)",
            address(wld),
            address(usdce),
            sellAmount - feeAmount,
            buyAmount
        );
        SwapParams memory params = SwapParams({
            sellToken: IERC20(address(wld)),
            buyToken: IERC20(address(usdce)),
            target: payable(address(dex)),
            swapCallData: swapCallData,
            sellAmount: sellAmount,
            feeToken: FeeToken.INPUT,
            feeAmount: feeAmount
        });
        Permit2 memory permit = _makePermit(address(wld), sellAmount, 4);

        uint256 routerFeeBefore = wld.balanceOf(address(router));
        uint256 sharesBefore = vault.balanceOf(user);

        vm.startPrank(user);
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.FillQuoteTokenToToken(
            address(wld),
            address(usdce),
            user,
            address(dex),
            sellAmount - feeAmount,
            buyAmount,
            FeeToken.INPUT,
            feeAmount
        );
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.FillQuoteAndDeposit(address(usdce), buyAmount, user, address(vault));

        uint256 shares = router.fillQuoteTokenToTokenAndDeposit(params, address(vault), user, permit);
        vm.stopPrank();

        assertEq(shares, buyAmount, "shares should equal deposited amount");
        assertEq(vault.balanceOf(user), sharesBefore + buyAmount, "receiver gets vault shares");
        assertEq(wld.balanceOf(address(router)), routerFeeBefore + feeAmount, "router keeps input fee (sell token)");
    }

    function test_fillQuoteTokenToTokenAndDeposit_outputFee_success() public {
        uint256 sellAmount = 10e6;
        uint256 feeAmount = 2e6;
        uint256 buyAmount = 10e6;
        bytes memory swapCallData = abi.encodeWithSignature(
            "swapTokensForTokens(address,address,uint256,uint256)",
            address(usdce),
            address(usdce),
            sellAmount,
            buyAmount
        );
        SwapParams memory params = SwapParams({
            sellToken: IERC20(address(usdce)),
            buyToken: IERC20(address(usdce)),
            target: payable(address(dex)),
            swapCallData: swapCallData,
            sellAmount: sellAmount,
            feeToken: FeeToken.OUTPUT,
            feeAmount: feeAmount
        });
        Permit2 memory permit = _makePermit(address(usdce), sellAmount, 5);

        uint256 routerFeeBefore = usdce.balanceOf(address(router));

        vm.startPrank(user);
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.FillQuoteTokenToToken(
            address(usdce), address(usdce), user, address(dex), sellAmount, buyAmount, FeeToken.OUTPUT, feeAmount
        );
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.FillQuoteAndDeposit(address(usdce), buyAmount - feeAmount, user, address(vault));

        uint256 shares = router.fillQuoteTokenToTokenAndDeposit(params, address(vault), user, permit);
        vm.stopPrank();

        assertEq(shares, buyAmount - feeAmount, "shares reflect net deposit");
        assertEq(usdce.balanceOf(address(router)), routerFeeBefore + feeAmount, "fee retained");
    }

    function test_fillQuoteTokenToTokenAndDeposit_revert_targetNotApproved() public {
        uint256 sellAmount = 10e6;
        SwapParams memory params = SwapParams({
            sellToken: IERC20(address(usdce)),
            buyToken: IERC20(address(usdce)),
            target: payable(address(0xdead)),
            swapCallData: bytes(""),
            sellAmount: sellAmount,
            feeToken: FeeToken.INPUT,
            feeAmount: 0
        });
        Permit2 memory permit = _makePermit(address(usdce), sellAmount, 6);

        vm.startPrank(user);
        vm.expectRevert();
        router.fillQuoteTokenToTokenAndDeposit(params, address(vault), user, permit);
        vm.stopPrank();
    }

    function test_fillQuoteTokenToTokenAndDeposit_revert_feeExceedsOutput() public {
        uint256 sellAmount = 10e6;
        uint256 feeAmount = 20e6;
        uint256 buyAmount = 1e6;
        bytes memory swapCallData = abi.encodeWithSignature(
            "swapTokensForTokens(address,address,uint256,uint256)",
            address(usdce),
            address(usdce),
            sellAmount,
            buyAmount
        );
        SwapParams memory params = SwapParams({
            sellToken: IERC20(address(usdce)),
            buyToken: IERC20(address(usdce)),
            target: payable(address(dex)),
            swapCallData: swapCallData,
            sellAmount: sellAmount,
            feeToken: FeeToken.OUTPUT,
            feeAmount: feeAmount
        });
        Permit2 memory permit = _makePermit(address(usdce), sellAmount, 7);

        vm.startPrank(user);
        vm.expectRevert(UnoRouterV2.FeeExceedsOutput.selector);
        router.fillQuoteTokenToTokenAndDeposit(params, address(vault), user, permit);
        vm.stopPrank();
    }

    function test_fillQuoteTokenToTokenAndDepositViaRouter_inputFee_success() public {
        MockUnoMorphoRouter unoMorphoRouter = new MockUnoMorphoRouter(
            IERC20(address(usdce)),
            IERC4626(address(vault))
        );

        uint256 sellAmount = 10e18; // WLD
        uint256 feeAmount = 1e18;
        uint256 buyAmount = 10e6; // USDC (router asset)
        bytes memory swapCallData = abi.encodeWithSignature(
            "swapTokensForTokens(address,address,uint256,uint256)",
            address(wld),
            address(usdce),
            sellAmount - feeAmount,
            buyAmount
        );
        SwapParams memory params = SwapParams({
            sellToken: IERC20(address(wld)),
            buyToken: IERC20(address(usdce)),
            target: payable(address(dex)),
            swapCallData: swapCallData,
            sellAmount: sellAmount,
            feeToken: FeeToken.INPUT,
            feeAmount: feeAmount
        });
        Permit2 memory permit = _makePermit(address(wld), sellAmount, 10);

        uint256 sharesBefore = vault.balanceOf(user);

        vm.startPrank(user);
        uint256 shares = router.fillQuoteTokenToTokenAndDepositViaRouter(
            params,
            address(unoMorphoRouter),
            user,
            permit
        );
        vm.stopPrank();

        assertEq(shares, buyAmount, "shares should equal deposited amount");
        assertEq(unoMorphoRouter.lastCaller(), address(router), "router should call UnoMorphoRouter");
        assertEq(unoMorphoRouter.lastReceiver(), user, "receiver should match");
        assertEq(unoMorphoRouter.lastAssets(), buyAmount, "assets should match");
        assertEq(vault.balanceOf(user), sharesBefore + buyAmount, "receiver gets vault shares");
    }

    function test_fillQuoteTokenToTokenAndDepositViaRouter_revert_invalidAsset() public {
        MockUnoMorphoRouter unoMorphoRouter = new MockUnoMorphoRouter(
            IERC20(address(wld)),
            IERC4626(address(vault))
        );

        uint256 sellAmount = 10e18;
        uint256 feeAmount = 1e18;
        uint256 buyAmount = 10e6;
        bytes memory swapCallData = abi.encodeWithSignature(
            "swapTokensForTokens(address,address,uint256,uint256)",
            address(wld),
            address(usdce),
            sellAmount - feeAmount,
            buyAmount
        );
        SwapParams memory params = SwapParams({
            sellToken: IERC20(address(wld)),
            buyToken: IERC20(address(usdce)),
            target: payable(address(dex)),
            swapCallData: swapCallData,
            sellAmount: sellAmount,
            feeToken: FeeToken.INPUT,
            feeAmount: feeAmount
        });
        Permit2 memory permit = _makePermit(address(wld), sellAmount, 11);

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                UnoRouterV2.InvalidDepositAsset.selector,
                address(wld),
                address(usdce)
            )
        );
        router.fillQuoteTokenToTokenAndDepositViaRouter(params, address(unoMorphoRouter), user, permit);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Tests: existing function compatibility (no new events)
    // ---------------------------------------------------------------------

    function test_fillQuoteTokenToToken_emitsOnlyLegacyEvent() public {
        uint256 sellAmount = 10e6;
        uint256 buyAmount = 5e18;
        uint256 feeAmount = 1e6;
        bytes memory swapCallData = abi.encodeWithSignature(
            "swapTokensForTokens(address,address,uint256,uint256)",
            address(usdce),
            address(wld),
            sellAmount - feeAmount,
            buyAmount
        );
        uint256 nonce = 8;
        Permit2 memory permit = _makePermit(address(usdce), sellAmount, nonce);

        vm.startPrank(user);
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.FillQuoteTokenToToken(
            address(usdce),
            address(wld),
            user,
            address(dex),
            sellAmount - feeAmount,
            buyAmount,
            FeeToken.INPUT,
            feeAmount
        );
        router.fillQuoteTokenToToken(
            address(usdce),
            address(wld),
            payable(address(dex)),
            swapCallData,
            sellAmount,
            FeeToken(uint8(0)),
            feeAmount,
            permit
        );
        vm.stopPrank();
    }

    function test_fillQuoteEthToToken_legacy_events_only() public {
        uint256 feeAmount = 0.01 ether;
        uint256 ethAmount = 1 ether;
        uint256 buyAmount = 1000e6;
        bytes memory swapCallData =
            abi.encodeWithSignature("swapEthForTokens(address,uint256)", address(usdce), buyAmount);
        address payable target = payable(address(dex));

        vm.startPrank(user);
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.FillQuoteEthToToken(address(usdce), user, target, ethAmount - feeAmount, buyAmount, feeAmount);
        router.fillQuoteEthToToken{ value: ethAmount }(address(usdce), target, swapCallData, feeAmount);
        vm.stopPrank();
    }

    function test_fillQuoteTokenToEth_legacy_events_only() public {
        uint256 sellAmount = 10e6;
        uint256 buyAmount = 1 ether;
        uint256 feePercentage = 0.1e18; // 10%
        bytes memory swapCallData = abi.encodeWithSignature(
            "swapTokensForEth(address,uint256,uint256)", address(usdce), sellAmount, buyAmount
        );
        Permit2 memory permit = _makePermit(address(usdce), sellAmount, 9);

        vm.startPrank(user);
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.FillQuoteTokenToEth(
            address(usdce),
            user,
            address(dex),
            sellAmount,
            buyAmount - ((buyAmount * feePercentage) / 1e18),
            (buyAmount * feePercentage) / 1e18
        );
        router.fillQuoteTokenToEth(
            address(usdce), payable(address(dex)), swapCallData, sellAmount, feePercentage, permit
        );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Admin parity: swap targets and fee withdrawals
    // ---------------------------------------------------------------------

    function test_updateSwapTargets_add_and_remove() public {
        address newTarget = makeAddr("newTarget");
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.SwapTargetAdded(newTarget);
        router.updateSwapTargets(newTarget, true);
        assertTrue(router.swapTargets(newTarget));

        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.SwapTargetRemoved(newTarget);
        router.updateSwapTargets(newTarget, false);
        assertFalse(router.swapTargets(newTarget));
        vm.stopPrank();
    }

    function test_withdrawToken() public {
        uint256 amount = 100e6;
        uint256 routerBefore = usdce.balanceOf(address(router));
        uint256 ownerBefore = usdce.balanceOf(owner);

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.TokenWithdrawn(address(usdce), owner, amount);
        router.withdrawToken(address(usdce), owner, amount);
        vm.stopPrank();

        assertEq(usdce.balanceOf(address(router)), routerBefore - amount, "router debited");
        assertEq(usdce.balanceOf(owner), ownerBefore + amount, "owner credited");
    }

    function test_withdrawEth() public {
        uint256 amount = 1 ether;
        uint256 routerBefore = address(router).balance;
        uint256 ownerBefore = owner.balance;

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit UnoRouterV2.EthWithdrawn(owner, amount);
        router.withdrawEth(owner, amount);
        vm.stopPrank();

        assertEq(address(router).balance, routerBefore - amount, "router debited");
        assertEq(owner.balance, ownerBefore + amount, "owner credited");
    }

    // ---------------------------------------------------------------------
    // Parity: UnoRouter (v1) vs UnoRouterV2 (state deltas)
    // ---------------------------------------------------------------------

    function test_parity_fillQuoteTokenToToken_inputFee() public {
        Env memory e = _deployEnv();
        uint256 sellAmount = 10e6;
        uint256 feeAmount = 1e6;
        uint256 buyAmount = 10e18;
        bytes memory swapCallData = abi.encodeWithSignature(
            "swapTokensForTokens(address,address,uint256,uint256)",
            address(e.usdce),
            address(e.wld),
            sellAmount - feeAmount,
            buyAmount
        );
        Permit2 memory permit = _makePermit(address(e.usdce), sellAmount, 20);

        // Legacy
        Delta memory beforeLegacy = _delta(address(e.usdce), address(e.wld), address(e.legacy));
        vm.prank(user);
        e.legacy
            .fillQuoteTokenToToken(
                address(e.usdce),
                address(e.wld),
                payable(address(e.dex)),
                swapCallData,
                sellAmount,
                LegacyFeeToken.INPUT,
                feeAmount,
                permit
            );
        Delta memory dLegacy = _subtract(_delta(address(e.usdce), address(e.wld), address(e.legacy)), beforeLegacy);

        // V2
        Delta memory beforeV2 = _delta(address(e.usdce), address(e.wld), address(e.v2));
        vm.prank(user);
        e.v2
            .fillQuoteTokenToToken(
                address(e.usdce),
                address(e.wld),
                payable(address(e.dex)),
                swapCallData,
                sellAmount,
                FeeToken.INPUT,
                feeAmount,
                permit
            );
        Delta memory dV2 = _subtract(_delta(address(e.usdce), address(e.wld), address(e.v2)), beforeV2);

        assertEq(dLegacy.userSell, dV2.userSell, "user sell delta");
        assertEq(dLegacy.userBuy, dV2.userBuy, "user buy delta");
        assertEq(dLegacy.routerSell, dV2.routerSell, "router fee delta (sell token)");
        assertEq(dLegacy.routerBuy, dV2.routerBuy, "router buy delta");
        assertEq(dLegacy.userEth, dV2.userEth, "user eth delta");
        assertEq(dLegacy.routerEth, dV2.routerEth, "router eth delta");
    }

    function test_parity_fillQuoteTokenToToken_outputFee() public {
        Env memory e = _deployEnv();
        uint256 sellAmount = 10e6;
        uint256 feeAmount = 2e18;
        uint256 buyAmount = 10e18;
        bytes memory swapCallData = abi.encodeWithSignature(
            "swapTokensForTokens(address,address,uint256,uint256)",
            address(e.usdce),
            address(e.wld),
            sellAmount,
            buyAmount
        );
        Permit2 memory permit = _makePermit(address(e.usdce), sellAmount, 21);

        Delta memory beforeLegacy = _delta(address(e.usdce), address(e.wld), address(e.legacy));
        vm.prank(user);
        e.legacy
            .fillQuoteTokenToToken(
                address(e.usdce),
                address(e.wld),
                payable(address(e.dex)),
                swapCallData,
                sellAmount,
                LegacyFeeToken.OUTPUT,
                feeAmount,
                permit
            );
        Delta memory dLegacy = _subtract(_delta(address(e.usdce), address(e.wld), address(e.legacy)), beforeLegacy);

        Delta memory beforeV2 = _delta(address(e.usdce), address(e.wld), address(e.v2));
        vm.prank(user);
        e.v2
            .fillQuoteTokenToToken(
                address(e.usdce),
                address(e.wld),
                payable(address(e.dex)),
                swapCallData,
                sellAmount,
                FeeToken.OUTPUT,
                feeAmount,
                permit
            );
        Delta memory dV2 = _subtract(_delta(address(e.usdce), address(e.wld), address(e.v2)), beforeV2);

        assertEq(dLegacy.userSell, dV2.userSell, "user sell delta");
        assertEq(dLegacy.userBuy, dV2.userBuy, "user buy delta");
        assertEq(dLegacy.routerSell, dV2.routerSell, "router fee delta (sell token)");
        assertEq(dLegacy.routerBuy, dV2.routerBuy, "router fee delta (buy token)");
        assertEq(dLegacy.userEth, dV2.userEth, "user eth delta");
        assertEq(dLegacy.routerEth, dV2.routerEth, "router eth delta");
    }

    function test_parity_fillQuoteEthToToken() public {
        Env memory e = _deployEnv();
        uint256 feeAmount = 0.01 ether;
        uint256 ethAmount = 1 ether;
        uint256 buyAmount = 1000e6;
        bytes memory swapCallData =
            abi.encodeWithSignature("swapEthForTokens(address,uint256)", address(e.usdce), buyAmount);

        Delta memory beforeLegacy = _delta(address(e.usdce), address(e.usdce), address(e.legacy));
        vm.prank(user);
        e.legacy.fillQuoteEthToToken{ value: ethAmount }(
            address(e.usdce), payable(address(e.dex)), swapCallData, feeAmount
        );
        Delta memory dLegacy = _subtract(_delta(address(e.usdce), address(e.usdce), address(e.legacy)), beforeLegacy);

        Delta memory beforeV2 = _delta(address(e.usdce), address(e.usdce), address(e.v2));
        vm.prank(user);
        e.v2.fillQuoteEthToToken{ value: ethAmount }(address(e.usdce), payable(address(e.dex)), swapCallData, feeAmount);
        Delta memory dV2 = _subtract(_delta(address(e.usdce), address(e.usdce), address(e.v2)), beforeV2);

        assertEq(dLegacy.userSell, dV2.userSell, "user sell delta (eth not tracked here)");
        assertEq(dLegacy.userBuy, dV2.userBuy, "user buy delta");
        assertEq(dLegacy.routerEth, dV2.routerEth, "router eth delta (fee)");
        assertEq(dLegacy.userEth, dV2.userEth, "user eth delta");
    }

    function test_parity_fillQuoteTokenToEth() public {
        Env memory e = _deployEnv();
        uint256 sellAmount = 10e6;
        uint256 buyAmount = 1 ether;
        uint256 feePercentage = 0.1e18; // 10%
        bytes memory swapCallData = abi.encodeWithSignature(
            "swapTokensForEth(address,uint256,uint256)", address(e.usdce), sellAmount, buyAmount
        );
        Permit2 memory permit = _makePermit(address(e.usdce), sellAmount, 22);

        Delta memory beforeLegacy = _delta(address(e.usdce), address(e.usdce), address(e.legacy));
        vm.prank(user);
        e.legacy
            .fillQuoteTokenToEth(
                address(e.usdce), payable(address(e.dex)), swapCallData, sellAmount, feePercentage, permit
            );
        Delta memory dLegacy = _subtract(_delta(address(e.usdce), address(e.usdce), address(e.legacy)), beforeLegacy);

        Delta memory beforeV2 = _delta(address(e.usdce), address(e.usdce), address(e.v2));
        vm.prank(user);
        e.v2
            .fillQuoteTokenToEth(
                address(e.usdce), payable(address(e.dex)), swapCallData, sellAmount, feePercentage, permit
            );
        Delta memory dV2 = _subtract(_delta(address(e.usdce), address(e.usdce), address(e.v2)), beforeV2);

        assertEq(dLegacy.userSell, dV2.userSell, "user sell delta");
        assertEq(dLegacy.userBuy, dV2.userBuy, "user buy delta (not used)");
        assertEq(dLegacy.routerEth, dV2.routerEth, "router eth delta (fee)");
        assertEq(dLegacy.userEth, dV2.userEth, "user eth delta");
    }
}
