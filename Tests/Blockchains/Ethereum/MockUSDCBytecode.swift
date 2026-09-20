// The compiled creation bytecode for EthereumAnvilTests.swift's mock USDC,
// deployed fresh on each test's own local Anvil chain — never a real
// mainnet contract (see EthereumAnvilTests.swift's header comment for why).

import Foundation
@testable import WalletKit

/// Solidity source this bytecode was compiled from (`forge build` from a
/// throwaway scratch Foundry project — `mise x foundry -- forge build
/// --optimize --optimizer-runs 200`, Solc 0.8.35 — via `mise x foundry --
/// forge`; recompile and update the constant below if this ever needs to
/// change):
///
/// ```solidity
/// // SPDX-License-Identifier: MIT
/// pragma solidity ^0.8.24;
///
/// /// Minimal ERC-20 for WalletKit's local-Anvil integration tests only.
/// /// Hardcoded name/symbol (no constructor args — sidesteps EthereumABI's
/// /// lack of dynamic-type encoding for deployment). Mint is deliberately
/// /// unrestricted: only a throwaway local chain ever runs this.
/// contract MockUSDC {
///     string public constant name = "Mock USDC";
///     string public constant symbol = "USDC";
///     uint8 public constant decimals = 6;
///
///     mapping(address => uint256) public balanceOf;
///
///     event Transfer(address indexed from, address indexed to, uint256 value);
///
///     function mint(address to, uint256 amount) external {
///         balanceOf[to] += amount;
///         emit Transfer(address(0), to, amount);
///     }
///
///     function transfer(address to, uint256 amount) external returns (bool) {
///         require(balanceOf[msg.sender] >= amount, "insufficient balance");
///         balanceOf[msg.sender] -= amount;
///         balanceOf[to] += amount;
///         emit Transfer(msg.sender, to, amount);
///         return true;
///     }
/// }
/// ```
///
/// `balanceOf` as a public mapping auto-generates the standard
/// `balanceOf(address) view returns (uint256)` getter, so
/// `EthereumRPCClient.erc20Balance(token:owner:)` already reads this
/// contract's balances with no changes needed.

let mockUSDCCreationBytecode = try! Data( // swiftlint:disable:this force_try
    // swiftlint:disable:next line_length
    hexString: "0x6080604052348015600e575f5ffd5b506103ae8061001c5f395ff3fe608060405234801561000f575f5ffd5b5060043610610060575f3560e01c806306fdde0314610064578063313ce567146100a257806340c10f19146100bc57806370a08231146100d157806395d89b41146100fe578063a9059cbb14610121575b5f5ffd5b61008c604051806040016040528060098152602001684d6f636b205553444360b81b81525081565b60405161009991906102a6565b60405180910390f35b6100aa600681565b60405160ff9091168152602001610099565b6100cf6100ca3660046102f6565b610144565b005b6100f06100df36600461031e565b5f6020819052908152604090205481565b604051908152602001610099565b61008c604051806040016040528060048152602001635553444360e01b81525081565b61013461012f3660046102f6565b6101b4565b6040519015158152602001610099565b6001600160a01b0382165f908152602081905260408120805483929061016b908490610352565b90915550506040518181526001600160a01b038316905f907fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef9060200160405180910390a35050565b335f9081526020819052604081205482111561020d5760405162461bcd60e51b8152602060048201526014602482015273696e73756666696369656e742062616c616e636560601b604482015260640160405180910390fd5b335f908152602081905260408120805484929061022b908490610365565b90915550506001600160a01b0383165f9081526020819052604081208054849290610257908490610352565b90915550506040518281526001600160a01b0384169033907fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef9060200160405180910390a35060015b92915050565b602081525f82518060208401528060208501604085015e5f604082850101526040601f19601f83011684010191505092915050565b80356001600160a01b03811681146102f1575f5ffd5b919050565b5f5f60408385031215610307575f5ffd5b610310836102db565b946020939093013593505050565b5f6020828403121561032e575f5ffd5b610337826102db565b9392505050565b634e487b7160e01b5f52601160045260245ffd5b808201808211156102a0576102a061033e565b818103818111156102a0576102a061033e56fea26469706673582212200b59cd1cd101f07cbeba3ebf884340311a05cb5e06312b51ea59aabc144d458064736f6c63430008230033"
)
