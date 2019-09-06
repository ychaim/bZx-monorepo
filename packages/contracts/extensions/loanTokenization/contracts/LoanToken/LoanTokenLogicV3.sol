/**
 * Copyright 2017-2019, bZeroX, LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0.
 */

pragma solidity 0.5.8;
pragma experimental ABIEncoderV2;

import "./AdvancedToken.sol";
import "../shared/OracleNotifierInterface.sol";


interface IBZx {
    function takeOrderFromiToken(
        bytes32 loanOrderHash, // existing loan order hash
        address[3] calldata sentAddresses,
            // trader: borrower/trader
            // collateralTokenAddress: collateral token
            // tradeTokenAddress: trade token
        uint256[7] calldata sentAmounts,
            // newInterestRate: new loan interest rate
            // newLoanAmount: new loan size (principal from lender)
            // interestInitialAmount: interestAmount sent to determine initial loan length (this is included in one of the below)
            // loanTokenSent: loanTokenAmount + interestAmount + any extra
            // collateralTokenSent: collateralAmountRequired + any extra
            // tradeTokenSent: tradeTokenAmount (optional)
            // withdrawalAmount: Actual amount sent to borrower (can't exceed newLoanAmount)
        bytes calldata loanData)
        external
        returns (uint256);

    function getLenderInterestForOracle(
        address lender,
        address oracleAddress,
        address interestTokenAddress)
        external
        view
        returns (
            uint256,    // interestPaid
            uint256,    // interestPaidDate
            uint256,    // interestOwedPerDay
            uint256);   // interestUnPaid

    function oracleAddresses(
        address oracleAddress)
        external
        view
        returns (address);

    function getRequiredCollateral(
        address loanTokenAddress,
        address collateralTokenAddress,
        address oracleAddress,
        uint256 newLoanAmount,
        uint256 marginAmount)
        external
        view
        returns (uint256 collateralTokenAmount);

    function getBorrowAmount(
        address loanTokenAddress,
        address collateralTokenAddress,
        address oracleAddress,
        uint256 collateralTokenAmount,
        uint256 marginAmount)
        external
        view
        returns (uint256 borrowAmount);
}

interface IBZxOracle {
    function getTradeData(
        address sourceTokenAddress,
        address destTokenAddress,
        uint256 sourceTokenAmount)
        external
        view
        returns (uint256 sourceToDestRate, uint256 sourceToDestPrecision, uint256 destTokenAmount);
}

interface iTokenizedRegistry {
    function isTokenType(
        address _token,
        uint256 _tokenType)
        external
        view
        returns (bool valid);
}

