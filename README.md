# new-alend-migrator
New aLEND to aAAVE migrator with active debt.
 
~~Working on allowing migration when aLEND > available AAVE liquidity on Uniswap. (1 address)~~

The above is now fixed through the use of multiple transactions.

## Steps Needed to Migrate Successfully

1. Have any amount of aAAVE deposited to enable collateralization. (Make sure it's enabled!)
2. Make sure you have enough AAVE to cover the Uniswap flash swap fee (call the "CalculateNeededAave" function, it returns both the AAVE to be flash swapped AND the fee amount you must have in your wallet. When aLEND > available AAVE liquidity, the fee is the amount for only the next tx.) 
3. Approve the contract for aLEND and AAVE spending.
4. Finally, just call the "MigrateALend" function and the migration will proceed automatically. For aLEND > AAVE liquidity on Uniswap, you will need to call it multiple times.

## USE AT YOUR OWN RISK
