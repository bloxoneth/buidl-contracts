// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {FeeRouter, IUniswapV3SwapRouter} from "src/FeeRouter.sol";

contract MintableERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWETH is MintableERC20 {
    constructor() MintableERC20("Wrapped ETH", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract MockSwapRouter is IUniswapV3SwapRouter {
    MintableERC20 public immutable blox;
    MockWETH public immutable weth;
    uint256 public rate; // BLOX out per 1 WETH in (18 decimals)

    constructor(address blox_, address weth_, uint256 rate_) {
        blox = MintableERC20(blox_);
        weth = MockWETH(weth_);
        rate = rate_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        require(params.tokenIn == address(weth), "tokenIn");
        require(params.tokenOut == address(blox), "tokenOut");
        require(params.amountIn > 0, "amountIn");

        bool ok = weth.transferFrom(msg.sender, address(this), params.amountIn);
        require(ok, "weth in");

        amountOut = (params.amountIn * rate) / 1e18;
        require(amountOut >= params.amountOutMinimum, "minOut");
        blox.mint(params.recipient, amountOut);
    }
}

contract FeeRouterTest is Test {
    MintableERC20 private blox;
    MockWETH private weth;
    MockSwapRouter private router;
    FeeRouter private feeRouter;

    address private owner = address(0xABCD);
    address private emissions = address(0xE111);

    function setUp() public {
        blox = new MintableERC20("BLOX", "BLOX");
        weth = new MockWETH();
        router = new MockSwapRouter(address(blox), address(weth), 2e18); // 1 ETH => 2 BLOX
        feeRouter = new FeeRouter(
            address(blox), address(weth), address(router), emissions, 3000, owner
        );
    }

    function testRouteAllToEmissions() public {
        vm.deal(address(this), 3 ether);
        (bool sent,) = address(feeRouter).call{value: 3 ether}("");
        require(sent, "send eth");

        uint256 beforeBlox = blox.balanceOf(emissions);
        uint256 out = feeRouter.routeAllToEmissions(5e18, block.timestamp + 1 hours);

        assertEq(out, 6e18);
        assertEq(blox.balanceOf(emissions) - beforeBlox, 6e18);
        assertEq(address(feeRouter).balance, 0);
    }

    function testRouteSpecificAmountLeavesRemainder() public {
        vm.deal(address(this), 3 ether);
        (bool sent,) = address(feeRouter).call{value: 3 ether}("");
        require(sent, "send eth");

        feeRouter.routeToEmissions(1 ether, 2e18, block.timestamp + 1 hours);
        assertEq(blox.balanceOf(emissions), 2e18);
        assertEq(address(feeRouter).balance, 2 ether);
    }

    function testOnlyOwnerSetters() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        feeRouter.setEmissionsReceiver(address(0x1234));

        vm.prank(owner);
        feeRouter.setEmissionsReceiver(address(0x1234));
        assertEq(feeRouter.emissionsReceiver(), address(0x1234));
    }

    function testRouteRevertsOnZeroMinOut() public {
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(feeRouter).call{value: 1 ether}("");
        require(sent, "send eth");

        vm.expectRevert(FeeRouter.BadMinOut.selector);
        feeRouter.routeAllToEmissions(0, block.timestamp + 1 hours);
    }
}

