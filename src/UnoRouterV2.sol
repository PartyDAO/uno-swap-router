// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";
import { Permit2Helper, Permit2 } from "./Permit2Helper.sol";

/// @notice Token side used for fee collection.
enum FeeToken {
    INPUT,
    OUTPUT
}

/// @notice Parameters for token-to-token swap flows.
struct SwapParams {
    IERC20 sellToken;
    IERC20 buyToken;
    address payable target;
    bytes swapCallData;
    uint256 sellAmount;
    FeeToken feeToken;
    uint256 feeAmount;
}

/// @title UnoRouterV2
/// @notice Upgradeable router with atomic swap+send and swap+deposit flows, preserving UnoRouter v1 behavior and
/// events.
contract UnoRouterV2 is Initializable, Permit2Helper, ReentrancyGuardUpgradeable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    string public constant VERSION = "0.1.0";

    /// @notice Set of allowed swapTargets.
    mapping(address => bool) public swapTargets;

    event SwapTargetUpdated(address indexed target, bool approved);
    event SwapTargetAdded(address indexed target);
    event SwapTargetRemoved(address indexed target);
    event TokenWithdrawn(address indexed token, address indexed target, uint256 amount);
    event EthWithdrawn(address indexed target, uint256 amount);

    event FillQuoteTokenToToken(
        address indexed sellToken,
        address indexed buyToken,
        address indexed user,
        address target,
        uint256 amountSold,
        uint256 amountBought,
        FeeToken feeToken,
        uint256 feeAmount
    );
    event FillQuoteTokenToEth(
        address indexed sellToken,
        address indexed user,
        address target,
        uint256 amountSold,
        uint256 amountBought,
        uint256 feeAmount
    );
    event FillQuoteEthToToken(
        address indexed buyToken,
        address indexed user,
        address target,
        uint256 amountSold,
        uint256 amountBought,
        uint256 feeAmount
    );

    event FillQuoteAndSend(address indexed buyToken, uint256 buyTokenAmount, address sendTo);
    event FillQuoteAndDeposit(address indexed buyToken, uint256 buyTokenAmount, address depositTo, address vault);

    error TargetNotAuthorized(address target);
    error AllowanceNotZero(address token, address target, uint256 allowance);
    error NoTokensReceived(address token);
    error FeeExceedsOutput();

    modifier onlyApprovedTarget(address target) {
        if (!swapTargets[target]) revert TargetNotAuthorized(target);
        _;
    }

    /// @notice Initializes the router with owner and approved swap targets.
    /// @param owner_ Owner address (multisig).
    /// @param swapTargets_ Pre-approved aggregator addresses.
    function initialize(address owner_, address[] memory swapTargets_) external initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        for (uint256 i = 0; i < swapTargets_.length; i++) {
            swapTargets[swapTargets_[i]] = true;
        }
    }

    /// @notice Accept ETH only during swaps or from owner.
    receive() external payable {
        require(_reentrancyGuardEntered() || msg.sender == owner(), "NO_RECEIVE");
    }

    /// @param permit2_ Immutable Permit2 address.
    constructor(ISignatureTransfer permit2_) Permit2Helper(permit2_) {
        _disableInitializers();
    }

    /// @notice Update an aggregator target approval (legacy parity).
    function setSwapTarget(address target, bool approved) external onlyOwner {
        swapTargets[target] = approved;
        emit SwapTargetUpdated(target, approved);
    }

    /// @notice Add or remove a swap target.
    /// @param target Aggregator target.
    /// @param add True to add, false to remove.
    function updateSwapTargets(address target, bool add) external onlyOwner {
        swapTargets[target] = add;
        if (add) {
            emit SwapTargetAdded(target);
        } else {
            emit SwapTargetRemoved(target);
        }
    }

    /// @notice Withdraw ERC20 tokens held by the contract.
    /// @param token Token address to withdraw.
    /// @param to Recipient address.
    /// @param amount Amount to withdraw.
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "ZERO_ADDRESS");
        IERC20(token).safeTransfer(to, amount);
        emit TokenWithdrawn(token, to, amount);
    }

    /// @notice Withdraw ETH held by the contract.
    /// @param to Recipient address.
    /// @param amount Amount to withdraw.
    function withdrawEth(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "ZERO_ADDRESS");
        Address.sendValue(payable(to), amount);
        emit EthWithdrawn(to, amount);
    }

    /// @notice Swap ERC20->ERC20, emit legacy event.
    /// @param sellTokenAddress Token sold.
    /// @param buyTokenAddress Token bought.
    /// @param target Approved aggregator.
    /// @param swapCallData Calldata for aggregator.
    /// @param sellAmount Amount of sell token.
    /// @param feeToken Fee side (input/output).
    /// @param feeAmount Fee amount.
    /// @param permit Permit2 data.
    function fillQuoteTokenToToken(
        address sellTokenAddress,
        address buyTokenAddress,
        address payable target,
        bytes calldata swapCallData,
        uint256 sellAmount,
        FeeToken feeToken,
        uint256 feeAmount,
        Permit2 calldata permit
    )
        external
        payable
        nonReentrant
        onlyApprovedTarget(target)
    {
        uint256 initialOutputTokenAmount = IERC20(buyTokenAddress).balanceOf(address(this));

        _pullTokensViaPermit2(sellTokenAddress, sellAmount, permit);

        uint256 tokensToSwap = feeToken == FeeToken.INPUT ? sellAmount - feeAmount : sellAmount;
        IERC20(sellTokenAddress).forceApprove(target, tokensToSwap);

        _executeSwapCall(target, swapCallData, msg.value);

        uint256 allowance = IERC20(sellTokenAddress).allowance(address(this), target);
        if (allowance != 0) revert AllowanceNotZero(sellTokenAddress, target, allowance);

        uint256 finalOutputTokenAmount = IERC20(buyTokenAddress).balanceOf(address(this));
        if (finalOutputTokenAmount <= initialOutputTokenAmount) revert NoTokensReceived(buyTokenAddress);

        uint256 tokensDiff = finalOutputTokenAmount - initialOutputTokenAmount;
        uint256 tokensToSend = feeToken == FeeToken.OUTPUT ? tokensDiff - feeAmount : tokensDiff;
        IERC20(buyTokenAddress).safeTransfer(msg.sender, tokensToSend);

        emit FillQuoteTokenToToken(
            sellTokenAddress, buyTokenAddress, msg.sender, target, tokensToSwap, tokensToSend, feeToken, feeAmount
        );
    }

    /// @notice Swap ETH->ERC20, emit legacy event.
    /// @param buyTokenAddress Token bought.
    /// @param target Approved aggregator.
    /// @param swapCallData Calldata for aggregator.
    /// @param feeAmount Fee in wei.
    function fillQuoteEthToToken(
        address buyTokenAddress,
        address payable target,
        bytes calldata swapCallData,
        uint256 feeAmount
    )
        external
        payable
        nonReentrant
        onlyApprovedTarget(target)
    {
        uint256 initialTokenBalance = IERC20(buyTokenAddress).balanceOf(address(this));
        uint256 initialEthAmount = address(this).balance - msg.value;
        uint256 sellAmount = msg.value - feeAmount;

        _executeSwapCall(target, swapCallData, sellAmount);

        uint256 finalTokenBalance = IERC20(buyTokenAddress).balanceOf(address(this));
        if (finalTokenBalance <= initialTokenBalance) revert NoTokensReceived(buyTokenAddress);

        uint256 tokensToSend = finalTokenBalance - initialTokenBalance;
        IERC20(buyTokenAddress).safeTransfer(msg.sender, tokensToSend);

        uint256 finalEthAmount = address(this).balance - feeAmount;
        if (finalEthAmount > initialEthAmount) {
            uint256 ethDiff = finalEthAmount - initialEthAmount;
            Address.sendValue(payable(msg.sender), ethDiff);
            sellAmount -= ethDiff;
        }

        emit FillQuoteEthToToken(buyTokenAddress, msg.sender, target, sellAmount, tokensToSend, feeAmount);
    }

    /// @notice Swap ERC20->ETH, emit legacy event.
    /// @param sellTokenAddress Token sold.
    /// @param target Approved aggregator.
    /// @param swapCallData Calldata for aggregator.
    /// @param sellAmount Amount of sell token.
    /// @param feePercentage Fee percentage in 1e18 precision.
    /// @param permit Permit2 data.
    function fillQuoteTokenToEth(
        address sellTokenAddress,
        address payable target,
        bytes calldata swapCallData,
        uint256 sellAmount,
        uint256 feePercentage,
        Permit2 calldata permit
    )
        external
        payable
        nonReentrant
        onlyApprovedTarget(target)
    {
        uint256 initialEthAmount = address(this).balance - msg.value;

        _pullTokensViaPermit2(sellTokenAddress, sellAmount, permit);

        IERC20(sellTokenAddress).forceApprove(target, sellAmount);

        _executeSwapCall(target, swapCallData, msg.value);

        uint256 allowance = IERC20(sellTokenAddress).allowance(address(this), target);
        if (allowance != 0) revert AllowanceNotZero(sellTokenAddress, target, allowance);

        uint256 finalEthAmount = address(this).balance;
        uint256 ethDiff = finalEthAmount - initialEthAmount;
        require(ethDiff > 0, "NO_ETH_BACK");

        uint256 fees;
        uint256 ethToSend;
        if (feePercentage > 0) {
            fees = (ethDiff * feePercentage) / 1e18;
            ethToSend = ethDiff - fees;
            Address.sendValue(payable(msg.sender), ethToSend);
        } else if (ethDiff > 0) {
            ethToSend = ethDiff;
            Address.sendValue(payable(msg.sender), ethToSend);
        }

        emit FillQuoteTokenToEth(sellTokenAddress, msg.sender, target, sellAmount, ethToSend, fees);
    }

    /// @notice Swap ERC20->ERC20 and send to recipient; emits legacy and new events.
    /// @param params Swap parameters (sell/buy tokens, target, calldata, amounts, fee).
    /// @param recipient Address receiving bought tokens.
    /// @param permit Permit2 data.
    function fillQuoteTokenToTokenAndSend(
        SwapParams calldata params,
        address recipient,
        Permit2 calldata permit
    )
        external
        payable
        nonReentrant
        onlyApprovedTarget(params.target)
    {
        (uint256 tokensSwapped, uint256 outputReceived) = _executeSwapWithPermit(params, permit);

        emit FillQuoteTokenToToken(
            address(params.sellToken),
            address(params.buyToken),
            msg.sender,
            params.target,
            tokensSwapped,
            outputReceived,
            params.feeToken,
            params.feeAmount
        );

        if (params.feeToken == FeeToken.OUTPUT && params.feeAmount > outputReceived) revert FeeExceedsOutput();
        uint256 tokensToSend = params.feeToken == FeeToken.OUTPUT ? outputReceived - params.feeAmount : outputReceived;

        params.buyToken.safeTransfer(recipient, tokensToSend);

        emit FillQuoteAndSend(address(params.buyToken), tokensToSend, recipient);
    }

    /// @notice Swap ERC20->ERC20 and deposit into ERC4626 vault; emits legacy and new events.
    /// @param params Swap parameters (sell/buy tokens, target, calldata, amounts, fee).
    /// @param vault ERC4626 vault address.
    /// @param receiver Recipient of vault shares.
    /// @param permit Permit2 data.
    /// @return shares Vault shares minted.
    function fillQuoteTokenToTokenAndDeposit(
        SwapParams calldata params,
        address vault,
        address receiver,
        Permit2 calldata permit
    )
        external
        payable
        nonReentrant
        onlyApprovedTarget(params.target)
        returns (uint256 shares)
    {
        (uint256 tokensSwapped, uint256 outputReceived) = _executeSwapWithPermit(params, permit);

        emit FillQuoteTokenToToken(
            address(params.sellToken),
            address(params.buyToken),
            msg.sender,
            params.target,
            tokensSwapped,
            outputReceived,
            params.feeToken,
            params.feeAmount
        );

        if (params.feeToken == FeeToken.OUTPUT && params.feeAmount > outputReceived) revert FeeExceedsOutput();
        uint256 tokensToDeposit =
            params.feeToken == FeeToken.OUTPUT ? outputReceived - params.feeAmount : outputReceived;

        params.buyToken.forceApprove(vault, tokensToDeposit);
        shares = IERC4626(vault).deposit(tokensToDeposit, receiver);

        emit FillQuoteAndDeposit(address(params.buyToken), tokensToDeposit, receiver, vault);
    }

    /// @dev Execute swap flow: Permit2 pull -> approve -> swap -> validate.
    /// @dev Swap helper: Permit2 pull -> approve -> swap -> validate outputs.
    function _executeSwapWithPermit(
        SwapParams calldata params,
        Permit2 calldata permit
    )
        internal
        returns (uint256 tokensSwapped, uint256 outputReceived)
    {
        uint256 initialBalance = params.buyToken.balanceOf(address(this));

        _pullTokensViaPermit2(address(params.sellToken), params.sellAmount, permit);

        tokensSwapped = params.feeToken == FeeToken.INPUT ? params.sellAmount - params.feeAmount : params.sellAmount;

        params.sellToken.forceApprove(params.target, tokensSwapped);
        _executeSwapCall(params.target, params.swapCallData, msg.value);

        uint256 allowance = params.sellToken.allowance(address(this), params.target);
        if (allowance != 0) revert AllowanceNotZero(address(params.sellToken), params.target, allowance);

        uint256 finalBalance = params.buyToken.balanceOf(address(this));
        if (finalBalance <= initialBalance) revert NoTokensReceived(address(params.buyToken));

        outputReceived = finalBalance - initialBalance;
    }

    /// @dev Executes low-level swap call; bubbles revert data.
    function _executeSwapCall(address payable target, bytes calldata swapCallData, uint256 value) internal {
        (bool success, bytes memory res) = target.call{ value: value }(swapCallData);
        if (!success) {
            assembly {
                let returndata_size := mload(res)
                revert(add(32, res), returndata_size)
            }
        }
    }

    /// @dev Pull tokens from caller via Permit2 (immutable PERMIT2).
    function _pullTokensViaPermit2(address token, uint256 amount, Permit2 calldata permitData) internal {
        PERMIT2.permitTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({ token: token, amount: amount }),
                nonce: permitData.nonce,
                deadline: permitData.deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: amount }),
            msg.sender,
            permitData.signature
        );
    }

    /// @dev UUPS authorization hook.
    function _authorizeUpgrade(address) internal override onlyOwner { }
}

