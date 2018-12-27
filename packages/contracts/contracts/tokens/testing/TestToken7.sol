
pragma solidity 0.5.2;

import "../BaseToken.sol";


// 1 billion tokens (18 decimal places)
contract TestToken7 is BaseToken( // solhint-disable-line no-empty-blocks
    10**(50+18),
    "TestToken7", 
    18,
    "TEST7"
) {}
