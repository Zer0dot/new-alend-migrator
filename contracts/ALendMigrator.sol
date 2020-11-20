pragma solidity ^0.6.6;

import "./uniswap/IUniswapV2Pair.sol";
import "./uniswap/IUniswapV2Callee.sol";
import "./aave/ILendingPoolAddressesProvider.sol";
import "./aave/ILendingPool.sol";
import "./aave/ILendToAaveMigrator.sol";
import "./aave/IAToken.sol";
import "./aave/ILendingPoolAddressesProvider.sol";
import "./utils/Withdrawable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";

/**
 * @title ALendMigrator Contract
 * @author Zer0dot
 * @notice Migrates your aLEND to aAAVE using a Uniswap Flash Swap, this
 * requires that you have aAAVE deposited with collateralization enabled,
 * regular AAVE in your wallet to pay for fees and AAVE and aLEND approval.
 */
contract ALendMigrator is IUniswapV2Callee, Withdrawable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IAToken;

    uint16 constant refCode = 152;

    address constant _aave = address(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
    address constant _aLend = address(0x7D2D3688Df45Ce7C552E19c27e007673da9204B8);
    address constant _aAave = address(0xba3D9687Cf50fE253cd2e1cFeEdE1d6787344Ed5);
    address constant _migrator = address(0x317625234562B1526Ea2FaC4030Ea499C5291de4);
    address constant _addressesProvider = address(0x24a42fD28C976A61Df5D00D0599C34c4f90748c8);
    address constant _lend = address(0x80fB784B7eD66730e8b1DBd9820aFD29931aab03);
    address constant pairAddress = address(0xDFC14d2Af169B0D36C4EFF567Ada9b2E0CAE044f);

    IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
    IAToken aLend = IAToken(_aLend);
    IAToken aAave = IAToken(_aAave);
    IERC20 aave = IERC20(_aave);
    IERC20 lend = IERC20(_lend);

    ILendingPoolAddressesProvider provider = ILendingPoolAddressesProvider(_addressesProvider);
    ILendingPool lendingPool = ILendingPool(provider.getLendingPool());
    ILendToAaveMigrator migrator = ILendToAaveMigrator(_migrator);
    address lendingPoolCoreAddress = provider.getLendingPoolCore();

    /**
     * @dev Emitted when a user successfully migrates their aLend to aAAVE
     *
     * @param user The user address who has successfully migrated.
     */
    event MigrationSuccessful(address user);

    /**
     * @dev Constructor approves the Aave lendingPoolCore and Migrator contracts.
     */
    constructor() public {
        aave.approve(lendingPoolCoreAddress, uint256(-1));
        lend.approve(_migrator, uint256(-1));
    }

    /**
     * @dev Returns the needed AAVE to flash swap and the needed
     * AAVE to cover the flash swap fee for msg.sender  
     */
    function calculateNeededAave() public view returns (uint256, uint256) {
        uint256 aLendBalance = aLend.balanceOf(msg.sender);
        require(aLendBalance > 0, "No aLEND to migrate.");
        uint256 aaveBalanceNeeded;
        uint256 aaveBalancePlusFees;
        (uint112 aaveReserve, , ) = pair.getReserves();

        if (aaveReserve < aLendBalance.div(100)) {
            // Entire reserve -1 to avoid Uniswap Insufficient Liquidity error
            aaveBalanceNeeded = uint256(aaveReserve).sub(1);
        } else {
            aaveBalanceNeeded = aLendBalance.div(100);
        }
        
        // Times 100 / 99.7 to calculate fees, add 1 to fees to avoid Uniswap invariant error
        aaveBalancePlusFees = aaveBalanceNeeded.mul(1000).div(997);
        uint256 feeAmount = aaveBalancePlusFees.sub(aaveBalanceNeeded).add(1);
        return (aaveBalanceNeeded, feeAmount);
    }

    /**
     * @dev Migrates msg.sender's aLEND to aAAVE, calculates fees and initiates the flash swap.
     */
    function migrateALend() external {
        // Verify that aAAVE is collateral-enabled
        ( , , , , , , , , , bool collateralEnabled) = lendingPool.getUserReserveData(_aave, msg.sender);
        require(collateralEnabled == true, "AAVE is not collateral-enabled.");
        (uint256 aaveBalanceNeeded, uint256 feeAmount) = calculateNeededAave();

        // The fee is transferred in before the loan
        require(aave.balanceOf(msg.sender) >= feeAmount, "Not enough AAVE to cover flash swap fees.");
        aave.safeTransferFrom(msg.sender, address(this), feeAmount); 

        // Get the current AAVE balance to verify that the flash swap worked later
        uint256 currentAaveBalance = aave.balanceOf(address(this));
        bytes memory flashData = abi.encode(msg.sender, currentAaveBalance);

        pair.swap(aaveBalanceNeeded, 0, address(this), flashData);
    }

    /**
     * @dev Executes the flash swap aLEND migration. This can only be called by the correct pair address
     * and proceeds with the following steps:
     * 
     * 1. Ensures the flash swap correctly credited AAVE
     * 2. Deposits the flash swapped AAVE
     * 3. Transfers the newly-deposited aAAVE to the caller
     * 4. Ensures no leftover dust (if aLEND < 100e-18)
     * 5. Transfers in the caller's aLEND
     * 6. Redeems the aLEND
     * 7. Migrates the redeemed LEND to AAVE
     * 8. Repays the flash swap
     * 9. Ensures that the caller received the aAAVE
     */
    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external override {
        require(msg.sender == address(pair), "Only the Uniswap AAVE/ETH pair can call this function.");

        (address caller, uint256 previousAaveBalance) = abi.decode(data, (address, uint256));
        require(aave.balanceOf(address(this)) > previousAaveBalance, "Flash swap did not credit AAVE.");
    
        lendingPool.deposit(address(aave), amount0, refCode);
        aAave.safeTransfer(caller, amount0);

        uint256 aLendBalance = amount0.mul(100);
        uint256 aLendLeftover = aLend.balanceOf(caller).sub(aLendBalance);
        if(aLendLeftover < 100 && aLendLeftover > 0) {
            aLendBalance = aLendBalance.add(aLendLeftover);
        }

        aLend.safeTransferFrom(caller, address(this), aLendBalance);
        aLend.redeem(aLendBalance);
        migrator.migrateFromLEND(aLendBalance);

        uint256 aaveToPay = aave.balanceOf(address(this));
        aave.safeTransfer(address(pair), aaveToPay); 

        require(aAave.balanceOf(caller).mul(1000) >= aLendBalance.mul(1000).div(100));

        emit MigrationSuccessful(caller);
    }
}