// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function withdraw(uint256) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address,uint256) external returns (bool);
    function approve(address,uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

contract AutoBurnBuyer {
    address public owner;
    address public immutable token;
    address public immutable nativeWrapper;
    IUniswapV2Pair public pair;
    IUniswapV2Router02 public router;

    uint16 public pairFeeBps; // e.g. 9970 for 0.3%
    uint16 public slippageBps = 1500;
    bool public autoEnabled = true;
    bool public useRouter = false;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event BurnBuy(uint256 amountInWei, uint256 amountOut);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    constructor(
        address _pair,
        address _token,
        address _nativeWrapper,
        uint16 _pairFeeBps,
        bool _autoEnabled
    ) {
        require(_pair != address(0) && _token != address(0) && _nativeWrapper != address(0), "zero");
        require(_pairFeeBps <= 10000 && _pairFeeBps >= 9000, "fee range");

        address t0 = IUniswapV2Pair(_pair).token0();
        address t1 = IUniswapV2Pair(_pair).token1();
        require(
            (t0 == _nativeWrapper && t1 == _token) ||
            (t1 == _nativeWrapper && t0 == _token),
            "pair mismatch"
        );

        owner = msg.sender;
        pair = IUniswapV2Pair(_pair);
        token = _token;
        nativeWrapper = _nativeWrapper;
        pairFeeBps = _pairFeeBps;
        autoEnabled = _autoEnabled;

        emit OwnershipTransferred(address(0), owner);
    }

    receive() external payable {
        if (autoEnabled && msg.value > 0) {
            _buyAndBurn(msg.value, _computeMinOut(msg.value));
        }
    }

    function burnBuy() external payable {
        require(msg.value > 0, "no value");
        _buyAndBurn(msg.value, _computeMinOut(msg.value));
    }

    // ---------------- CORE ----------------

    function _computeMinOut(uint256 amountInWei) internal view returns (uint256) {
        address t0 = pair.token0();
        bool wethIs0 = (t0 == nativeWrapper);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            wethIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        // ✅ Correct Uniswap v2 math (no divide on fee)
        uint256 amountInWithFee = amountInWei * pairFeeBps;
        uint256 amountOut = (amountInWithFee * reserveOut) / (reserveIn * 10000 + amountInWithFee);
        return (amountOut * (10000 - slippageBps)) / 10000;
    }

    function _buyAndBurn(uint256 amountInWei, uint256 minOutAbsolute) internal {
        IWETH(nativeWrapper).deposit{value: amountInWei}();

        // ---- ROUTER MODE ----
        if (useRouter) {
            IERC20(nativeWrapper).approve(address(router), amountInWei);
            uint256 balBefore = IERC20(token).balanceOf(address(this));

            address[] memory path = new address[](2);
            path[0] = nativeWrapper;
            path[1] = token;

            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountInWei,
                minOutAbsolute,
                path,
                address(this),
                block.timestamp
            );

            uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
            IERC20(token).transfer(DEAD, received);
            emit BurnBuy(amountInWei, received);
            return;
        }

        // ---- PAIR MODE ----
        address t0 = pair.token0();
        bool wethIs0 = (t0 == nativeWrapper);

        IERC20(nativeWrapper).transfer(address(pair), amountInWei);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            wethIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        uint256 amountInWithFee = amountInWei * pairFeeBps;
        uint256 amountOut = (amountInWithFee * reserveOut) / (reserveIn * 10000 + amountInWithFee);

        uint amount0Out = wethIs0 ? 0 : amountOut;
        uint amount1Out = wethIs0 ? amountOut : 0;

        uint256 balBefore2 = IERC20(token).balanceOf(address(this));
        pair.swap(amount0Out, amount1Out, address(this), new bytes(0));
        uint256 received2 = IERC20(token).balanceOf(address(this)) - balBefore2;

        require(received2 >= minOutAbsolute, "slippage too high");
        IERC20(token).transfer(DEAD, received2);
        emit BurnBuy(amountInWei, received2);
    }

    // ---------------- ADMIN ----------------

    function setRouter(address _router, bool enable) external onlyOwner {
        router = IUniswapV2Router02(_router);
        useRouter = enable;
    }

    function setSlippage(uint16 bps) external onlyOwner {
        require(bps <= 5000, "too high");
        slippageBps = bps;
    }

    function rescueNative(address to, uint256 amountWei) external onlyOwner {
        (bool ok,) = payable(to).call{value: amountWei}("");
        require(ok, "send fail");
    }

    function rescueERC20(address _token, address to, uint256 amount) external onlyOwner {
        IERC20(_token).transfer(to, amount);
    }
}
