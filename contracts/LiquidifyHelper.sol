// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./libs/Ownable.sol";
import "./libs/SafeMath.sol";
import "./libs/IERC20.sol";
import "./libs/IUniswapAmm.sol";

contract LiquidifyHelper is Ownable {
    using SafeMath for uint256;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public _token0;
    address public _token1;

    IUniswapV2Router02 public _swapRouter;

    constructor() {
        _swapRouter = IUniswapV2Router02(
            address(0x10ED43C718714eb63d5aA57B78B54704E256024E)
        );
    }

    function setSwapRouter(address newSwapRouter) external onlyOwner {
        require(newSwapRouter != address(0), "Invalid swap router");
        _swapRouter = IUniswapV2Router02(newSwapRouter);
    }

    function setTokenPair(address token0, address token1) external onlyOwner {
        IERC20(token0).balanceOf(address(this));
        IERC20(token1).balanceOf(address(this));
        _token0 = token0;
        _token1 = token1;
    }

    //to recieve ETH from swapRouter when swaping
    receive() external payable {}

    function liquifyAndBurn() external onlyOwner {
        uint256 token0Amount = IERC20(_token0).balanceOf(address(this));
        uint256 token1Amount = IERC20(_token1).balanceOf(address(this));
        if (token0Amount > 0 && token1Amount > 0) {
            addLiquidityAndBurn(token0Amount, token1Amount);
        }
    }

    function addLiquidityAndBurn(uint256 token0Amount, uint256 token1Amount)
        internal
    {
        require(_token0 != address(0), "Invalid token 0");
        require(_token1 != address(0), "Invalid token 1");

        // approve token transfer to cover all possible scenarios
        IERC20(_token0).approve(address(_swapRouter), token0Amount);
        IERC20(_token1).approve(address(_swapRouter), token1Amount);

        // add the liquidity
        _swapRouter.addLiquidity(
            _token0,
            _token1,
            token0Amount,
            token1Amount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            DEAD,
            block.timestamp.add(300)
        );
    }

    function recoverToken(address tokenAddress, uint256 tokenAmount)
        external
        onlyOwner
    {
        // do not allow recovering self token
        require(tokenAddress != address(this), "Self withdraw");
        IERC20(tokenAddress).transfer(owner(), tokenAmount);
    }
}
