// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockUniswapV2Router
 * @notice Minimal mock router that simulates swaps and dispenses the output
 *         token from its own balance using a configurable linear rate.
 *         It supports the two "supporting fee on transfer" swap functions
 *         that our Marketplace uses for buyback-and-burn tests.
 */
contract MockUniswapV2Router {
    // output tokens dispensed per 1 unit of input (18 decimals compatible)
    uint256 public rate; // e.g. 1000 ether => 1000 output tokens per 1 input token/ETH

    event RateUpdated(uint256 newRate);

    constructor(uint256 _rate) {
        rate = _rate;
    }

    receive() external payable {}

    function setRate(uint256 _rate) external {
        rate = _rate;
        emit RateUpdated(_rate);
    }

    // Simulate: swapExactETHForTokensSupportingFeeOnTransferTokens
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint /*deadline*/
    ) external payable {
        require(path.length >= 2, "path");
        address outToken = path[path.length - 1];
        uint256 outAmount = (msg.value * rate) / 1e18; // scale like AMMs with 18 decimals
        require(outAmount >= amountOutMin, "slippage");
        IERC20(outToken).transfer(to, outAmount);
        // received ETH is kept in this mock
    }

    // Simulate: swapExactTokensForTokensSupportingFeeOnTransferTokens
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint /*deadline*/
    ) external {
        require(path.length >= 2, "path");
        address inToken = path[0];
        address outToken = path[path.length - 1];
        // pull input tokens from caller (Marketplace has approved this router)
        IERC20(inToken).transferFrom(msg.sender, address(this), amountIn);
        uint256 outAmount = (amountIn * rate) / 1e18;
        require(outAmount >= amountOutMin, "slippage");
        IERC20(outToken).transfer(to, outAmount);
    }
}