contract LoanTokenLogicV3 is AdvancedToken, OracleNotifierInterface {
    using SafeMath for uint256;

    address internal target_;

    modifier onlyOracle() {
        require(msg.sender == IBZx(bZxContract).oracleAddresses(bZxOracle), "1");
        _;
    }


    function()
        external
        payable
    {
        require(
            msg.sender == wethContract,
            "fallback not allowed"
        );
    }


    /* Public functions */

    function mintWithEther(
        address receiver)
        external
        payable
        nonReentrant
        returns (uint256 mintAmount)
    {
        require(loanTokenAddress == wethContract, "2");
        return _mintToken(
            receiver,
            msg.value
        );
    }

    function mint(
        address receiver,
        uint256 depositAmount)
        external
        nonReentrant
        returns (uint256 mintAmount)
    {
        return _mintToken(
            receiver,
            depositAmount
        );
    }

    function burnToEther(
        address payable receiver,
        uint256 burnAmount)
        external
        nonReentrant
        returns (uint256 loanAmountPaid)
    {
        require(loanTokenAddress == wethContract, "3");
        loanAmountPaid = _burnToken(
            receiver,
            burnAmount
        );

        if (loanAmountPaid != 0) {
            WETHInterface(wethContract).withdraw(loanAmountPaid);
            require(receiver.send(loanAmountPaid), "4");
        }
    }

    function burn(
        address receiver,
        uint256 burnAmount)
        external
        nonReentrant
        returns (uint256 loanAmountPaid)
    {
        loanAmountPaid = _burnToken(
            receiver,
            burnAmount
        );

        if (loanAmountPaid != 0) {
            require(ERC20(loanTokenAddress).transfer(
                receiver,
                loanAmountPaid
            ), "5");
        }
    }

    function borrowTokenFromDeposit(
        uint256 borrowAmount,
        uint256 leverageAmount,
        uint256 initialLoanDuration,    // duration in seconds
        uint256 collateralTokenSent,    // set to 0 if sending ETH
        address borrower,
        address collateralTokenAddress, // address(0) means ETH and ETH must be sent with the call
        bytes memory loanData)          // 1st byte (MSB) is 0x0 or 0x1 indicating the interest model (variable or fixed); remaining bytes are 0x orders
        public
        payable
        nonReentrant
        returns (bytes32 loanOrderHash)
    {
        require(
            ((msg.value == 0 && collateralTokenAddress != address(0) && collateralTokenSent != 0) ||
            (msg.value != 0 && (collateralTokenAddress == address(0) || collateralTokenAddress == wethContract) && collateralTokenSent == 0)),
            "6"
        );

        loanOrderHash = loanOrderHashes[leverageAmount];
        require(loanOrderHash != 0, "7");

        _settleInterest();

        uint256 value = _totalAssetSupply(0);

        uint256[7] memory sentAmounts;

        bool useFixedInterestModel;
        if (loanData.length != 0) {
            assembly {
                useFixedInterestModel := mload(add(loanData, 1))
            }
        }

        if (borrowAmount == 0) {
            // borrowAmount, interestRate
            (borrowAmount, sentAmounts[0]) = _getBorrowAmountForDeposit(
                collateralTokenSent,
                leverageAmount,
                initialLoanDuration,
                collateralTokenAddress,
                useFixedInterestModel
            );
            require(borrowAmount != 0, "borrowAmount == 0");
        } else {
            // interestRate
            sentAmounts[0] = _nextBorrowInterestRate(
                borrowAmount,
                value,
                useFixedInterestModel
            );
        }

        // initial interestInitialAmount
        sentAmounts[2] = borrowAmount
            .mul(sentAmounts[0]);
        sentAmounts[2] = sentAmounts[2]
            .mul(initialLoanDuration);
        sentAmounts[2] = sentAmounts[2]
            .div(31536000 * 10**20); // 365 * 86400 * 10**20

        // withdrawalAmount
        sentAmounts[6] = borrowAmount;

        borrowAmount = borrowAmount.add(sentAmounts[2]);

        // final interestRate
        sentAmounts[0] = _nextBorrowInterestRate(
            borrowAmount,
            value,
            useFixedInterestModel
        );

        if (msg.value != 0) {
            collateralTokenAddress = wethContract;
            collateralTokenSent = msg.value;
        }

        sentAmounts[6] = _borrowTokenAndUseFinal(
            loanOrderHash,
            [
                borrower,
                collateralTokenAddress,
                address(0) // tradeTokenAddress
            ],
            [
                sentAmounts[0],         // interestRate
                borrowAmount,
                sentAmounts[2],         // interestInitialAmount
                0,                      // loanTokenSent
                collateralTokenSent,
                0,                      // tradeTokenSent
                sentAmounts[6]          // withdrawalAmount
            ],
            loanData
        );
        require(sentAmounts[6] == borrowAmount, "8");
    }

    // Called to borrow token for withdrawal or trade
    // borrowAmount: loan amount to borrow
    // leverageAmount: signals the amount of initial margin we will collect
    //   Please reference the docs for supported values.
    //   Example: 2000000000000000000 -> 150% initial margin
    //            2000000000000000028 -> 150% initial margin, 28-day fixed-term
    // interestInitialAmount: This value will indicate the initial duration of the loan
    //   This is ignored if the loan order has a fixed-term
    // loanTokenSent: loan token sent (interestAmount + extra)
    // collateralTokenSent: collateral token sent
    // tradeTokenSent: trade token sent
    // borrower: the address the loan will be assigned to (this address can be different than msg.sender)
    //    Collateral and interest for loan will be withdrawn from msg.sender
    // collateralTokenAddress: The token to collateralize the loan in
    // tradeTokenAddress: The borrowed token will be swap for this token to start a leveraged trade
    //    If the borrower wished to instead withdraw the borrowed token to their wallet, set this to address(0)
    //    If set to address(0), initial collateral required will equal initial margin percent + 100%
    // returns loanOrderHash for the base protocol loan
    function borrowTokenAndUse(
        uint256 borrowAmount,
        uint256 leverageAmount,
        uint256 interestInitialAmount,
        uint256 loanTokenSent,
        uint256 collateralTokenSent,
        uint256 tradeTokenSent,
        address borrower,
        address collateralTokenAddress,
        address tradeTokenAddress,
        bytes memory loanData)
        public
        nonReentrant
        returns (bytes32 loanOrderHash)
    {
        require(collateralTokenAddress != address(0) &&
            (tradeTokenAddress == address(0) ||
                tradeTokenAddress != loanTokenAddress),
            "9"
        );

        loanOrderHash = _borrowTokenAndUse(
            leverageAmount,
            [
                borrower,
                collateralTokenAddress,
                tradeTokenAddress
            ],
            [
                0, // interestRate (found later)
                borrowAmount,
                interestInitialAmount,
                loanTokenSent,
                collateralTokenSent,
                tradeTokenSent,
                borrowAmount
            ],
            false, // amountIsADeposit
            loanData
        );
    }

    function marginTradeFromDeposit(
        uint256 depositAmount,
        uint256 leverageAmount,
        uint256 loanTokenSent,
        uint256 collateralTokenSent,
        uint256 tradeTokenSent,
        address trader,
        address depositTokenAddress,
        address collateralTokenAddress,
        address tradeTokenAddress)
        public
        nonReentrant
        returns (bytes32 loanOrderHash)
    {
        return _marginTradeFromDeposit(
            depositAmount,
            leverageAmount,
            loanTokenSent,
            collateralTokenSent,
            tradeTokenSent,
            trader,
            depositTokenAddress,
            collateralTokenAddress,
            tradeTokenAddress,
            "" // loanData
        );
    }

    function marginTradeFromDeposit(
        uint256 depositAmount,
        uint256 leverageAmount,
        uint256 loanTokenSent,
        uint256 collateralTokenSent,
        uint256 tradeTokenSent,
        address trader,
        address depositTokenAddress,
        address collateralTokenAddress,
        address tradeTokenAddress,
        bytes memory loanData)
        public
        nonReentrant
        returns (bytes32 loanOrderHash)
    {
        return _marginTradeFromDeposit(
            depositAmount,
            leverageAmount,
            loanTokenSent,
            collateralTokenSent,
            tradeTokenSent,
            trader,
            depositTokenAddress,
            collateralTokenAddress,
            tradeTokenAddress,
            loanData
        );
    }

    // Called by pTokens to borrow and immediately get into a positions
    // Other traders can call this, but it's recommended to instead use borrowTokenAndUse(...) instead
    // assumption: depositAmount is collateral + interest deposit and will be denominated in deposit token
    // assumption: loan token and interest token are the same
    // returns loanOrderHash for the base protocol loan
    function _marginTradeFromDeposit(
        uint256 depositAmount,
        uint256 leverageAmount,
        uint256 loanTokenSent,
        uint256 collateralTokenSent,
        uint256 tradeTokenSent,
        address trader,
        address depositTokenAddress,
        address collateralTokenAddress,
        address tradeTokenAddress,
        bytes memory loanData)
        internal
        returns (bytes32 loanOrderHash)
    {
        require(tradeTokenAddress != address(0) &&
            tradeTokenAddress != loanTokenAddress,
            "10"
        );

        uint256 amount = depositAmount;
        // To calculate borrow amount and interest owed to lender we need deposit amount to be represented as loan token
        if (depositTokenAddress == tradeTokenAddress) {
            (,,amount) = IBZxOracle(bZxOracle).getTradeData(
                tradeTokenAddress,
                loanTokenAddress,
                amount
            );
        } else if (depositTokenAddress != loanTokenAddress) {
            // depositTokenAddress can only be tradeTokenAddress or loanTokenAddress
            revert("11");
        }

        loanOrderHash = _borrowTokenAndUse(
            leverageAmount,
            [
                trader,
                collateralTokenAddress,     // collateralTokenAddress
                tradeTokenAddress          // tradeTokenAddress
            ],
            [
                0,                      // interestRate (found later)
                amount,                 // amount of deposit
                0,                      // interestInitialAmount (interest is calculated based on fixed-term loan)
                loanTokenSent,
                collateralTokenSent,
                tradeTokenSent,
                0
            ],
            true,                        // amountIsADeposit
            loanData
        );
    }


    // Claims owned loan token for the caller
    // Also claims for user with the longest reserves
    // returns amount claimed for the caller
    function claimLoanToken()
        external
        nonReentrant
        returns (uint256 claimedAmount)
    {
        claimedAmount = _claimLoanToken(msg.sender);

        if (burntTokenReserveList.length != 0) {
            _claimLoanToken(address(0));

            if (burntTokenReserveListIndex[msg.sender].isSet && nextOwedLender_ != msg.sender) {
                // ensure lender is paid next
                nextOwedLender_ = msg.sender;
            }
        }
    }

    function wrapEther()
        public
    {
        if (address(this).balance != 0) {
            WETHInterface(wethContract).deposit.value(address(this).balance)();
        }
    }

    // Sends non-LoanToken assets to the Oracle fund
    // These are assets that would otherwise be "stuck" due to a user accidently sending them to the contract
    function donateAsset(
        address tokenAddress)
        public
        returns (bool)
    {
        if (tokenAddress == loanTokenAddress)
            return false;

        uint256 balance = ERC20(tokenAddress).balanceOf(address(this));
        if (balance == 0)
            return false;

        require(ERC20(tokenAddress).transfer(
            IBZx(bZxContract).oracleAddresses(bZxOracle),
            balance
        ), "12");

        return true;
    }

    function transfer(
        address _to,
        uint256 _value)
        public
        returns (bool)
    {
        require(_value <= balances[msg.sender], "insufficient balance");
        require(_to != address(0), "13");

        balances[msg.sender] = balances[msg.sender].sub(_value);
        balances[_to] = balances[_to].add(_value);

        // handle checkpoint update
        uint256 currentPrice = tokenPrice();
        if (burntTokenReserveListIndex[msg.sender].isSet || balances[msg.sender] != 0) {
            checkpointPrices_[msg.sender] = currentPrice;
        } else {
            checkpointPrices_[msg.sender] = 0;
        }
        if (burntTokenReserveListIndex[_to].isSet || balances[_to] != 0) {
            checkpointPrices_[_to] = currentPrice;
        } else {
            checkpointPrices_[_to] = 0;
        }

        emit Transfer(msg.sender, _to, _value);
        return true;
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _value)
        public
        returns (bool)
    {
        uint256 allowanceAmount = allowed[_from][msg.sender];
        require(_value <= balances[_from], "14");
        require(_value <= allowanceAmount, "15");
        require(_to != address(0), "16");

        balances[_from] = balances[_from].sub(_value);
        balances[_to] = balances[_to].add(_value);
        if (allowanceAmount < MAX_UINT) {
            allowed[_from][msg.sender] = allowanceAmount.sub(_value);
        }

        // handle checkpoint update
        uint256 currentPrice = tokenPrice();
        if (burntTokenReserveListIndex[_from].isSet || balances[_from] != 0) {
            checkpointPrices_[_from] = currentPrice;
        } else {
            checkpointPrices_[_from] = 0;
        }
        if (burntTokenReserveListIndex[_to].isSet || balances[_to] != 0) {
            checkpointPrices_[_to] = currentPrice;
        } else {
            checkpointPrices_[_to] = 0;
        }

        emit Transfer(_from, _to, _value);
        return true;
    }


    /* Public View functions */

    function tokenPrice()
        public
        view
        returns (uint256 price)
    {
        uint256 interestUnPaid;
        if (lastSettleTime_ != block.timestamp) {
            (,,interestUnPaid) = _getAllInterest();

            interestUnPaid = interestUnPaid
                .mul(spreadMultiplier)
                .div(10**20);
        }

        return _tokenPrice(_totalAssetSupply(interestUnPaid));
    }

    function checkpointPrice(
        address _user)
        public
        view
        returns (uint256 price)
    {
        return checkpointPrices_[_user];
    }

    function totalReservedSupply()
        public
        view
        returns (uint256)
    {
        return burntTokenReserved.mul(tokenPrice()).div(10**18);
    }

    function marketLiquidity()
        public
        view
        returns (uint256)
    {
        uint256 totalSupply = totalAssetSupply();
        uint256 reservedSupply = totalReservedSupply();
        if (totalSupply > reservedSupply) {
            totalSupply = totalSupply.sub(reservedSupply);
        } else {
            return 0;
        }

        if (totalSupply > totalAssetBorrow) {
            return totalSupply.sub(totalAssetBorrow);
        } else {
            return 0;
        }
    }

    // interest that lenders are currently receiving for open loans, prior to any fees
    function supplyInterestRate()
        public
        view
        returns (uint256)
    {
        if (totalAssetBorrow != 0) {
            return _supplyInterestRate(totalAssetSupply());
        }
    }

    // the average interest that borrowers are currently paying for open loans, prior to any fees
    function avgBorrowInterestRate()
        public
        view
        returns (uint256)
    {
        if (totalAssetBorrow != 0) {
            return _protocolInterestRate(totalAssetSupply());
        } else {
            return baseRate;
        }
    }

    // the base rate the next base protocol borrower will receive for variable-rate loans
    function borrowInterestRate()
        public
        view
        returns (uint256)
    {
        return _nextBorrowInterestRate(
            0, // borrowAmount
            totalAssetSupply(),
            false // useFixedInterestModel
        );
    }

    // the rate the next base protocol borrower will receive based on the amount being borrowed for variable-rate loans
    function nextBorrowInterestRate(
        uint256 borrowAmount)
        public
        view
        returns (uint256)
    {
        uint256 interestUnPaid;
        if (borrowAmount != 0) {
            if (lastSettleTime_ != block.timestamp) {
                (,,interestUnPaid) = _getAllInterest();

                interestUnPaid = interestUnPaid
                    .mul(spreadMultiplier)
                    .div(10**20);
            }

            uint256 balance = ERC20(loanTokenAddress).balanceOf(address(this)).add(interestUnPaid);
            if (borrowAmount > balance) {
                borrowAmount = balance;
            }
        }

        return _nextBorrowInterestRate(
            borrowAmount,
            _totalAssetSupply(interestUnPaid),
            false // useFixedInterestModel
        );
    }

    // kept for backwards compatability
    function nextLoanInterestRate(
        uint256 borrowAmount)
        public
        view
        returns (uint256)
    {
        return nextBorrowInterestRate(borrowAmount);
    }

    function nextSupplyInterestRate(
        uint256 supplyAmount)
        public
        view
        returns (uint256)
    {
        if (totalAssetBorrow != 0) {
            return _supplyInterestRate(totalAssetSupply().add(supplyAmount));
        }
    }

    function totalAssetSupply()
        public
        view
        returns (uint256)
    {
        uint256 interestUnPaid;
        if (lastSettleTime_ != block.timestamp) {
            (,,interestUnPaid) = _getAllInterest();

            interestUnPaid = interestUnPaid
                .mul(spreadMultiplier)
                .div(10**20);
        }

        return _totalAssetSupply(interestUnPaid);
    }

    function getMaxEscrowAmount(
        uint256 leverageAmount)
        public
        view
        returns (uint256)
    {
        LoanData memory loanData = loanOrderData[loanOrderHashes[leverageAmount]];
        if (loanData.initialMarginAmount == 0)
            return 0;

        return marketLiquidity()
            .mul(loanData.initialMarginAmount)
            .div(_adjustValue(
                10**20, // maximum possible interest (100%)
                loanData.maxDurationUnixTimestampSec,
                loanData.initialMarginAmount));
    }

    function getLeverageList()
        public
        view
        returns (uint256[] memory)
    {
        return leverageList;
    }

    // returns the user's balance of underlying token
    function assetBalanceOf(
        address _owner)
        public
        view
        returns (uint256)
    {
        return balanceOf(_owner)
            .mul(tokenPrice())
            .div(10**18);
    }

    function getDepositAmountForBorrow(
        uint256 borrowAmount,
        uint256 leverageAmount,             // use 2000000000000000000 for 150% initial margin
        uint256 initialLoanDuration,        // duration in seconds
        address collateralTokenAddress,     // address(0) means ETH
        bool useFixedInterestModel)         // False=variable interest, True=fixed interest
        public
        view
        returns (uint256 depositAmount)
    {
        // interestInitialAmount
        (uint256 value,) = _getInterestInitialAmount(
            borrowAmount,
            initialLoanDuration,
            useFixedInterestModel
        );

        borrowAmount = borrowAmount
            .add(value);
        borrowAmount = _verifyBorrowAmount(borrowAmount);

        value = loanOrderData[loanOrderHashes[leverageAmount]].initialMarginAmount
            .add(10**20); // adjust for over-collateralized loan

        if (borrowAmount != 0) {
            return IBZx(bZxContract).getRequiredCollateral(
                loanTokenAddress,
                collateralTokenAddress != address(0) ? collateralTokenAddress : wethContract,
                bZxOracle,
                borrowAmount,
                value // marginAmount
            );
        } else {
            return 0;
        }
    }

    function getBorrowAmountForDeposit(
        uint256 depositAmount,
        uint256 leverageAmount,             // use 2000000000000000000 for 150% initial margin
        uint256 initialLoanDuration,        // duration in seconds
        address collateralTokenAddress,     // address(0) means ETH
        bool useFixedInterestModel)         // False=variable interest, True=fixed interest
        public
        view
        returns (uint256 borrowAmount)
    {
        (borrowAmount,) = _getBorrowAmountForDeposit(
            depositAmount,
            leverageAmount,
            initialLoanDuration,
            collateralTokenAddress,
            useFixedInterestModel
        );
    }


    /* Internal functions */

    function _mintToken(
        address receiver,
        uint256 depositAmount)
        internal
        returns (uint256 mintAmount)
    {
        require (depositAmount != 0, "17");

        if (burntTokenReserveList.length != 0) {
            _claimLoanToken(address(0));
            _claimLoanToken(receiver);
            if (msg.sender != receiver)
                _claimLoanToken(msg.sender);
        } else {
            _settleInterest();
        }

        uint256 assetSupply = _totalAssetSupply(0);
        uint256 currentPrice = _tokenPrice(assetSupply);
        mintAmount = depositAmount.mul(10**18).div(currentPrice);

        if (msg.value == 0) {
            require(ERC20(loanTokenAddress).transferFrom(
                msg.sender,
                address(this),
                depositAmount
            ), "18");
        } else {
            WETHInterface(wethContract).deposit.value(depositAmount)();
        }

        _setInternalSupply(
            assetSupply.add(depositAmount)
        );

        _mint(receiver, mintAmount, depositAmount, currentPrice);

        checkpointPrices_[receiver] = currentPrice;
    }

    function _burnToken(
        address receiver,
        uint256 burnAmount)
        internal
        returns (uint256 loanAmountPaid)
    {
        require(burnAmount != 0, "19");

        if (burnAmount > balanceOf(msg.sender)) {
            burnAmount = balanceOf(msg.sender);
        }

        if (burntTokenReserveList.length != 0) {
            _claimLoanToken(address(0));
            _claimLoanToken(receiver);
            if (msg.sender != receiver)
                _claimLoanToken(msg.sender);
        } else {
            _settleInterest();
        }

        uint256 assetSupply = _totalAssetSupply(0);
        uint256 currentPrice = _tokenPrice(assetSupply);

        uint256 loanAmountOwed = burnAmount.mul(currentPrice).div(10**18);
        uint256 loanAmountAvailableInContract = ERC20(loanTokenAddress).balanceOf(address(this));

        loanAmountPaid = loanAmountOwed;
        if (loanAmountPaid > loanAmountAvailableInContract) {
            uint256 reserveAmount = loanAmountPaid.sub(loanAmountAvailableInContract);
            uint256 reserveTokenAmount = reserveAmount.mul(10**18).div(currentPrice);

            burntTokenReserved = burntTokenReserved.add(reserveTokenAmount);
            if (burntTokenReserveListIndex[receiver].isSet) {
                uint256 index = burntTokenReserveListIndex[receiver].index;
                burntTokenReserveList[index].amount = burntTokenReserveList[index].amount.add(reserveTokenAmount);
            } else {
                burntTokenReserveList.push(TokenReserves({
                    lender: receiver,
                    amount: reserveTokenAmount
                }));
                burntTokenReserveListIndex[receiver] = ListIndex({
                    index: burntTokenReserveList.length-1,
                    isSet: true
                });
            }

            loanAmountPaid = loanAmountAvailableInContract;
        }

        _setInternalSupply(
            assetSupply.sub(loanAmountPaid)
        );

        _burn(msg.sender, burnAmount, loanAmountPaid, currentPrice);

        if (burntTokenReserveListIndex[msg.sender].isSet || balances[msg.sender] != 0) {
            checkpointPrices_[msg.sender] = currentPrice;
        } else {
            checkpointPrices_[msg.sender] = 0;
        }
    }

    function _settleInterest()
        internal
    {
        if (lastSettleTime_ != block.timestamp) {
            (bool success,) = bZxContract.call.gas(gasleft())(
                abi.encodeWithSignature(
                    "payInterestForOracle(address,address)",
                    bZxOracle, // (leave as original value)
                    loanTokenAddress // same as interestTokenAddress
                )
            );
            success;
            lastSettleTime_ = block.timestamp;
        }
    }

    function _getBorrowAmountForDeposit(
        uint256 depositAmount,
        uint256 leverageAmount,             // use 2000000000000000000 for 150% initial margin
        uint256 initialLoanDuration,        // duration in seconds
        address collateralTokenAddress,     // address(0) means ETH
        bool useFixedInterestModel)         // False=variable interest, True=fixed interest
        internal
        view
        returns (uint256 borrowAmount, uint256 interestRate)
    {
        uint256 value = loanOrderData[loanOrderHashes[leverageAmount]].initialMarginAmount
            .add(10**20); // adjust for over-collateralized loan

        borrowAmount = IBZx(bZxContract).getBorrowAmount(
            loanTokenAddress,
            collateralTokenAddress != address(0) ? collateralTokenAddress : wethContract,
            bZxOracle,
            depositAmount,
            value // marginAmount
        );

        // interestInitialAmount
        (value, interestRate) = _getInterestInitialAmount(
            borrowAmount,
            initialLoanDuration,
            useFixedInterestModel
        );

        if (borrowAmount > value) {
            borrowAmount = borrowAmount
                .sub(value);
            borrowAmount = _verifyBorrowAmount(borrowAmount);
        } else {
            return (0, 0);
        }
    }

    function _getInterestInitialAmount(
        uint256 borrowAmount,
        uint256 initialLoanDuration,
        bool useFixedInterestModel)
        internal
        view
        returns (uint256 interestAmount, uint256 interestRate)
    {
        uint256 assetSupply = totalAssetSupply();
        interestRate = _nextBorrowInterestRate(
            borrowAmount,
            assetSupply,
            useFixedInterestModel
        );

        // initial interestInitialAmount
        interestAmount = borrowAmount
            .mul(interestRate)
            .mul(initialLoanDuration)
            .div(31536000 * 10**20); // 365 * 86400 * 10**20
    }

    function _getNextOwed()
        internal
        view
        returns (address)
    {
        if (nextOwedLender_ != address(0))
            return nextOwedLender_;
        else if (burntTokenReserveList.length != 0)
            return burntTokenReserveList[0].lender;
        else
            return address(0);
    }

    function _claimLoanToken(
        address lender)
        internal
        returns (uint256)
    {
        _settleInterest();

        if (lender == address(0))
            lender = _getNextOwed();

        if (!burntTokenReserveListIndex[lender].isSet)
            return 0;

        uint256 index = burntTokenReserveListIndex[lender].index;
        uint256 assetSupply = _totalAssetSupply(0);
        uint256 currentPrice = _tokenPrice(assetSupply);

        uint256 claimAmount = burntTokenReserveList[index].amount.mul(currentPrice).div(10**18);
        if (claimAmount == 0)
            return 0;

        uint256 availableAmount = ERC20(loanTokenAddress).balanceOf(address(this));
        if (availableAmount == 0) {
            return 0;
        }

        uint256 claimTokenAmount;
        if (claimAmount <= availableAmount) {
            claimTokenAmount = burntTokenReserveList[index].amount;
            _removeFromList(lender, index);
        } else {
            claimAmount = availableAmount;
            claimTokenAmount = claimAmount.mul(10**18).div(currentPrice);

            // prevents less than 10 being left in burntTokenReserveList[index].amount
            if (claimTokenAmount.add(10) < burntTokenReserveList[index].amount) {
                burntTokenReserveList[index].amount = burntTokenReserveList[index].amount.sub(claimTokenAmount);
            } else {
                _removeFromList(lender, index);
            }
        }

        _setInternalSupply(
            assetSupply.sub(claimAmount)
        );

        require(ERC20(loanTokenAddress).transfer(
            lender,
            claimAmount
        ), "20");

        if (burntTokenReserveListIndex[lender].isSet || balances[lender] != 0) {
            checkpointPrices_[lender] = currentPrice;
        } else {
            checkpointPrices_[lender] = 0;
        }

        burntTokenReserved = burntTokenReserved > claimTokenAmount ?
            burntTokenReserved.sub(claimTokenAmount) :
            0;

        emit Claim(
            lender,
            claimTokenAmount,
            claimAmount,
            burntTokenReserveListIndex[lender].isSet ?
                burntTokenReserveList[burntTokenReserveListIndex[lender].index].amount :
                0,
            currentPrice
        );

        return claimAmount;
    }

    function _borrowTokenAndUse(
        uint256 leverageAmount,
        address[3] memory sentAddresses,
        uint256[7] memory sentAmounts,
        bool amountIsADeposit,
        bytes memory loanData)
        internal
        returns (bytes32 loanOrderHash)
    {
        require(sentAmounts[1] != 0, "21"); // amount

        loanOrderHash = loanOrderHashes[leverageAmount];
        require(loanOrderHash != 0, "22");

        _settleInterest();

        bool useFixedInterestModel;
        if (loanData.length != 0) {
            assembly {
                useFixedInterestModel := mload(add(loanData, 1))
            }
        }

        if (amountIsADeposit) {
            (sentAmounts[1], sentAmounts[0]) = _getBorrowAmountAndRate( // borrowAmount, interestRate
                loanOrderHash,
                sentAmounts[1], // amount
                useFixedInterestModel
            );

            // update for borrowAmount
            sentAmounts[6] = sentAmounts[1]; // borrowAmount
        } else {
            // amount is borrow amount
            sentAmounts[0] = _nextBorrowInterestRate( // interestRate
                sentAmounts[1], // amount
                _totalAssetSupply(0),
                useFixedInterestModel
            );
        }

        if (sentAddresses[2] == address(0)) { // tradeTokenAddress
            // tradeTokenSent is ignored if trade token isn't specified
            sentAmounts[5] = 0;
        }

        uint256 borrowAmount = _borrowTokenAndUseFinal(
            loanOrderHash,
            sentAddresses,
            sentAmounts,
            loanData
        );
        require(borrowAmount == sentAmounts[1], "23");
    }

    // returns borrowAmount
    function _borrowTokenAndUseFinal(
        bytes32 loanOrderHash,
        address[3] memory sentAddresses,
        uint256[7] memory sentAmounts,
        bytes memory loanData)
        internal
        returns (uint256)
    {
        sentAmounts[1] = _verifyBorrowAmount(sentAmounts[1]); // borrowAmount
        require (sentAmounts[1] != 0, "24");

        // handle transfers prior to adding borrowAmount to loanTokenSent
        _verifyTransfers(
            sentAddresses,
            sentAmounts
        );

        // adding the loan token amount from the lender to loanTokenSent
        sentAmounts[3] = sentAmounts[3]
            .add(sentAmounts[1]); // borrowAmount

        sentAmounts[1] = IBZx(bZxContract).takeOrderFromiToken( // borrowAmount
            loanOrderHash,
            sentAddresses,
            sentAmounts,
            loanData
        );
        require (sentAmounts[1] != 0, "25");

        // update total borrowed amount outstanding in loans
        totalAssetBorrow = totalAssetBorrow
            .add(sentAmounts[1]); // borrowAmount

        // checkpoint supply since the base protocol borrow stats have changed
        checkpointSupply = _totalAssetSupply(0);

        if (burntTokenReserveList.length != 0) {
            _claimLoanToken(address(0));
            _claimLoanToken(sentAddresses[0]); // borrower
        }

        emit Borrow(
            sentAddresses[0],               // borrower
            sentAmounts[1],                 // borrowAmount
            sentAmounts[0],                 // interestRate
            sentAddresses[1],               // collateralTokenAddress
            sentAddresses[2],               // tradeTokenAddress
            sentAddresses[2] == address(0)  // withdrawOnOpen
        );

        return sentAmounts[1]; // borrowAmount;
    }

    function _verifyBorrowAmount(
        uint256 borrowAmount)
        internal
        view
        returns (uint256)
    {
        uint256 availableToBorrow = ERC20(loanTokenAddress).balanceOf(address(this));
        if (availableToBorrow == 0)
            return 0;

        uint256 reservedSupply = totalReservedSupply();
        if (availableToBorrow > reservedSupply) {
            availableToBorrow = availableToBorrow.sub(reservedSupply);
        } else {
            return 0;
        }

        if (borrowAmount > availableToBorrow) {
            //return availableToBorrow;
            return 0;
        }

        return borrowAmount;
    }

    // sentAddresses[0]: borrower
    // sentAddresses[1]: collateralTokenAddress
    // sentAddresses[2]: tradeTokenAddress
    // sentAmounts[0]: interestRate
    // sentAmounts[1]: borrowAmount
    // sentAmounts[2]: interestInitialAmount
    // sentAmounts[3]: loanTokenSent
    // sentAmounts[4]: collateralTokenSent
    // sentAmounts[5]: tradeTokenSent
    // sentAmounts[6]: withdrawalAmount
    function _verifyTransfers(
        address[3] memory sentAddresses,
        uint256[7] memory sentAmounts)
        internal
    {
        if (sentAddresses[2] == address(0)) { // withdrawOnOpen == true
            require(ERC20(loanTokenAddress).transfer(
                sentAddresses[0],
                sentAmounts[6]
            ), "26");

            if (sentAmounts[1] > sentAmounts[6]) {
                require(ERC20(loanTokenAddress).transfer(
                    bZxVault,
                    sentAmounts[1] - sentAmounts[6]
                ), "34");
            }
        } else {
            require(ERC20(loanTokenAddress).transfer(
                bZxVault,
                sentAmounts[1]
            ), "27");
        }

        if (sentAmounts[4] != 0) {
            if (msg.value != 0) {
                require(sentAddresses[1] == wethContract &&
                    sentAmounts[4] == msg.value, "28");

                WETHInterface(wethContract).deposit.value(sentAmounts[4])();

                require(ERC20(sentAddresses[1]).transfer(
                    bZxVault,
                    sentAmounts[4]
                ), "29");
            } else {
                if (sentAddresses[1] == loanTokenAddress) {
                    sentAmounts[3] = sentAmounts[3].add(sentAmounts[4]);
                } else if (sentAddresses[1] == sentAddresses[2]) {
                    sentAmounts[5] = sentAmounts[5].add(sentAmounts[4]);
                } else {
                    require(ERC20(sentAddresses[1]).transferFrom(
                        msg.sender,
                        bZxVault,
                        sentAmounts[4]
                    ), "30");
                }
            }
        }

        if (sentAmounts[3] != 0) {
            if (loanTokenAddress == sentAddresses[2]) {
                sentAmounts[5] = sentAmounts[5].add(sentAmounts[3]);
            } else {
                require(ERC20(loanTokenAddress).transferFrom(
                    msg.sender,
                    bZxVault,
                    sentAmounts[3]
                ), "31");
            }
        }

        if (sentAmounts[5] != 0) {
            require(ERC20(sentAddresses[2]).transferFrom(
                msg.sender,
                bZxVault,
                sentAmounts[5]
            ), "32");
        }
    }

    function _removeFromList(
        address lender,
        uint256 index)
        internal
    {
        // remove lender from burntToken list
        if (burntTokenReserveList.length > 1) {
            // replace item in list with last item in array
            burntTokenReserveList[index] = burntTokenReserveList[burntTokenReserveList.length - 1];

            // update the position of this replacement
            burntTokenReserveListIndex[burntTokenReserveList[index].lender].index = index;
        }

        // trim array and clear storage
        burntTokenReserveList.length--;
        burntTokenReserveListIndex[lender].index = 0;
        burntTokenReserveListIndex[lender].isSet = false;

        if (lender == nextOwedLender_) {
            nextOwedLender_ = address(0);
        }
    }


    /* Internal View functions */

    function _tokenPrice(
        uint256 assetSupply)
        internal
        view
        returns (uint256)
    {
        uint256 totalTokenSupply = totalSupply_.add(burntTokenReserved);

        return totalTokenSupply != 0 ?
            assetSupply
                .mul(10**18)
                .div(totalTokenSupply) : initialPrice;
    }

    function _protocolInterestRate(
        uint256 assetSupply)
        internal
        view
        returns (uint256)
    {
        uint256 interestRate;
        if (totalAssetBorrow != 0) {
            (,uint256 interestOwedPerDay,) = _getAllInterest();
            interestRate = interestOwedPerDay
                .mul(10**20)
                .div(totalAssetBorrow)
                .mul(365)
                .mul(checkpointSupply)
                .div(assetSupply);
        } else {
            interestRate = baseRate;
        }

        return interestRate;
    }

    // next supply interest adjustment
    function _supplyInterestRate(
        uint256 assetSupply)
        public
        view
        returns (uint256)
    {
        if (totalAssetBorrow != 0) {
            return _protocolInterestRate(assetSupply)
                .mul(_utilizationRate(assetSupply))
                .div(10**20);
        } else {
            return 0;
        }
    }

    // next borrow interest adjustment
    function _nextBorrowInterestRate(
        uint256 newBorrowAmount,
        uint256 assetSupply,
        bool useFixedInterestModel)
        internal
        view
        returns (uint256 nextRate)
    {
        uint256 utilRate = _utilizationRate(assetSupply)
            .add(newBorrowAmount != 0 ?
                newBorrowAmount
                .mul(10**20)
                .div(assetSupply) : 0);

        uint256 minRate;
        uint256 maxRate;

        if (utilRate > 90 ether) {
            // scale rate proportionally up to 100%

            utilRate = utilRate.sub(90 ether);
            if (utilRate > 10 ether)
                utilRate = 10 ether;

            maxRate = rateMultiplier
                .add(baseRate)
                .mul(90)
                .div(100);

            nextRate = utilRate
                .mul(SafeMath.sub(100 ether, maxRate))
                .div(10 ether)
                .add(maxRate);
        } else {
            if (useFixedInterestModel && utilRate < 80 ether) {
                // target 80% utilization when loan is fixed-rate and utilization is under 80%
                utilRate = 80 ether;
            }

            if (utilRate >= 50 ether) {
                nextRate = utilRate
                    .mul(rateMultiplier)
                    .div(10**20)
                    .add(baseRate);

                minRate = baseRate;
                maxRate = rateMultiplier
                    .add(baseRate);
            } else {
                (uint256 lowUtilBaseRate, uint256 lowUtilRateMultiplier) = _getLowUtilValues();
                nextRate = utilRate
                    .mul(lowUtilRateMultiplier)
                    .div(10**20)
                    .add(lowUtilBaseRate);

                minRate = lowUtilBaseRate;
                maxRate = lowUtilRateMultiplier
                    .add(lowUtilBaseRate);
            }

            if (nextRate < minRate)
                nextRate = minRate;
            else if (nextRate > maxRate)
                nextRate = maxRate;
        }

        return nextRate;
    }

    function _getAllInterest()
        internal
        view
        returns (
            uint256 interestPaidSoFar,
            uint256 interestOwedPerDay,
            uint256 interestUnPaid)
    {
        // these values don't account for any fees retained by the oracle, so we account for it elsewhere with spreadMultiplier
        (interestPaidSoFar,,interestOwedPerDay,interestUnPaid) = IBZx(bZxContract).getLenderInterestForOracle(
            address(this),
            bZxOracle, // (leave as original value)
            loanTokenAddress // same as interestTokenAddress
        );
    }

    function _getBorrowAmountAndRate(
        bytes32 loanOrderHash,
        uint256 depositAmount,
        bool useFixedInterestModel)
        internal
        view
        returns (uint256 borrowAmount, uint256 interestRate)
    {
        LoanData memory loanData = loanOrderData[loanOrderHash];
        require(loanData.initialMarginAmount != 0, "33");

        interestRate = _nextBorrowInterestRate(
            depositAmount
                .mul(10**20)
                .div(loanData.initialMarginAmount),
            totalAssetSupply(),
            useFixedInterestModel
        );

        // assumes that loan, collateral, and interest token are the same
        borrowAmount = depositAmount
            .mul(10**40)
            .div(_adjustValue(
                interestRate,
                loanData.maxDurationUnixTimestampSec,
                loanData.initialMarginAmount))
            .div(loanData.initialMarginAmount);
    }

    function _adjustValue(
        uint256 interestRate,
        uint256 maxDuration,
        uint256 marginAmount)
        internal
        pure
        returns (uint256)
    {
        return maxDuration != 0 ?
            interestRate
                .mul(10**20)
                .div(31536000) // 86400 * 365
                .mul(maxDuration)
                .div(marginAmount)
                .add(10**20) :
            10**20;
    }

    function _utilizationRate(
        uint256 assetSupply)
        internal
        view
        returns (uint256)
    {
        if (totalAssetBorrow != 0 && assetSupply != 0) {
            // U = total_borrow / total_supply
            return totalAssetBorrow
                .mul(10**20)
                .div(assetSupply);
        } else {
            return 0;
        }
    }

    function _totalAssetSupply(
        uint256 interestUnPaid)
        internal
        view
        returns (uint256 assetSupply)
    {
        if (totalSupply_.add(burntTokenReserved) != 0) {
            uint256 supplyActual = ERC20(loanTokenAddress).balanceOf(address(this))
                .add(totalAssetBorrow)
                .add(interestUnPaid);
            uint256 supplyInternal = _internalSupply();

            assetSupply = supplyActual > supplyInternal ?
                supplyActual :
                supplyInternal;
        }
    }

    function _setInternalSupply(
        uint256 value)
        internal
    {
        bytes32 slot = keccak256("iToken_InternalSupply");
        assembly {
            sstore(slot, value)
        }
    }

    function _internalSupply()
        internal
        view
        returns (uint256 value)
    {
        bytes32 slot = keccak256("iToken_InternalSupply");
        assembly {
            value := sload(slot)
        }
    }

    function _getLowUtilValues()
        internal
        view
        returns (uint256 lowUtilBaseRate, uint256 lowUtilRateMultiplier)
    {
        bytes32 slotLowUtilBaseRate = keccak256("iToken_LowUtilBaseRate");
        bytes32 slotLowUtilRateMultiplier = keccak256("iToken_LowUtilRateMultiplier");
        assembly {
            lowUtilBaseRate := sload(slotLowUtilBaseRate)
            lowUtilRateMultiplier := sload(slotLowUtilRateMultiplier)
        }
    }

    /* Oracle-Only functions */

    // called only by BZxOracle when a loan is partially or fully closed
    function closeLoanNotifier(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition,
        address loanCloser,
        uint256 closeAmount,
        bool /* isLiquidation */)
        public
        onlyOracle
        returns (bool)
    {
        LoanData memory loanData = loanOrderData[loanOrder.loanOrderHash];
        if (loanData.loanOrderHash == loanOrder.loanOrderHash) {

            totalAssetBorrow = totalAssetBorrow > closeAmount ?
                totalAssetBorrow.sub(closeAmount) : 0;

            if (burntTokenReserveList.length != 0) {
                _claimLoanToken(address(0));
            } else {
                _settleInterest();
            }

            if (closeAmount == 0)
                return true;

            // checkpoint supply since the base protocol borrow stats have changed
            checkpointSupply = _totalAssetSupply(0);

            if (loanCloser != loanPosition.trader) {
                if (iTokenizedRegistry(tokenizedRegistry).isTokenType(
                    loanPosition.trader,
                    2 // tokenType=pToken
                )) {
                    (bool success,) = loanPosition.trader.call(
                        abi.encodeWithSignature(
                            "triggerPosition(bool)",
                            !loanPosition.active // openPosition
                        )
                    );
                    success;
                }
            }

            return true;
        } else {
            return false;
        }
    }


    /* Owner-Only functions */

    function updateSettings(
        address settingsTarget,
        bytes memory txnData)
        public
        onlyOwner
    {
        address currentTarget = target_;
        target_ = settingsTarget;

        (bool result,) = address(this).call(txnData);

        uint256 size;
        uint256 ptr;
        assembly {
            size := returndatasize
            ptr := mload(0x40)
            returndatacopy(ptr, 0, size)
            if eq(result, 0) { revert(ptr, size) }
        }

        target_ = currentTarget;

        assembly {
            return(ptr, size)
        }
    }
}
