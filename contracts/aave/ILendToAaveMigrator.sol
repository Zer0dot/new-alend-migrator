pragma solidity ^0.6.6;

interface ILendToAaveMigrator {
    function migrateFromLEND(uint256 amount) external;
}