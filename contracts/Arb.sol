pragma solidity 0.5.9;

import "./SelfDestructible.sol";
import "./Pausable.sol";
import "./SafeDecimalMath.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IExchangeRates.sol";
import './interfaces/IUniswapV2Router01.sol';

contract ArbRewarder is SelfDestructible, Pausable {

    using SafeMath for uint;
    using SafeDecimalMath for uint;

    /* How far off the peg the pool must be to allow its ratio to be pushed up or down
     * by this contract, thus granting the caller arbitrage rewards.
     * Parts-per-hundred-thousand: 100 = 1% */
    uint off_peg_min = 100;

    /* Additional slippage we'll allow on top of the uniswap trade
     * Parts-per-hundred-thousand: 100 = 1%
     * Example: 95 sTRX, 100 TRX, buy 1 sTRX -> expected: 1.03857 TRX
     * After acceptable_slippage:  1.02818 TRX */
    uint acceptable_slippage = 100;

    /* How long we'll let a uniswap transaction sit before it becomes invalid
     * In seconds. Prevents miners holding our transaction and using it later. */
    uint max_delay = 600;

    /* Divisor for off_peg_min and acceptable_slippage */
    uint constant divisor = 10000;

    /* Contract Addresses */
    address public UNISWAP_ROUTER = 0x2c870Cf7333C55E131fFfb75e402dA3E0B903465 ;
    address public OIKOS_PROXY = 0xb20d4f75Ba52E8574daD86FA2b8F8958392bc994;
    address public UNISWAP_sTRX_PAIR = 0x6C872684e348EC3a5418Fb1E952556110550c924;
    address public sTRX_TOKEN_PROXY = 0xA099cc498284ed6e25F3C99e6d55074e6ba42911;
    address public WTRX_TOKEN = 0x891cdb91d149f23B1a45D9c5Ca78a88d0cB44C18;
    address public sTRX_TOKEN = 0x15DDbaD15288f96F5Cf0B068b0e187ecCBc0Aa0B;
    address public EXCHANGE_RATES = 0x609938ef4EaEd907d8A76fa867cd7e25Adb03669;

    /* Constants */
    uint public WTRX_DECIMALS = 6;
    uint public sTRX_DECIMALS = 18;

    IERC20 public synth = IERC20(sTRX_TOKEN);
    IERC20 public oikos = IERC20(OIKOS_PROXY);
    IERC20 public wtrx = IERC20(WTRX_TOKEN);

    IExchangeRates public exchangeRates = IExchangeRates(EXCHANGE_RATES);
    IUniswapV2Router02 public uniswapRouter = IUniswapV2Router02(UNISWAP_ROUTER);

    constructor(address _owner)
        // Owned is initialised in SelfDestructible 
        SelfDestructible(_owner)
        Pausable(_owner)
        public
    {}

    /* ========== SETTERS ========== */
    function setParams(uint _acceptable_slippage, uint _max_delay, uint _off_peg_min) external onlyOwner {
        require(_off_peg_min < divisor, "_off_peg_min less than divisor");
        require(_acceptable_slippage < divisor, "_acceptable_slippage less than divisor");
        acceptable_slippage = _acceptable_slippage;
        max_delay = _max_delay;
        off_peg_min = _off_peg_min;
    }

    function setSynthetix(address _address) external onlyOwner {
        OIKOS_PROXY = _address;
        oikos = IERC20(OIKOS_PROXY);
    }

    function setSynthAddress(address _synthAddress) external onlyOwner {
        synth = IERC20(_synthAddress);
        synth.approve(UNISWAP_ROUTER, uint(-1));
    }

    function setUniswapExchange(address _uniswapAddress) external onlyOwner {
        UNISWAP_ROUTER = _uniswapAddress;
        uniswapRouter = IUniswapV2Router02(_uniswapAddress);
        synth.approve(UNISWAP_ROUTER, uint(-1));
    }

    function setExchangeRates(address _exchangeRatesAddress) external onlyOwner {
        exchangeRates = IExchangeRates(_exchangeRatesAddress);
    }

    /* ========== OWNER ONLY ========== */

    function recoverTRX(address payable to_addr) external onlyOwner {
        to_addr.transfer(address(this).balance);
    }

    function recoverERC20(address trc20_addr, address to_addr) external onlyOwner {
        IERC20 trc20_interface = IERC20(trc20_addr);
        trc20_interface.transfer(to_addr, trc20_interface.balanceOf(address(this)));
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    /**
     * Here the caller gives us some TRX. We convert the TRX->sTRX  and reward the caller with OKS worth
     * the value of the sTRX received from the earlier swap.
     */
    function arbSynthRate() public payable
        rateNotStale("sTRX")
        rateNotStale("OKS")
        notPaused
        returns (uint)
    {
        /* Ensure there is enough more sTRX than TRX in the Uniswap pool */
        uint strx_in_uniswap = uniswapSynthBalance();
        uint trx_in_uniswap = uniswapTRXBalance() * 10**(sTRX_DECIMALS-WTRX_DECIMALS);
        require(trx_in_uniswap.divideDecimal(strx_in_uniswap) < uint(divisor-off_peg_min).divideDecimal(divisor), "sTRX/TRX ratio is too high");

        // Get maximum TRX we'll convert for caller 
        uint max_trx_to_convert = maxConvert(trx_in_uniswap, strx_in_uniswap, divisor, divisor-off_peg_min);
        uint trx_to_convert = min(msg.value, max_trx_to_convert);
        uint unspent_input = msg.value - trx_to_convert;

        // Actually swap TRX for sTRX 
        uint min_strx_bought = expectedOutput(trx_to_convert)[1];
        uint tokens_bought =  uniswapRouter.swapExactTRXForTokens.value(trx_to_convert)(min_strx_bought, getPathForTRXtoToken(), address(this), now+600)[1];

        //discount factor
        uint discount_factor = strx_in_uniswap / trx_in_uniswap;

    	// Reward caller 
        uint reward_tokens = rewardCaller(tokens_bought, unspent_input, trx_to_convert, discount_factor);
        return reward_tokens;
    }

    function uniswapTRXBalance() public view returns (uint){
        return wtrx.balanceOf(UNISWAP_sTRX_PAIR);
    }

   function uniswapSynthBalance() public view returns (uint){
        return synth.balanceOf(UNISWAP_sTRX_PAIR);
    }
    
    function isArbable()
        public
        returns (bool)
    {
        uint strx_in_uniswap = uniswapSynthBalance();
        uint trx_in_uniswap = uniswapTRXBalance() * 10**(sTRX_DECIMALS-WTRX_DECIMALS);
        return trx_in_uniswap.divideDecimal(strx_in_uniswap) < uint(divisor-off_peg_min).divideDecimal(divisor);
    }

    function expectedOutput(uint input) public view returns (uint[] memory) {
        return uniswapRouter.getAmountsOut(input, getPathForTRXtoToken());
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function rewardCaller(uint bought, uint unspent_input, uint trx_to_convert, uint discount_factor)
        private
        returns
        (uint reward_tokens)
    {
        uint oks_rate = exchangeRates.rateForCurrency("OKS");
        //this is the TRX/USD rate
        uint trx_rate = exchangeRates.rateForCurrency("sTRX");

        reward_tokens = ((trx_to_convert * 10**(sTRX_DECIMALS-WTRX_DECIMALS)) * trx_rate) / oks_rate;
        uint reward_bonus = reward_tokens / discount_factor;
        reward_tokens = reward_tokens + reward_bonus;
        oikos.transfer(msg.sender, reward_tokens);

        if(unspent_input > 0) {
            msg.sender.transfer(unspent_input);
        }
    }

    function applySlippage(uint input) private view returns (uint output) {
        output = input - (input * (acceptable_slippage / divisor));
    }

    function getPathForTRXtoToken() private view returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = uniswapRouter.WTRX();
        path[1] = sTRX_TOKEN_PROXY;
        
        return path;
    }

    /**
     * maxConvert determines how many tokens need to be swapped to bring a market to a n:d ratio
     * This can be derived by solving a system of equations.
     *
     * First, we know that once we're done balanceA and balanceB should be related by our ratio:
     *
     * n * (A + input) = d * (B - output)
     *
     * From Uniswap's code, we also know how input and output are related:
     *
     * output = (997*input*B) / (1000*A + 997*input)
     *
     * So:
     *
     * n * (A + input) = d * (B - ((997*input*B) / (1000*A + 997*input)))
     *
     * Solving for input (given n>d>0 and B>A>0):
     *
     * input = (sqrt((A * (9*A*n + 3988000*B*d)) / n) - 1997*A) / 1994
     */
    function maxConvert(uint a, uint b, uint n, uint d) private pure returns (uint result) {
        result = (sqrt((a * (9*a*n + 3988000*b*d)) / n) - 1997*a) / 1994;
    }

    function sqrt(uint x) private pure returns (uint y) {
        uint z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function min(uint a, uint b) private pure returns (uint result) {
        result = a > b ? b : a;
    }

    /* ========== MODIFIERS ========== */

    modifier rateNotStale(bytes32 currencyKey) {
        require(!exchangeRates.rateIsStale(currencyKey), "Rate stale or not a synth");
        _;
    }

}

contract IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityTRXSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountTRXMin,
        address to,
        uint deadline
    ) external returns (uint amountTRX);
    function removeLiquidityTRXWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountTRXMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountTRX);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactTRXForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForTRXSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
} 