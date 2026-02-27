// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH9 {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IUniswapV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

/// @notice Receives ETH mint-fee flow, swaps to BLOX, and routes BLOX into emissions.
/// BuildNFT should set this contract as `liquidityReceiver`.
contract FeeRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable blox;
    address public immutable weth;

    address public swapRouter;
    address public emissionsReceiver;
    uint24 public poolFee;

    event SwapRouterSet(address indexed router);
    event EmissionsReceiverSet(address indexed receiver);
    event PoolFeeSet(uint24 fee);
    event RoutedToEmissions(
        address indexed caller,
        uint256 ethIn,
        uint256 bloxOut,
        uint24 poolFee,
        address indexed receiver
    );

    error ZeroAddress();
    error ZeroAmount();
    error BadMinOut();
    error InvalidPoolFee();

    constructor(
        address blox_,
        address weth_,
        address swapRouter_,
        address emissionsReceiver_,
        uint24 poolFee_,
        address owner_
    ) Ownable(owner_) {
        if (
            blox_ == address(0) || weth_ == address(0) || swapRouter_ == address(0)
                || emissionsReceiver_ == address(0) || owner_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (poolFee_ == 0) revert InvalidPoolFee();

        blox = blox_;
        weth = weth_;
        swapRouter = swapRouter_;
        emissionsReceiver = emissionsReceiver_;
        poolFee = poolFee_;
    }

    receive() external payable {}

    function setSwapRouter(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        swapRouter = router;
        emit SwapRouterSet(router);
    }

    function setEmissionsReceiver(address receiver) external onlyOwner {
        if (receiver == address(0)) revert ZeroAddress();
        emissionsReceiver = receiver;
        emit EmissionsReceiverSet(receiver);
    }

    function setPoolFee(uint24 fee) external onlyOwner {
        if (fee == 0) revert InvalidPoolFee();
        poolFee = fee;
        emit PoolFeeSet(fee);
    }

    /// @notice Route all ETH held by this contract to emissions via BLOX buy.
    /// @param minBloxOut slippage-protected minimum BLOX out.
    /// @param deadline unix timestamp deadline for router execution.
    function routeAllToEmissions(uint256 minBloxOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 bloxOut)
    {
        uint256 amountIn = address(this).balance;
        if (amountIn == 0) revert ZeroAmount();
        if (minBloxOut == 0) revert BadMinOut();
        return _routeToEmissions(amountIn, minBloxOut, deadline);
    }

    /// @notice Route a specific ETH amount (already held by this contract) into BLOX emissions.
    function routeToEmissions(uint256 amountIn, uint256 minBloxOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 bloxOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > address(this).balance) revert ZeroAmount();
        if (minBloxOut == 0) revert BadMinOut();
        return _routeToEmissions(amountIn, minBloxOut, deadline);
    }

    function _routeToEmissions(uint256 amountIn, uint256 minBloxOut, uint256 deadline)
        internal
        returns (uint256 bloxOut)
    {
        IWETH9(weth).deposit{value: amountIn}();
        IWETH9(weth).approve(swapRouter, 0);
        IWETH9(weth).approve(swapRouter, amountIn);

        IUniswapV3SwapRouter.ExactInputSingleParams memory p = IUniswapV3SwapRouter
            .ExactInputSingleParams({
            tokenIn: weth,
            tokenOut: blox,
            fee: poolFee,
            recipient: emissionsReceiver,
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: minBloxOut,
            sqrtPriceLimitX96: 0
        });

        bloxOut = IUniswapV3SwapRouter(swapRouter).exactInputSingle(p);
        emit RoutedToEmissions(msg.sender, amountIn, bloxOut, poolFee, emissionsReceiver);
    }

    /// @notice Owner rescue for stuck tokens (excluding normal flow outputs).
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    function rescueETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        require(ok, "eth rescue");
    }
}

