// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/Main.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MainTest is Test {
    // ethereum mainnet
    address constant POSITION_MANAGER =
        0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH_USDC_POOL =
        0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;

    Main main;
    address constant SWAP_DEALER = address(0x2);
    address constant user = address(0x1);

    function setUp() public {
        vm.createSelectFork("https://eth.blockrazor.xyz");

        main = new Main(POSITION_MANAGER);

        deal(WETH, user, 10 ether);
        deal(USDC, user, 10000 * 10 ** 6);
        deal(user, 1 ether);
        deal(WETH, SWAP_DEALER, 1000 ether);
        deal(USDC, SWAP_DEALER, 10_000_000 * 10 ** 6);

        vm.startPrank(user);
        IERC20(USDC).approve(address(main), 100000 * 10 ** 6);
        IERC20(WETH).approve(address(main), 100 ether);
        IERC721(POSITION_MANAGER).setApprovalForAll(address(main), true);
        vm.stopPrank();
    }

    function testProvideLiquidity() public {
        vm.startPrank(user);

        uint256 initialUSDCBalance = IERC20(USDC).balanceOf(user);
        uint256 initialWETHBalance = IERC20(WETH).balanceOf(user);

        uint256 usdcAmount = 2000 * 10 ** 6;
        uint256 wethAmount = 1 ether;

        uint24 width = 500;

        (uint256 tokenId, , ) = main.provideLiquidity(
            WETH_USDC_POOL,
            usdcAmount,
            wethAmount,
            width,
            60
        );

        assertGt(tokenId, 0, "Must get position ID");
        assertLt(IERC20(WETH).balanceOf(user), initialWETHBalance);
        assertLt(IERC20(USDC).balanceOf(user), initialUSDCBalance);

        vm.stopPrank();
    }

    function testWidthTooLarge() public {
        vm.startPrank(user);

        uint24 width = 10000;

        vm.expectRevert(
            abi.encodeWithSelector(Main.WidthTooLarge.selector, width)
        );

        main.provideLiquidity(
            WETH_USDC_POOL,
            1000 * 10 ** 6,
            1 ether,
            width,
            50
        );

        vm.stopPrank();
    }

    function testCalculateLiquidity() public view {
        IUniswapV3Pool pool = IUniswapV3Pool(WETH_USDC_POOL);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        int24 tickSpacing = pool.tickSpacing();
        int24 lowerTick = -tickSpacing;
        int24 upperTick = tickSpacing;

        uint128 liquidity = main.calculateLiquidity(
            1000 * 10 ** 6,
            1 ether,
            sqrtPriceX96,
            lowerTick,
            upperTick
        );

        assertGt(liquidity, 0, "Liquidity must be greater than 0");
    }

    function testCollectFees() public {
        deal(WETH, address(this), 100 ether);
        deal(USDC, address(this), 100000 * 10 ** 6);

        IERC20(WETH).approve(WETH_USDC_POOL, type(uint256).max);
        IERC20(USDC).approve(WETH_USDC_POOL, type(uint256).max);

        vm.startPrank(user);

        (uint256 tokenId, , ) = main.provideLiquidity(
            WETH_USDC_POOL,
            2000 * 10 ** 6,
            1 ether,
            500,
            60
        );

        vm.stopPrank();

        _simulateSwaps();

        vm.startPrank(user);

        uint256 initialUSDC = IERC20(USDC).balanceOf(user);
        uint256 initialWETH = IERC20(WETH).balanceOf(user);

        main.collectFees(tokenId);

        assertGt(
            IERC20(USDC).balanceOf(user),
            initialUSDC,
            "USDC fees not collected"
        );
        assertGt(
            IERC20(WETH).balanceOf(user),
            initialWETH,
            "WETH fees not collected"
        );

        vm.stopPrank();
    }

    function testIncreaseLiquidity() public {
        vm.startPrank(user);

        (uint256 tokenId, , ) = main.provideLiquidity(
            WETH_USDC_POOL,
            2000 * 10 ** 6,
            1 ether,
            500,
            60
        );

        uint256 initialLiquidity = _getPositionLiquidity(tokenId);

        (uint256 addedLiquidity, , ) = main.increaseLiquidity(
            tokenId,
            1000 * 10 ** 6,
            0.5 ether,
            60
        );

        assertGt(addedLiquidity, 0, "Liquidity not increased");
        assertGt(
            _getPositionLiquidity(tokenId),
            initialLiquidity,
            "Total liquidity mismatch"
        );

        vm.stopPrank();
    }

    function testWithdrawFullLiquidity() public {
        vm.startPrank(user);

        (uint256 tokenId, , ) = main.provideLiquidity(
            WETH_USDC_POOL,
            2000 * 10 ** 6,
            1 ether,
            500,
            60
        );

        uint256 balanceBeforeUSDC = IERC20(USDC).balanceOf(user);
        uint256 balanceBeforeWETH = IERC20(WETH).balanceOf(user);

        (uint256 amount0, uint256 amount1) = main.withdrawLiquidity(tokenId);

        assertGt(amount0 + amount1, 0, "No funds withdrawn");
        assertApproxEqAbs(
            IERC20(USDC).balanceOf(user),
            balanceBeforeUSDC + amount0,
            1000,
            "USDC balance mismatch"
        );
        assertApproxEqAbs(
            IERC20(WETH).balanceOf(user),
            balanceBeforeWETH + amount1,
            0.01 ether,
            "WETH balance mismatch"
        );

        vm.stopPrank();
    }

    function testAmountTooSmall() public {
        vm.startPrank(user);

        vm.expectRevert(
            abi.encodeWithSelector(Main.AmountTooSmall.selector, 0)
        );
        main.provideLiquidity(WETH_USDC_POOL, 0, 1000 * 10 ** 6, 500, 60);

        vm.expectRevert(
            abi.encodeWithSelector(Main.AmountTooSmall.selector, 0)
        );
        main.provideLiquidity(WETH_USDC_POOL, 1 ether, 0, 500, 60);

        vm.stopPrank();
    }

    function testTokenReturn() public {
        vm.startPrank(user);

        uint256 initialUsdcBalance = IERC20(USDC).balanceOf(user);
        uint256 initialWethBalance = IERC20(WETH).balanceOf(user);

        (, uint256 usdcUsed, uint256 wethUsed) = main.provideLiquidity(
            WETH_USDC_POOL,
            4000 * 10 ** 6,
            2 ether,
            500,
            60
        );

        uint256 finalUsdcBalance = IERC20(USDC).balanceOf(user);
        uint256 finalWethBalance = IERC20(WETH).balanceOf(user);
        assertEq(
            initialUsdcBalance - usdcUsed,
            finalUsdcBalance,
            "USDC not returned correctly"
        );
        assertEq(
            initialWethBalance - wethUsed,
            finalWethBalance,
            "WETH not returned correctly"
        );

        vm.stopPrank();
    }

    function testNotOwner() public {
        address attacker = address(0x666);

        vm.startPrank(user);
        (uint256 tokenId, , ) = main.provideLiquidity(
            WETH_USDC_POOL,
            2000 * 10 ** 6,
            1 ether,
            500,
            60
        );
        vm.stopPrank();

        vm.startPrank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Main.NotTheOwner.selector, attacker, user)
        );
        main.withdrawLiquidity(tokenId);
        vm.stopPrank();
    }

    function _getPositionLiquidity(
        uint256 tokenId
    ) internal view returns (uint128) {
        (, , , , , , , uint128 liquidity, , , , ) = INonfungiblePositionManager(
            POSITION_MANAGER
        ).positions(tokenId);
        return liquidity;
    }

    function _simulateSwaps() internal {
        IUniswapV3Pool pool = IUniswapV3Pool(WETH_USDC_POOL);

        _swap(pool, WETH, USDC, 1 ether);

        _swap(pool, USDC, WETH, 500 * 10 ** 6);
    }

    function _swap(
        IUniswapV3Pool pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal {
        bool zeroForOne = tokenIn < tokenOut;
        int256 amountSpecified = int256(amountIn);

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? sqrtPriceX96 - (sqrtPriceX96 / 100)
            : sqrtPriceX96 + (sqrtPriceX96 / 100);

        pool.swap(
            address(this),
            zeroForOne,
            amountSpecified,
            sqrtPriceLimitX96,
            abi.encode(tokenIn, tokenOut)
        );
    }
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        require(msg.sender == WETH_USDC_POOL, "Invalid pool");

        abi.decode(data, (address, address));

        if (amount0Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token0()).transfer(
                msg.sender,
                uint256(amount0Delta)
            );
        }

        if (amount1Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token1()).transfer(
                msg.sender,
                uint256(amount1Delta)
            );
        }
    }
}
