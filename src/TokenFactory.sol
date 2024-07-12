import {Token} from "./Token.sol";
import {IUniswapV2Factory} from "https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol";

pragma solidity ^0.8.13;

interface IUniswapV2Router02 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

contract TokenFactory {
    enum TokenState {
        NOT_CREATED,
        FUNDING,
        TRADING
    }

    uint256 public constant CREATION_FEE = 2 ether;
    uint256 public constant TRANSACTION_FEE_PERCENTAGE = 2;
    
    uint256 decimals=10**18;
    uint256 public MaxSupply=1000000000*decimals; //1billion
    uint256 constant public fundingGoal= 30 ether;
    uint256 public initialMint= MaxSupply*20/100;
    uint constant public k = 46875; //co-efficient
    uint constant public offset = 18750000000000000000000000000000; //offset
    uint constant public SCALING_FACTOR = 10 ** 39; //scaling factor for non decimal values
    mapping(address => TokenState) public tokens;
    mapping(address => address) public tokensCreators;

    mapping(address => uint256) public collateral;
    mapping(address => mapping(address => uint256)) public balances;

    mapping(address => mapping(address => uint256)) public tokensBought;
    mapping(address => mapping(address => uint256)) public tokensSold;
    mapping(address => uint256) public totalBought;
    mapping(address => uint256) public totalSold;


    address public constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address public constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    event TokenCreated(address indexed tokenAddress, string name, string symbol);
    event TokensPurchased(address indexed tokenAddress, address indexed buyer, uint256 ethAmount, uint256 tokenAmount);
    event TokensSold(address indexed tokenAddress, address indexed seller, uint256 tokenAmount, uint256 ethAmount);
    event LiquidityAdded(address indexed tokenAddress, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity);
    event LiquidityBurned(address indexed pair, uint256 liquidity);
    event VolumeTracked(address indexed user, uint256 bought, uint256 sold);

    function createToken(
        string memory name,
        string memory symbol
    ) public payable returns (address) {
        require(msg.value >= CREATION_FEE, "Creation fee of 2 ETH required");

        Token token = new Token(name, symbol, initialMint);
        tokens[address(token)] = TokenState.FUNDING;
        tokensCreators[address(token)] = msg.sender;

        if (msg.value-CREATION_FEE>0){
        this.buy{value: msg.value - CREATION_FEE}(address(token), 0);
        }
        emit TokenCreated(address(token), name, symbol);
        return address(token);
    }

    function buy(address tokenAddress, uint256 minOut) external payable {
        require(tokens[tokenAddress] == TokenState.FUNDING, "Token not in funding state");
        require(msg.value > 0, "ETH not enough");

        uint256 fee = (msg.value * TRANSACTION_FEE_PERCENTAGE) / 100;
        uint256 netAmount = msg.value - fee;

        Token token = Token(tokenAddress);
        uint256 amount;

        // Use bonding curve for calculation if there are ETH reserves
        amount = CalculatebuyETH(tokenAddress, netAmount);
        uint256 availableSupply = MaxSupply - token.totalSupply()- initialMint;
        require(amount <= availableSupply, "Token not enough");
        require(amount>= minOut, "LS") ;
        collateral[tokenAddress] += netAmount;
        token.mint(address(this), amount);
        tokensBought[tokenAddress][msg.sender] += amount;
        totalBought[msg.sender] += netAmount;
        balances[tokenAddress][msg.sender] += amount;

        emit TokensPurchased(tokenAddress, msg.sender, netAmount, amount);
        emit VolumeTracked(msg.sender, totalBought[msg.sender], totalSold[msg.sender]);

        if (collateral[tokenAddress] >= fundingGoal) {
            address pair = createLiquidityPool(tokenAddress);
            uint256 liquidity = addLiquidity(tokenAddress, initialMint, collateral[tokenAddress]);
            burnLiquidityToken(pair, liquidity);
            collateral[tokenAddress] = 0;
            tokens[tokenAddress] = TokenState.TRADING;
        }
    }

    function withdraw(address tokenAddress) public{
        require(balances[tokenAddress][msg.sender] > 0, "No Token Owned" );
        Token token = Token(tokenAddress);
        uint am= balances[tokenAddress][msg.sender];
        balances[tokenAddress][msg.sender]=0;
        token.transfer(msg.sender,am);
    } 

    function sell(address tokenAddress, uint256 amount) external {
        require(tokens[tokenAddress] == TokenState.TRADING, "Token not in trading state");
        require(amount > 0, "Token amount not enough");
        require(balances[tokenAddress][msg.sender] - amount>=0,"Not Enough Tokens") ;
        
        Token token = Token(tokenAddress);
        token.burn(address(this), amount);

        uint256 ethAmount = calsellPrice(tokenAddress, amount);
        uint256 fee = (ethAmount * TRANSACTION_FEE_PERCENTAGE) / 100;
        uint256 netEthAmount = ethAmount - fee;

        collateral[tokenAddress] -= netEthAmount;

        (bool success, ) = msg.sender.call{value: netEthAmount}(new bytes(0));
        require(success, "ETH send failed");

        tokensSold[tokenAddress][msg.sender] += amount;
        totalSold[msg.sender] += netEthAmount;
        balances[tokenAddress][msg.sender] -= amount;
        emit TokensSold(tokenAddress, msg.sender, amount, netEthAmount);
        emit VolumeTracked(msg.sender, totalBought[msg.sender], totalSold[msg.sender]);
    }



         // Bonding curve for buying tokens
    function calPrice (address tokenAddress, uint256 quantity) public view returns (uint256) {
        Token token = Token(tokenAddress);
        uint256 b = token.totalSupply()-initialMint+quantity;
        uint256 a = token.totalSupply()-initialMint;
        uint256 f_a = k *a+offset;
        uint256 f_b= k* b + offset;
        return ((b-a)*(f_a+ f_b)/( 2*SCALING_FACTOR));  //ethAmount  
        }
    function calsellPrice (address tokenAddress, uint256 quantity) public view returns (uint256) {
        Token token = Token(tokenAddress);
        uint256 b = token.totalSupply()-initialMint-quantity;
        uint256 a = token.totalSupply()-initialMint;
        uint256 f_a = k *a+offset;
        uint256 f_b= k* b + offset;
        return ((a-b)*(f_a+ f_b)/( 2*SCALING_FACTOR));    //ethAmount
        }
        
    // Helper for Buy
    function CalculatebuyETH(address tokenAddress, uint256 amountofETH) public view returns(uint256){
        return (1 ether/calPrice(tokenAddress,amountofETH))*amountofETH;
    }

   function getMarketCap(address tokenAddress) public view returns (uint256) {
        Token token = Token(tokenAddress);
        uint256 b = token.totalSupply()-initialMint-1*10**18;
        uint256 a = token.totalSupply()-initialMint;
        uint256 f_a = k *a+offset;
        uint256 f_b= k* b + offset;
        return ((b-a)*(f_a+ f_b)/( 2*SCALING_FACTOR))*token.totalSupply()-initialMint;    //supply*price
        }


    function createLiquidityPool(address tokenAddress) internal returns (address) {
        IUniswapV2Factory factory = IUniswapV2Factory(UNISWAP_V2_FACTORY);
        IUniswapV2Router02 router = IUniswapV2Router02(UNISWAP_V2_ROUTER);

        address pair = factory.createPair(tokenAddress, router.WETH());
        return pair;
    }

    function addLiquidity(address tokenAddress, uint256 tokenAmount, uint256 ethAmount) internal returns (uint256) {
        Token token = Token(tokenAddress);
        IUniswapV2Router02 router = IUniswapV2Router02(UNISWAP_V2_ROUTER);
        token.approve(UNISWAP_V2_ROUTER, tokenAmount);

        (, , uint256 liquidity) = router.addLiquidityETH{value: ethAmount}(
            tokenAddress,
            tokenAmount,
            tokenAmount,
            ethAmount,
            address(this),
            block.timestamp
        );

        emit LiquidityAdded(tokenAddress, tokenAmount, ethAmount, liquidity);
        return liquidity;
    }

    function burnLiquidityToken(address pair, uint256 liquidity) internal {
        IUniswapV2Pair pool = IUniswapV2Pair(pair);
        pool.transfer(address(0), liquidity);

        emit LiquidityBurned(pair, liquidity);
    }
}
