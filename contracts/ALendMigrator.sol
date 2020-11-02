pragma solidity ^0.6.6;

import "./uniswap/IUniswapV2Pair.sol";
import "./uniswap/IUniswapV2Callee.sol";
import "./aave/FlashLoanReceiverBase.sol";
import "./aave/ILendingPoolAddressesProvider.sol";
import "./aave/IlendingPool.sol";
import "./aave/ILendToAaveMigrator.sol";
import "./aave/IAToken.sol";
import "./aave/ILendingPoolAddressesProvider.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";

contract ALendMigrator is IUniswapV2Callee {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IAToken;

    IUniswapV2Pair pair;

    IAToken aLend;
    IAToken aAave;
    IERC20 aave;
    IERC20 lend;

    ILendingPoolAddressesProvider provider;
    ILendingPool lendingPool;
    ILendToAaveMigrator migrator;
    address lendingPoolCoreAddress;

    constructor(
        //address _aave,
        //address _lend
        //address _aLend,
        //address _aAave,
        //address _migrator,
        //address _addressesProvider
    ) public {
        //TEMP
        address _aave = address(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
        address _aLend = address(0x7D2D3688Df45Ce7C552E19c27e007673da9204B8);
        address _aAave = address(0xba3D9687Cf50fE253cd2e1cFeEdE1d6787344Ed5);
        address _migrator = address(0x317625234562B1526Ea2FaC4030Ea499C5291de4);
        address _addressesProvider = address(0x24a42fD28C976A61Df5D00D0599C34c4f90748c8);
        address _lend = address(0x80fB784B7eD66730e8b1DBd9820aFD29931aab03);
        //END TEMP
        provider = ILendingPoolAddressesProvider(_addressesProvider);
        lendingPool = ILendingPool(provider.getLendingPool());
        lendingPoolCoreAddress = provider.getLendingPoolCore();
        migrator = ILendToAaveMigrator(_migrator);
        aLend = IAToken(_aLend);
        aAave = IAToken(_aAave);
        aave = IERC20(_aave);
        lend = IERC20(_lend);

        /*address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

        address factory = address(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);

        /*address pairAddress = address(uint(keccak256(abi.encodePacked(
            hex'ff',
            factory,
            keccak256(abi.encodePacked(aave, weth)),
            hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f'
        ))));*/
        address pairAddress = address(0xDFC14d2Af169B0D36C4EFF567Ada9b2E0CAE044f);
        pair = IUniswapV2Pair(pairAddress);

        aave.approve(lendingPoolCoreAddress, uint256(-1));
        lend.approve(_migrator, uint256(-1));
    }

    event MigrationSuccessful(address user);

    function calculateNeededAAVE() external view returns (uint256) {
        uint256 aLendBalance = aLend.balanceOf(msg.sender);
        uint256 aaveBalanceNeeded = aLendBalance.div(100);

        //Times 100 / 99.7, + 1 to avoid Uniswap invariant error
        uint256 aaveBalancePlusFees = aaveBalanceNeeded.mul(1000).div(997); 
        uint256 feeAmount = aaveBalancePlusFees.sub(aaveBalanceNeeded).add(1);
        return feeAmount;
    }

    function migrateALend() external {
        uint256 aLendBalance = aLend.balanceOf(msg.sender);
        uint256 aaveBalanceNeeded = aLendBalance.div(100);

        //Times 100 / 99.7, add one to avoid Uniswap invariant error
        uint256 aaveBalancePlusFees = aaveBalanceNeeded.mul(1000).div(997); 
        uint256 feeAmount = aaveBalancePlusFees.sub(aaveBalanceNeeded).add(1);

        require(aave.balanceOf(msg.sender) >= feeAmount, "Not enough AAVE to cover flash swap fees.");
        aave.safeTransferFrom(msg.sender, address(this), feeAmount); //The fee is transferred in before the loan

        bytes memory flashData = abi.encode(msg.sender);

        pair.swap(aaveBalanceNeeded, 0, address(this), flashData);
    }

    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external override {

        (address caller) = abi.decode(data, (address));
        
        //Deposit the flash loaned AAVE
        lendingPool.deposit(address(aave), amount0, 0); //Maybe use my referral code 
        
        //Transfer the flash loaned deposited aAAVE to the user
        aAave.safeTransfer(caller, amount0);
        
        //Transfer in the caller's aLEND (REQUIRES aLend APPROVAL OF THIS CONTRACT)
        uint256 aLendBalance = aLend.balanceOf(caller);
        aLend.safeTransferFrom(caller, address(this), aLendBalance);

        //Redeem the aLEND for LEND
        aLend.redeem(aLendBalance);

        //Migrate the LEND to AAVE
        migrator.migrateFromLEND(aLendBalance);

        //Return AAVE + fee
        uint256 aaveToPay = aave.balanceOf(address(this));
        aave.safeTransfer(address(pair), aaveToPay); 

        emit MigrationSuccessful(caller);
        //From here on out, we're done. Godspeed.
    }
}