// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";

struct Permit2 {
    uint256 nonce;
    uint256 deadline;
    bytes signature;
}

/**
 * @title Permit2HelperUpgradeable
 * @notice Upgradeable helper contract for managing Permit2 signature transfers
 */
contract Permit2HelperUpgradeable is Initializable {
    /// @notice The Permit2 contract instance for signature transfers
    ISignatureTransfer public permit2;

    /**
     * @notice Initializes the Permit2HelperUpgradeable with a Permit2 contract instance
     * @param _permit2 The Permit2 contract address to use for signature transfers
     */
    function __Permit2HelperUpgradeable_init(ISignatureTransfer _permit2) internal onlyInitializing {
        permit2 = _permit2;
    }
}

