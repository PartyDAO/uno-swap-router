// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Permit2HelperUpgradeable, Permit2 } from "./utils/Permit2HelperUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";

/// @notice Fee deduction type for swap operations
enum FeeToken {
    INPUT,
    OUTPUT
}

/// @notice Parameters for swap operations
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
/// @notice Upgradeable version of UnoRouter with additional atomic swap functions
/// @dev Extends UnoRouter functionality with fillQuoteTokenToTokenAndSend and fillQuoteTokenToTokenAndDeposit
///      Maintains all existing UnoRouter functions and events for analytics compatibility
contract UnoRouterV2 is
    Initializable,
    Permit2HelperUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                VERSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract version string
    string public constant VERSION = "0.1.0";

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Set of allowed swap targets (mirrors UnoRouter pattern)
    mapping(address => bool) public swapTargets;

    /// @custom:oz-upgrades-unsafe-allow state-variable-usage
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when tokens are swapped (same as original UnoRouter)
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

    /// @notice Emitted when ETH is swapped for tokens (same as original UnoRouter)
    event FillQuoteEthToToken(
        address indexed buyToken,
        address indexed user,
        address target,
        uint256 amountSold,
        uint256 amountBought,
        uint256 feeAmount
    );

    /// @notice Emitted when tokens are swapped for ETH (same as original UnoRouter)
    event FillQuoteTokenToEth(
        address indexed sellToken,
        address indexed user,
        address target,
        uint256 amountSold,
        uint256 amountBought,
        uint256 feeAmount
    );

    /// @notice Emitted when tokens are swapped and sent to a recipient
    event SwapAndSend(
        address indexed sellToken,
        address indexed buyToken,
        address indexed user,
        address recipient,
        uint256 tokensSwapped,
        uint256 tokensSent,
        FeeToken feeToken,
        uint256 feeAmount
    );

    /// @notice Emitted when tokens are swapped and deposited into a vault
    event SwapAndDeposit(
        address indexed sellToken,
        address indexed vault,
        address indexed user,
        address receiver,
        uint256 tokensSwapped,
        uint256 tokensDeposited,
        uint256 sharesMinted,
        FeeToken feeToken,
        uint256 feeAmount
    );

    /// @notice Emitted when a swap target gets added (same as original UnoRouter)
    event SwapTargetAdded(address indexed target);

    /// @notice Emitted when a swap target gets removed (same as original UnoRouter)
    event SwapTargetRemoved(address indexed target);

    /// @notice Emitted when token fees are withdrawn (same as original UnoRouter)
    event TokenWithdrawn(address indexed token, address indexed target, uint256 amount);

    /// @notice Emitted when ETH fees are withdrawn (same as original UnoRouter)
    event EthWithdrawn(address indexed target, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller attempts to use a non-approved swap target
    error TargetNotApproved(address target);

    /// @notice Thrown when allowance was not fully consumed by swap
    error AllowanceNotZero(address token, address spender, uint256 allowance);

    /// @notice Thrown when no tokens were received from swap
    error NoTokensReceived(address buyToken);

    /// @notice Thrown when zero address is provided
    error ZeroAddress();

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when fee amount exceeds output amount
    error FeeExceedsOutput();

    /// @notice Thrown when amount is zero or invalid
    error InvalidAmount();

    /// @notice Thrown when no ETH was received
    error NoEthBack();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Modifier that ensures only approved targets can be called
    /// @param target The swap target address to check
    modifier onlyApprovedTarget(address target) {
        require(swapTargets[target], TargetNotApproved(target));
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Disables initializers to prevent initialization outside of proxy pattern
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the UnoRouterV2
    /// @param _permit2 The Permit2 contract address
    /// @param _owner The initial owner address
    /// @param _swapTargets Array of initial swap target addresses to approve
    function initialize(
        ISignatureTransfer _permit2,
        address _owner,
        address[] memory _swapTargets
    ) public initializer {
        require(_owner != address(0), ZeroAddress());
        require(address(_permit2) != address(0), ZeroAddress());

        __Permit2HelperUpgradeable_init(_permit2);
        __ReentrancyGuard_init();
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();

        for (uint256 i = 0; i < _swapTargets.length; i++) {
            swapTargets[_swapTargets[i]] = true;
            emit SwapTargetAdded(_swapTargets[i]);
        }
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation The address of the new implementation contract
    function _authorizeUpgrade(address newImplementation) internal view override {
        require(msg.sender == owner(), Unauthorized());
        require(newImplementation != address(0), ZeroAddress());
    }

    /// @dev We don't want to accept any ETH, except refunds from aggregators
    /// or the owner (for testing purposes), which can also withdraw
    /// This is done by evaluating the value of status, which is set to 2
    /// only during swaps due to the "nonReentrant" modifier
    receive() external payable {
        require(_reentrancyGuardEntered() || msg.sender == owner(), "NO_RECEIVE");
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Add or remove a swap target from the approved list (same as original UnoRouter)
    /// @param target The swap target address
    /// @param add Whether to add (true) or remove (false) the target
    function updateSwapTargets(address target, bool add) external onlyOwner {
        swapTargets[target] = add;
        if (add) {
            emit SwapTargetAdded(target);
        } else {
            emit SwapTargetRemoved(target);
        }
    }

    /// @notice Withdraw ERC20 tokens (from the fees) (same as original UnoRouter)
    /// @param token The token address
    /// @param to The address receiving the tokens
    /// @param amount The amount of tokens to withdraw
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), ZeroAddress());
        IERC20(token).safeTransfer(to, amount);
        emit TokenWithdrawn(token, to, amount);
    }

    /// @notice Withdraw ETH (from the fees) (same as original UnoRouter)
    /// @param to The address receiving the ETH
    /// @param amount The amount of ETH to withdraw
    function withdrawEth(address to, uint256 amount) external onlyOwner {
        require(to != address(0), ZeroAddress());
        (bool success, ) = to.call{ value: amount }("");
        require(success, "ETH_TRANSFER_FAILED");
        emit EthWithdrawn(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                    EXISTING UNOROUTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Swap ETH for tokens (same as original UnoRouter)
    /// @param buyTokenAddress The address of token that the user should receive
    /// @param target The address of the aggregator contract that will exec the swap
    /// @param swapCallData The calldata that will be passed to the aggregator contract
    /// @param feeAmount The amount of ETH that we will take as a fee
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
        // 1 - Get the initial balances
        uint256 initialTokenBalance = IERC20(buyTokenAddress).balanceOf(address(this));
        uint256 initialEthAmount = address(this).balance - msg.value;
        uint256 sellAmount = msg.value - feeAmount;

        // 2 - Call the encoded swap function call on the contract at `target`
        (bool success, bytes memory res) = target.call{ value: sellAmount }(swapCallData);

        // Get the revert message of the call and revert with it if the call failed
        if (!success) {
            assembly {
                let returndata_size := mload(res)
                revert(add(32, res), returndata_size)
            }
        }

        // 3 - Make sure we received the tokens
        uint256 finalTokenBalance = IERC20(buyTokenAddress).balanceOf(address(this));
        require(initialTokenBalance < finalTokenBalance, NoTokensReceived(buyTokenAddress));

        // 4 - Send the received tokens back to the user
        uint256 tokensToSend = finalTokenBalance - initialTokenBalance;
        IERC20(buyTokenAddress).safeTransfer(msg.sender, tokensToSend);

        // 5 - Return the remaining ETH to the user (if any)
        {
            uint256 finalEthAmount = address(this).balance - feeAmount;
            if (finalEthAmount > initialEthAmount) {
                uint256 ethDiff = finalEthAmount - initialEthAmount;
                (bool ethSuccess, ) = msg.sender.call{ value: ethDiff }("");
                require(ethSuccess, "ETH_TRANSFER_FAILED");
                sellAmount -= ethDiff; // We don't want to include refund amount in the sellAmount when emitting event
            }
        }

        emit FillQuoteEthToToken(buyTokenAddress, target, msg.sender, sellAmount, tokensToSend, feeAmount);
    }

    /// @notice Swap tokens for tokens (same as original UnoRouter)
    /// @param sellTokenAddress The address of token that the user is selling
    /// @param buyTokenAddress The address of token that the user should receive
    /// @param target The address of the aggregator contract that will exec the swap
    /// @param swapCallData The calldata that will be passed to the aggregator contract
    /// @param sellAmount The amount of tokens that the user is selling
    /// @param feeToken The token that we will take as a fee
    /// @param feeAmount The amount of the tokens to sell that we will take as a fee
    /// @param permit Struct containing the nonce, deadline, and signature values of the permit data
    function fillQuoteTokenToToken(
        address sellTokenAddress,
        address buyTokenAddress,
        address payable target,
        bytes calldata swapCallData,
        uint256 sellAmount,
        FeeToken feeToken,
        uint256 feeAmount,
        Permit2 memory permit
    )
        external
        payable
        nonReentrant
        onlyApprovedTarget(target)
    {
        // 1 - Get the initial output token balance
        uint256 initialOutputTokenAmount = IERC20(buyTokenAddress).balanceOf(address(this));

        // 2 - Move the tokens to this contract (which includes our fees)
        permit2.permitTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({ token: sellTokenAddress, amount: sellAmount }),
                nonce: permit.nonce,
                deadline: permit.deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: sellAmount }),
            msg.sender,
            permit.signature
        );

        // 3 - Approve the aggregator's contract to swap the tokens if needed
        uint256 tokensToSwap = feeToken == FeeToken.INPUT ? sellAmount - feeAmount : sellAmount;
        IERC20(sellTokenAddress).forceApprove(target, tokensToSwap);

        // 4 - Call the encoded swap function call on the contract at `target`
        (bool success, bytes memory res) = target.call{ value: msg.value }(swapCallData);

        // Get the revert message of the call and revert with it if the call failed
        if (!success) {
            assembly {
                let returndata_size := mload(res)
                revert(add(32, res), returndata_size)
            }
        }

        // 5 - Check that the tokens were fully spent during the swap
        uint256 allowance = IERC20(sellTokenAddress).allowance(address(this), target);
        require(allowance == 0, AllowanceNotZero(sellTokenAddress, target, allowance));

        // 6 - Make sure we received the tokens
        uint256 finalOutputTokenAmount = IERC20(buyTokenAddress).balanceOf(address(this));
        require(initialOutputTokenAmount < finalOutputTokenAmount, NoTokensReceived(buyTokenAddress));

        // 7 - Send tokens to the user
        uint256 tokensDiff = finalOutputTokenAmount - initialOutputTokenAmount;
        uint256 tokensToSend = feeToken == FeeToken.OUTPUT ? tokensDiff - feeAmount : tokensDiff;
        IERC20(buyTokenAddress).safeTransfer(msg.sender, tokensToSend);

        emit FillQuoteTokenToToken(
            sellTokenAddress, buyTokenAddress, msg.sender, target, tokensToSwap, tokensToSend, feeToken, feeAmount
        );
    }

    /// @notice Swap tokens for ETH (same as original UnoRouter)
    /// @param sellTokenAddress The address of token that the user is selling
    /// @param target The address of the aggregator contract that will exec the swap
    /// @param swapCallData The calldata that will be passed to the aggregator contract
    /// @param sellAmount The amount of tokens that the user is selling
    /// @param feePercentage The amount of ETH that we will take as a fee with 1e18 precision
    /// @param permit Struct containing the nonce, deadline, and signature values of the permit data
    function fillQuoteTokenToEth(
        address sellTokenAddress,
        address payable target,
        bytes calldata swapCallData,
        uint256 sellAmount,
        uint256 feePercentage,
        Permit2 memory permit
    )
        external
        payable
        nonReentrant
        onlyApprovedTarget(target)
    {
        // 1 - Get the initial ETH amount
        uint256 initialEthAmount = address(this).balance - msg.value;

        // 2 - Move the tokens to this contract
        permit2.permitTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({ token: sellTokenAddress, amount: sellAmount }),
                nonce: permit.nonce,
                deadline: permit.deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: sellAmount }),
            msg.sender,
            permit.signature
        );

        // 3 - Approve the aggregator's contract to swap the tokens
        IERC20(sellTokenAddress).forceApprove(target, sellAmount);

        // 4 - Call the encoded swap function call on the contract at `target`
        (bool success, bytes memory res) = target.call{ value: msg.value }(swapCallData);

        // Get the revert message of the call and revert with it if the call failed
        if (!success) {
            assembly {
                let returndata_size := mload(res)
                revert(add(32, res), returndata_size)
            }
        }

        // 5 - Check that the tokens were fully spent during the swap
        uint256 allowance = IERC20(sellTokenAddress).allowance(address(this), target);
        require(allowance == 0, AllowanceNotZero(sellTokenAddress, target, allowance));

        // 6 - Subtract the fees and send the rest to the user
        uint256 finalEthAmount = address(this).balance;
        uint256 ethDiff = finalEthAmount - initialEthAmount;

        require(ethDiff > 0, NoEthBack());

        uint256 fees;
        uint256 ethToSend;
        if (feePercentage > 0) {
            fees = (ethDiff * feePercentage) / 1e18;
            ethToSend = ethDiff - fees;
            (bool ethSuccess, ) = msg.sender.call{ value: ethToSend }("");
            require(ethSuccess, "ETH_TRANSFER_FAILED");
        } else if (ethDiff > 0) {
            ethToSend = ethDiff;
            (bool ethSuccess, ) = msg.sender.call{ value: ethToSend }("");
            require(ethSuccess, "ETH_TRANSFER_FAILED");
        }

        emit FillQuoteTokenToEth(sellTokenAddress, msg.sender, target, sellAmount, ethToSend, fees);
    }

    /*//////////////////////////////////////////////////////////////
                    NEW ATOMIC SWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Swap tokens and send entire output to recipient
    /// @param params Swap parameters (sell/buy tokens, target, calldata, amounts, fee config)
    /// @param recipient Destination for bought tokens
    /// @param permit Permit2 signature data
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
        require(recipient != address(0), ZeroAddress());
        require(params.sellAmount > 0, InvalidAmount());
        require(address(params.sellToken) != address(0), ZeroAddress());
        require(address(params.buyToken) != address(0), ZeroAddress());

        // Execute swap
        (uint256 tokensSwapped, uint256 outputReceived) = _executeSwapWithPermit(params, permit);

        // Calculate and send
        require(params.feeToken != FeeToken.OUTPUT || params.feeAmount <= outputReceived, FeeExceedsOutput());
        uint256 tokensToSend = params.feeToken == FeeToken.OUTPUT ? outputReceived - params.feeAmount : outputReceived;

        params.buyToken.safeTransfer(recipient, tokensToSend);

        // Cache values to reduce stack depth
        address sellTokenAddr = address(params.sellToken);
        address buyTokenAddr = address(params.buyToken);
        FeeToken feeToken = params.feeToken;
        uint256 feeAmount = params.feeAmount;

        emit SwapAndSend(
            sellTokenAddr, buyTokenAddr, msg.sender, recipient, tokensSwapped, tokensToSend, feeToken, feeAmount
        );
    }

    /// @notice Swap tokens and deposit entire output into ERC4626 vault
    /// @param params Swap parameters (sell/buy tokens, target, calldata, amounts, fee config)
    /// @param vault ERC4626 vault address
    /// @param receiver Who receives vault shares
    /// @param permit Permit2 signature data
    /// @return shares Amount of vault shares minted
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
        require(vault != address(0), ZeroAddress());
        require(receiver != address(0), ZeroAddress());
        require(params.sellAmount > 0, InvalidAmount());
        require(address(params.sellToken) != address(0), ZeroAddress());
        require(address(params.buyToken) != address(0), ZeroAddress());

        // Execute swap
        (uint256 tokensSwapped, uint256 outputReceived) = _executeSwapWithPermit(params, permit);

        // Calculate deposit amount
        require(params.feeToken != FeeToken.OUTPUT || params.feeAmount <= outputReceived, FeeExceedsOutput());
        uint256 tokensToDeposit =
            params.feeToken == FeeToken.OUTPUT ? outputReceived - params.feeAmount : outputReceived;

        // Approve and deposit
        params.buyToken.forceApprove(vault, tokensToDeposit);
        shares = IERC4626(vault).deposit(tokensToDeposit, receiver);

        // Cache values to reduce stack depth
        address sellTokenAddr = address(params.sellToken);
        FeeToken feeToken = params.feeToken;
        uint256 feeAmount = params.feeAmount;

        emit SwapAndDeposit(
            sellTokenAddr, vault, msg.sender, receiver, tokensSwapped, tokensToDeposit, shares, feeToken, feeAmount
        );
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute full swap flow: Permit2 pull -> approve -> swap -> validate
    /// @param params Swap parameters
    /// @param permit Permit2 signature data
    /// @return tokensSwapped Amount of sell tokens swapped
    /// @return outputReceived Amount of buy tokens received
    function _executeSwapWithPermit(
        SwapParams calldata params,
        Permit2 calldata permit
    )
        internal
        returns (uint256 tokensSwapped, uint256 outputReceived)
    {
        // Get initial balance
        uint256 initialBalance = params.buyToken.balanceOf(address(this));

        // Pull tokens via Permit2
        _pullTokensViaPermit2(address(params.sellToken), params.sellAmount, permit);

        // Calculate tokens to swap (deduct fee if INPUT)
        tokensSwapped = params.feeToken == FeeToken.INPUT ? params.sellAmount - params.feeAmount : params.sellAmount;

        // Approve target and execute swap
        params.sellToken.forceApprove(params.target, tokensSwapped);
        _executeSwapCall(params.target, params.swapCallData);

        // Verify allowance consumed
        uint256 allowance = params.sellToken.allowance(address(this), params.target);
        require(allowance == 0, AllowanceNotZero(address(params.sellToken), params.target, allowance));

        // Calculate output received
        uint256 finalBalance = params.buyToken.balanceOf(address(this));
        require(initialBalance < finalBalance, NoTokensReceived(address(params.buyToken)));
        outputReceived = finalBalance - initialBalance;
    }

    /// @notice Pull tokens from user via Permit2
    /// @param token The token address
    /// @param amount The amount to pull
    /// @param permit Permit2 signature data
    function _pullTokensViaPermit2(address token, uint256 amount, Permit2 calldata permit) internal {
        permit2.permitTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({ token: token, amount: amount }),
                nonce: permit.nonce,
                deadline: permit.deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: amount }),
            msg.sender,
            permit.signature
        );
    }

    /// @notice Execute swap call to target aggregator
    /// @param target The swap target address
    /// @param swapCallData The swap calldata
    function _executeSwapCall(address target, bytes calldata swapCallData) internal {
        (bool success, bytes memory res) = target.call{ value: msg.value }(swapCallData);
        if (!success) {
            assembly {
                let returndata_size := mload(res)
                revert(add(32, res), returndata_size)
            }
        }
    }
}

