pragma solidity ^0.6.6;

import "./uniswap/IUniswapV2Pair.sol";
import "./uniswap/IUniswapV2Callee.sol";
import "./aave/ILendingPoolAddressesProvider.sol";
import "./aave/ILendingPool.sol";
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

    event MigrationSuccessful(address user);

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

        //Address calculation
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

    function calculateNeededAave() public view returns (uint256, uint256) {
        uint256 aaveBalanceNeeded;
        uint256 aaveBalancePlusFees;
        
        uint256 aLendBalance = aLend.balanceOf(msg.sender);
        (uint112 aaveReserve, , ) = pair.getReserves();

        //If the address has too much aLEND, default to using the entire AAVE reserve, with leeway to trade
        //For the fee
        if (aaveReserve < aLendBalance.div(100)) {
            //Use the entire AAVE balance on Uniswap
            aaveBalancePlusFees = uint256(aaveReserve);
            aaveBalanceNeeded = aaveBalancePlusFees.mul(997).div(1000);
        } else {
            //uint256 aLendBalance = aLend.balanceOf(msg.sender);
            aaveBalanceNeeded = aLendBalance.div(100);
            //Times 100 / 99.7 to calculate fees
            aaveBalancePlusFees = aaveBalanceNeeded.mul(1000).div(997); 
        }

        // add 1 to avoid Uniswap invariant error
        uint256 feeAmount = aaveBalancePlusFees.sub(aaveBalanceNeeded).add(1);
        return (aaveBalanceNeeded, feeAmount);
    }

    function migrateALend() external {
        (uint256 aaveBalanceNeeded, uint256 feeAmount) = calculateNeededAave();

        //The fee is transferred in before the loan
        require(aave.balanceOf(msg.sender) >= feeAmount, "Not enough AAVE to cover flash swap fees.");
        aave.safeTransferFrom(msg.sender, address(this), feeAmount); 

        //Get the current AAVE balance to verify that the flash swap worked later
        uint256 currentAaveBalance = aave.balanceOf(address(this));
        bytes memory flashData = abi.encode(msg.sender, currentAaveBalance);

        pair.swap(aaveBalanceNeeded, 0, address(this), flashData);
    }

    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external override {
        
        //Verify that only the correct pair address can call this function
        require(msg.sender == address(pair), "Only the Uniswap AAVE/ETH pair can call this function.");

        (address caller, uint256 previousAaveBalance) = abi.decode(data, (address, uint256));

        //Verify that the flash swap credited the contract with the amount of AAVE needed
        require(aave.balanceOf(address(this)) > previousAaveBalance, "Flash swap did not credit AAVE.");
    
        //Deposit the flash loaned AAVE
        lendingPool.deposit(address(aave), amount0, 0);
        
        //Transfer the flash loaned deposited aAAVE to the user
        aAave.safeTransfer(caller, amount0);
        
        //Transfer in the caller's aLEND (REQUIRES aLend APPROVAL OF THIS CONTRACT)
        uint256 aLendBalance = amount0.mul(100);//aLend.balanceOf(caller);
        uint256 aLendLeftover = aLend.balanceOf(caller).sub(aLendBalance);
        //Check if leftover aLend is less than 1 "wei" AAVE worth, if so, transfer it along
        if(aLendLeftover < 100 && aLendLeftover > 0) {
            aLendBalance = aLendBalance.add(aLendLeftover);
        }
        aLend.safeTransferFrom(caller, address(this), aLendBalance);

        //Redeem the aLEND for LEND
        aLend.redeem(aLendBalance);

        //Migrate the LEND to AAVE
        migrator.migrateFromLEND(aLendBalance);

        //Return AAVE + fee
        uint256 aaveToPay = aave.balanceOf(address(this));
        aave.safeTransfer(address(pair), aaveToPay); 

        //Verify the aAAVE is successfully deposited and transferred
        require(aAave.balanceOf(caller).mul(1000) >= aLendBalance.mul(1000).div(100));

        emit MigrationSuccessful(caller);
    }
}