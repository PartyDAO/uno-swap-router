// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";

/// @dev Lightweight mock that ignores signatures and simply transfers tokens that have been approved to this contract.
contract MockPermit2 is ISignatureTransfer {
    bytes32 public constant DOMAIN_SEPARATOR = keccak256("MOCK_PERMIT2");

    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata /* signature */
    )
        external
        override
    {
        if (transferDetails.requestedAmount > permit.permitted.amount) {
            revert InvalidAmount(permit.permitted.amount);
        }
        SafeTransferLib.safeTransferFrom(
            ERC20(permit.permitted.token), owner, transferDetails.to, transferDetails.requestedAmount
        );
    }

    function permitTransferFrom(
        PermitBatchTransferFrom memory,
        SignatureTransferDetails[] calldata,
        address,
        bytes calldata
    )
        external
        pure
        override
    {
        revert("not implemented");
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom memory,
        SignatureTransferDetails calldata,
        address,
        bytes32,
        string calldata,
        bytes calldata
    )
        external
        pure
        override
    {
        revert("not implemented");
    }

    function permitWitnessTransferFrom(
        PermitBatchTransferFrom memory,
        SignatureTransferDetails[] calldata,
        address,
        bytes32,
        string calldata,
        bytes calldata
    )
        external
        pure
        override
    {
        revert("not implemented");
    }

    function invalidateUnorderedNonces(uint256, uint256) external pure override { }

    function nonceBitmap(address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

