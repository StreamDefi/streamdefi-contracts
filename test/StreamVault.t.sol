// SPDX-License-Identifier: MIT
pragma solidity =0.8.4;

import "forge-std/Test.sol";
import {StreamVault} from "../src/StreamVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Vault} from "../src/lib/Vault.sol";
import "forge-std/console.sol";

/*
  VAULT STATE
  ===========
  Deposit Receipts [{round, amount, unredeemedShares}]
  Round Price Per Share 
  Withdrawals [{round, shares}]
  Vault Params {decimals, asset, minimumSupply, cap}
  Vault State
    - round
    - lockedAmount
    - lastLockedAmount
    - totalPending
    - queuedWithdrawShares
  Last Queued Withdraw Amount
  Current Queued Withdraw Shares
 */

contract StreamVaultTest is Test {
    StreamVault vault;
    MockERC20 weth;
    MockERC20 dummyAsset;

    address depositer1;
    address depositer2;
    address depositer3;
    address depositer4;
    address depositer5;
    address depositer6;
    address depositer7;
    address depositer8;
    address depositer9;
    address depositer10;

    address[] depositors;

    address keeper;
    address keeper2;
    address owner;
    uint104 vaultCap;
    uint56 minSupply;
    uint256 singleShare = 10 ** 18;

    struct StateChecker {
        uint16 round;
        uint104 lockedAmount;
        uint104 lastLockedAmount;
        uint128 totalPending;
        uint128 queuedWithdrawShares;
        uint256 lastQueuedWithdrawAmount;
        uint256 currentQueuedWithdrawShares;
        uint256 totalShareSupply;
        uint256 currentRoundPricePerShare;
    }

    struct DepositReceiptChecker {
        address depositer;
        uint16 round;
        uint104 amount;
        uint128 unredeemedShares;
    }

    struct WithdrawalReceiptChecker {
        address withdrawer;
        uint16 round;
        uint256 shares;
    }

    function setUp() public {
        depositer1 = vm.addr(1);
        depositer2 = vm.addr(2);
        depositer3 = vm.addr(3);
        depositer4 = vm.addr(4);
        depositer5 = vm.addr(5);
        depositer6 = vm.addr(6);
        depositer7 = vm.addr(7);
        depositer8 = vm.addr(8);
        depositer9 = vm.addr(9);
        depositer10 = vm.addr(10);
        keeper = vm.addr(11);
        owner = vm.addr(12);
        keeper2 = vm.addr(13);

        depositors = [
            depositer1,
            depositer2,
            depositer3,
            depositer4,
            depositer5,
            depositer6,
            depositer7,
            depositer8,
            depositer9,
            depositer10
        ];
        weth = new MockERC20("wrapped ether", "WETH");
        dummyAsset = new MockERC20("dummy asset", "DUMMY");
        vaultCap = uint104(10000000 * (10 ** 18));
        minSupply = 0.001 ether;

        // valt cap of 10M WETH
        Vault.VaultParams memory vaultParams = Vault.VaultParams({
            decimals: 18,
            asset: address(weth),
            minimumSupply: minSupply,
            cap: vaultCap
        });

        vm.prank(owner);
        vault = new StreamVault(
            address(weth),
            keeper,
            "StreamVault",
            "SV",
            vaultParams
        );

        // fund deposirs with 1000 WETH and 100 ETH each and approve vault
        for (uint256 i = 0; i < depositors.length; i++) {
            vm.startPrank(depositors[i]);
            weth.mint(depositors[i], 1000 * (10 ** 18));
            weth.approve(address(vault), 1000 * (10 ** 18));
            vm.deal(depositors[i], 100 * (10 ** 18));
            vm.stopPrank();
        }
    }

    /************************************************
     *  SINGLE DEPOSIT TESTS
     ***********************************************/
    function test_singleDepositETH() public {
        uint104 depositAmount = 1 ether;

        vm.startPrank(depositer1);
        // deposit 1 ETH
        vault.depositETH{value: depositAmount}();

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );
        assertVaultState(StateChecker(1, 0, 0, depositAmount, 0, 0, 0, 0, 0));

        assertEq(weth.balanceOf(address(vault)), depositAmount);
        vm.stopPrank();
    }

    /************************************************
     *  MULTI DEPOSIT TESTS
     ***********************************************/
    function test_multiDepositETH() public {
        uint104 depositAmount = 1 ether;
        for (uint256 i = 0; i < depositors.length; i++) {
            vm.startPrank(depositors[i]);
            vault.depositETH{value: depositAmount}();
            assertDepositReceipt(
                DepositReceiptChecker(depositors[i], 1, depositAmount, 0)
            );

            assertEq(weth.balanceOf(address(vault)), depositAmount * (i + 1));
            vm.stopPrank();
        }

        assertVaultState(
            StateChecker(
                1,
                0,
                0,
                uint128(depositAmount * depositors.length),
                0,
                0,
                0,
                0,
                0
            )
        );
    }

    /************************************************
     *  SINGLE  ROLLOVER TESTS
     ***********************************************/

    function test_singleDepositWETHRollover() public {
        // deposit
        uint104 depositAmount = 1 ether;
        vm.startPrank(depositer1);
        vault.depositETH{value: depositAmount}();

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );
        assertVaultState(StateChecker(1, 0, 0, depositAmount, 0, 0, 0, 0, 0));
        assertEq(weth.balanceOf(address(vault)), depositAmount);
        vm.stopPrank();

        // rollover
        vm.startPrank(keeper);
        vault.rollToNextRound(
            weth.balanceOf(address(vault)) + weth.balanceOf(address(keeper))
        );
        vm.stopPrank();
        // totalLocked amount should be 1 eth and price per share should be 1
        // totalShare amount should be 1 eth
        assertVaultState(
            StateChecker(
                2,
                depositAmount,
                0,
                0,
                0,
                0,
                0,
                depositAmount,
                depositAmount
            )
        );

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(weth.balanceOf(address(keeper)), depositAmount);
    }

    /************************************************
     *  MULTI  ROLLOVER TESTS
     ***********************************************/

    function test_multiDepositETHRollover() public {
        // deposit
        uint104 depositAmount = 1 ether;
        for (uint256 i = 0; i < depositors.length; i++) {
            vm.startPrank(depositors[i]);
            vault.depositETH{value: depositAmount}();
            assertDepositReceipt(
                DepositReceiptChecker(depositors[i], 1, depositAmount, 0)
            );

            assertEq(weth.balanceOf(address(vault)), depositAmount * (i + 1));
            vm.stopPrank();
        }

        assertVaultState(
            StateChecker(
                1,
                0,
                0,
                uint128(depositAmount * depositors.length),
                0,
                0,
                0,
                0,
                0
            )
        );

        // rollover
        vm.startPrank(keeper);
        vault.rollToNextRound(
            weth.balanceOf(address(vault)) + weth.balanceOf(address(keeper))
        );
        vm.stopPrank();

        // totalLocked amount should be 1 eth and price per share should be 1
        // totalShare amount should be 1 eth
        assertVaultState(
            StateChecker(
                2,
                uint104(depositAmount * depositors.length),
                0,
                0,
                0,
                0,
                0,
                depositAmount * depositors.length,
                depositAmount
            )
        );

        for (uint i = 0; i < depositors.length; ++i) {
            assertDepositReceipt(
                DepositReceiptChecker(depositors[i], 1, depositAmount, 0)
            );
        }

        assertEq(weth.balanceOf(address(vault)), 0);

        assertEq(
            weth.balanceOf(address(keeper)),
            depositAmount * depositors.length
        );
    }

    /************************************************
     *  SINGLE  WITHDRAW TESTS
     ***********************************************/

    function test_singleInstantWithdrawETH() public {
        uint104 depositAmount = 1 ether;

        vm.startPrank(depositer1);
        // deposit 1 WETH
        vault.depositETH{value: depositAmount}();

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );
        assertVaultState(StateChecker(1, 0, 0, depositAmount, 0, 0, 0, 0, 0));
        assertEq(weth.balanceOf(address(vault)), depositAmount);

        // instant withdraw
        vault.withdrawInstantly(depositAmount);
        assertDepositReceipt(DepositReceiptChecker(depositer1, 1, 0, 0));
        assertVaultState(StateChecker(1, 0, 0, 0, 0, 0, 0, 0, 0));

        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(address(depositer1).balance, 100 * (10 ** 18));

        vm.stopPrank();
    }

    function test_singleInitiateWithdrawFull() public {
        uint104 depositAmount = 1 ether;

        vm.startPrank(depositer1);
        // deposit 1 WETH
        vault.depositETH{value: depositAmount}();

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );
        assertVaultState(StateChecker(1, 0, 0, depositAmount, 0, 0, 0, 0, 0));
        assertEq(weth.balanceOf(address(vault)), depositAmount);

        vm.stopPrank();

        vm.startPrank(keeper);
        vault.rollToNextRound(
            weth.balanceOf(address(vault)) + weth.balanceOf(address(keeper))
        );
        vm.stopPrank();
        vm.startPrank(depositer1);
        vault.initiateWithdraw(depositAmount);

        assertWithdrawalReceipt(
            WithdrawalReceiptChecker(depositer1, 2, depositAmount)
        );
        assertEq(vault.balanceOf(address(vault)), depositAmount);
    }

    function test_singleInitaiteWithdrawPartly() public {
        uint104 depositAmount = 1 ether;

        vm.startPrank(depositer1);
        // deposit 1 WETH
        vault.depositETH{value: depositAmount}();

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );
        assertVaultState(StateChecker(1, 0, 0, depositAmount, 0, 0, 0, 0, 0));
        assertEq(weth.balanceOf(address(vault)), depositAmount);

        vm.stopPrank();

        vm.startPrank(keeper);
        vault.rollToNextRound(
            weth.balanceOf(address(vault)) + weth.balanceOf(address(keeper))
        );
        vm.stopPrank();
        vm.startPrank(depositer1);
        vault.initiateWithdraw(depositAmount / 2);

        assertWithdrawalReceipt(
            WithdrawalReceiptChecker(depositer1, 2, depositAmount / 2)
        );
        assertEq(vault.balanceOf(address(vault)), depositAmount / 2);
    }

    function test_singleCompleteWithdraw() public {
        uint104 depositAmount = 1 ether;

        vm.startPrank(depositer1);
        // deposit 1 WETH
        vault.depositETH{value: depositAmount}();

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );
        assertVaultState(StateChecker(1, 0, 0, depositAmount, 0, 0, 0, 0, 0));
        assertEq(weth.balanceOf(address(vault)), depositAmount);

        vm.stopPrank();

        vm.startPrank(keeper);
        vault.rollToNextRound(
            weth.balanceOf(address(vault)) + weth.balanceOf(address(keeper))
        );
        vm.stopPrank();

        assertVaultState(
            StateChecker(
                2,
                depositAmount,
                0,
                0,
                0,
                0,
                0,
                depositAmount,
                depositAmount
            )
        );

        // initiate the withdraw
        vm.startPrank(depositer1);
        vault.initiateWithdraw(depositAmount);
        vm.stopPrank();

        // roll over to next round
        vm.startPrank(keeper);
        weth.transfer(address(vault), depositAmount);
        vault.rollToNextRound(
            weth.balanceOf(address(vault)) + weth.balanceOf(address(keeper))
        );
        vm.stopPrank();

        assertVaultState(
            StateChecker(
                3,
                0,
                depositAmount,
                0,
                depositAmount,
                depositAmount,
                0,
                depositAmount,
                depositAmount
            )
        );

        assertWithdrawalReceipt(
            WithdrawalReceiptChecker(depositer1, 2, depositAmount)
        );

        //complete the withdraw
        vm.startPrank(depositer1);
        vault.completeWithdraw();
        vm.stopPrank();

        assertVaultState(
            StateChecker(3, 0, depositAmount, 0, 0, 0, 0, 0, depositAmount)
        );

        assertEq(weth.balanceOf(address(vault)), 0);

        assertWithdrawalReceipt(WithdrawalReceiptChecker(depositer1, 2, 0));
    }

    /************************************************
     *  MULTI  WITHDRAW TESTS
     ***********************************************/
    function test_multiInitiateWithdraw() public {
        // deposit
        uint104 depositAmount = 1 ether;
        for (uint256 i = 0; i < depositors.length; i++) {
            vm.startPrank(depositors[i]);
            vault.depositETH{value: depositAmount}();
            assertDepositReceipt(
                DepositReceiptChecker(depositors[i], 1, depositAmount, 0)
            );

            assertEq(weth.balanceOf(address(vault)), depositAmount * (i + 1));
            vm.stopPrank();
        }

        assertVaultState(
            StateChecker(
                1,
                0,
                0,
                uint128(depositAmount * depositors.length),
                0,
                0,
                0,
                0,
                0
            )
        );

        // rollover
        vm.startPrank(keeper);
        vault.rollToNextRound(
            weth.balanceOf(address(vault)) + weth.balanceOf(address(keeper))
        );
        vm.stopPrank();

        // totalLocked amount should be 1 eth and price per share should be 1
        // totalShare amount should be 1 eth
        assertVaultState(
            StateChecker(
                2,
                uint104(depositAmount * depositors.length),
                0,
                0,
                0,
                0,
                0,
                depositAmount * depositors.length,
                depositAmount
            )
        );

        for (uint i = 0; i < depositors.length; ++i) {
            vm.startPrank(depositors[i]);
            vault.initiateWithdraw(depositAmount);
            vm.stopPrank();
            assertWithdrawalReceipt(
                WithdrawalReceiptChecker(depositors[i], 2, depositAmount)
            );
        }

        assertEq(
            vault.balanceOf(address(vault)),
            depositAmount * depositors.length
        );
    }

    function test_multiCompleteWithdraw() public {
        uint104 depositAmount = 1 ether;
        for (uint256 i = 0; i < depositors.length; i++) {
            vm.startPrank(depositors[i]);
            vault.depositETH{value: depositAmount}();
            assertDepositReceipt(
                DepositReceiptChecker(depositors[i], 1, depositAmount, 0)
            );

            assertEq(weth.balanceOf(address(vault)), depositAmount * (i + 1));
            vm.stopPrank();
        }

        assertVaultState(
            StateChecker(
                1,
                0,
                0,
                uint128(depositAmount * depositors.length),
                0,
                0,
                0,
                0,
                0
            )
        );

        // rollover
        vm.startPrank(keeper);
        vault.rollToNextRound(
            weth.balanceOf(address(vault)) + weth.balanceOf(address(keeper))
        );
        vm.stopPrank();

        // totalLocked amount should be 1 eth and price per share should be 1
        // totalShare amount should be 1 eth
        assertVaultState(
            StateChecker(
                2,
                uint104(depositAmount * depositors.length),
                0,
                0,
                0,
                0,
                0,
                depositAmount * depositors.length,
                depositAmount
            )
        );

        assertEq(
            weth.balanceOf(address(keeper)),
            depositors.length * depositAmount
        );

        for (uint i = 0; i < depositors.length; ++i) {
            vm.startPrank(depositors[i]);
            vault.initiateWithdraw(depositAmount);
            vm.stopPrank();
            assertWithdrawalReceipt(
                WithdrawalReceiptChecker(depositors[i], 2, depositAmount)
            );
        }

        vm.startPrank(keeper);
        weth.transfer(address(vault), depositAmount * depositors.length);
        vault.rollToNextRound(
            weth.balanceOf(address(vault)) + weth.balanceOf(address(keeper))
        );
        vm.stopPrank();

        assertVaultState(
            StateChecker(
                3,
                0,
                uint104(depositAmount * depositors.length),
                0,
                uint128(depositAmount * depositors.length),
                depositAmount * depositors.length,
                0,
                depositAmount * depositors.length,
                depositAmount
            )
        );

        for (uint i = 0; i < depositors.length; ++i) {
            assertWithdrawalReceipt(
                WithdrawalReceiptChecker(depositors[i], 2, depositAmount)
            );
        }

        //complete the withdraw
        for (uint i = 0; i < depositors.length; ++i) {
            vm.startPrank(depositors[i]);
            vault.completeWithdraw();
            vm.stopPrank();
            assertWithdrawalReceipt(
                WithdrawalReceiptChecker(depositors[i], 2, 0)
            );
        }

        assertVaultState(
            StateChecker(
                3,
                0,
                uint104(depositAmount * depositors.length),
                0,
                0,
                0,
                0,
                0,
                depositAmount
            )
        );

        assertEq(weth.balanceOf(address(vault)), 0);
    }

    /************************************************
     *  CONSTRUCTOR TESTS
     ***********************************************/

    function test_initializesCorrectly(
        address _weth,
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams
    ) public {
        _vaultParams.asset = address(dummyAsset);
        vm.assume(_weth != address(0));
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));

        vm.prank(owner);
        vault = new StreamVault(
            _weth,
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );
        (uint8 decimals, address asset, uint56 _minSupply, uint104 cap) = vault
            .vaultParams();

        assertEq(vault.WETH(), _weth);
        assertEq(vault.keeper(), _keeper);
        assertEq(decimals, _vaultParams.decimals);
        assertEq(asset, address(dummyAsset));
        assertEq(_minSupply, _vaultParams.minimumSupply);
        assertEq(cap, _vaultParams.cap);

        (
            uint16 round,
            uint104 lockedAmount,
            uint104 lastLockedAmount,
            uint128 totalPending,
            uint128 queuedWithdrawShares
        ) = vault.vaultState();

        assertEq(round, 1);
        assertEq(lockedAmount, 0);
        assertEq(totalPending, 0);
        assertEq(queuedWithdrawShares, 0);
        assertEq(lastLockedAmount, 0);

        assertEq(vault.name(), _tokenName);
        assertEq(vault.symbol(), _tokenSymbol);
        assertEq(vault.owner(), owner);
    }

    function test_RevertIfWrappedNativeTokenIsZeroAdr(
        address _weth,
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams
    ) public {
        _vaultParams.asset = address(dummyAsset);
        _weth = address(0);
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));

        vm.startPrank(owner);
        vm.expectRevert("!_weth");
        vault = new StreamVault(
            _weth,
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );
        vm.stopPrank();
    }

    function test_RevertIfKeeperIsZeroAdr(
        address _weth,
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams
    ) public {
        _vaultParams.asset = address(dummyAsset);
        vm.assume(_weth != address(0));
        _keeper = address(0);
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));

        vm.startPrank(owner);
        vm.expectRevert("!_keeper");
        vault = new StreamVault(
            _weth,
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );
        vm.stopPrank();
    }

    function test_RevertIfCapIsZero(
        address _weth,
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams
    ) public {
        _vaultParams.asset = address(dummyAsset);
        vm.assume(_weth != address(0));
        vm.assume(_keeper != address(0));
        _vaultParams.cap = 0;
        vm.assume(_vaultParams.asset != address(0));

        vm.startPrank(owner);
        vm.expectRevert("!_cap");
        vault = new StreamVault(
            _weth,
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );
        vm.stopPrank();
    }

    function test_RevertIfAssetIsZeroAdr(
        address _weth,
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams
    ) public {
        _vaultParams.asset = address(dummyAsset);
        vm.assume(_weth != address(0));
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        _vaultParams.asset = address(0);

        vm.startPrank(owner);
        vm.expectRevert("!_asset");
        vault = new StreamVault(
            _weth,
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );
        vm.stopPrank();
    }

    /************************************************
     *  SET KEEPER TESTS
     ***********************************************/

    function test_RevertWhenSettingKeeperToZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert("!newKeeper");
        vault.setNewKeeper(address(0));
        vm.stopPrank();
        // ensure vault keepers stays the same after attempting to set to zero adr
        assertEq(vault.keeper(), keeper);
    }

    function test_RevertWhenNonOwnerChangesKeeper(address fakeOwner) public {
        vm.assume(fakeOwner != owner);
        vm.startPrank(fakeOwner);
        vm.expectRevert();
        vault.setNewKeeper(keeper2);
        vm.stopPrank();
        // ensure vault keepers stays the same after attempting to set to zero adr
        assertEq(vault.keeper(), keeper);
    }

    function test_settingNewKeeper() public {
        vm.prank(owner);
        vault.setNewKeeper(keeper2);
        assertEq(vault.keeper(), keeper2);
        vm.prank(keeper2);
        vault.rollToNextRound(0);
    }

    function test_RevertIfOldKeeperMakesCallAfterChanged() public {
        vm.prank(owner);
        vault.setNewKeeper(keeper2);
        assertEq(vault.keeper(), keeper2);
        vm.prank(keeper2);
        vault.rollToNextRound(0);
        vm.startPrank(keeper);
        vm.expectRevert("!keeper");
        vault.rollToNextRound(0);
        vm.stopPrank();
    }

    /************************************************
     *  SET CAP TESTING
     ***********************************************/

    function test_RevertIfCapIsSetToZero() public {
        (, , , uint104 cap) = vault.vaultParams();
        vm.startPrank(owner);
        vm.expectRevert("!newCap");
        vault.setCap(0);
        vm.stopPrank();
        // ensure old cap remains
        assertEq(cap, vaultCap);
    }

    function test_RevertIfCapDoesntFitIn104Bits(uint256 newCap) public {
        (, , , uint104 cap) = vault.vaultParams();
        vm.assume(newCap > type(uint104).max);
        vm.startPrank(owner);
        vm.expectRevert();
        vault.setCap(newCap);
        // ensure old cap remains
        assertEq(cap, vaultCap);
    }

    function test_newCapGetsSet(uint104 newCap) public {
        vm.assume(newCap > 0);
        vm.prank(owner);
        vault.setCap(newCap);
        (, , , uint104 cap) = vault.vaultParams();
        assertEq(cap, newCap);
    }

    function test_NonOwnerCannotCallSetCap(
        address fakeOwner,
        uint104 newCap
    ) public {
        (, , , uint104 capBefore) = vault.vaultParams();
        vm.assume(newCap > 0);
        vm.assume(fakeOwner != owner);
        vm.startPrank(fakeOwner);
        vm.expectRevert();
        vault.setCap(newCap);
        vm.stopPrank();
        (, , , uint104 capAfter) = vault.vaultParams();
        assertEq(capBefore, capAfter);
    }

    // test if changing the cap in the middle of the round when the current round balance is already hire than cap
    function test_canSetCapBelowCurrentDeposits() public {
        vm.deal(depositer1, vaultCap);
        vm.prank(depositer1);
        vault.depositETH{value: vaultCap}();
        vm.prank(owner);
        vault.setCap(vaultCap - 1 ether);
        (, , , uint104 cap) = vault.vaultParams();
        assertEq(cap, vaultCap - 1 ether);

        // ensure that the cap worked
        vm.startPrank(depositer2);
        vm.expectRevert();
        vault.depositETH{value: 1 ether}();
        vm.stopPrank();
    }

    /************************************************
     *  INTERNAL DEPOSIT FOR TESTS
     ***********************************************/

    function test_depositReceiptCreatedForNewDepositer(
        uint56 depositAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        assertDepositReceipt(DepositReceiptChecker(depositer1, 0, 0, 0));

        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, uint104(depositAmount), 0)
        );
    }

    function test_depositRecieptIncreasesWhenDepositingSameRound(
        uint56 depositAmount1,
        uint56 depositAmount2
    ) public {
        vm.assume(depositAmount1 > minSupply);
        vm.assume(depositAmount2 > minSupply);
        vm.deal(depositer1, depositAmount1);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount1}();

        assertEq(weth.balanceOf(address(vault)), depositAmount1);

        assertDepositReceipt(
            DepositReceiptChecker(
                depositer1, // depositer
                1, // round
                depositAmount1, // amount
                0 // unredeemed shares
            )
        );

        assertVaultState(
            StateChecker(
                1, // round
                0, // locked amount
                0, // last lockedAmount
                uint128(depositAmount1), // total pending
                0, // queuedWithdrawShares
                0, // lastQueuedWithdrawAmount
                0, // currentQueuedWithdrawShares
                0, // totalShareSupply
                0 // currentRoundPricePerShare
            )
        );
        vm.deal(depositer1, depositAmount2);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount2}();

        assertEq(
            weth.balanceOf(address(vault)),
            uint256(depositAmount2) + uint256(depositAmount1)
        );
        assertDepositReceipt(
            DepositReceiptChecker(
                depositer1,
                1,
                uint104(depositAmount1) + uint104(depositAmount2),
                0
            )
        );

        assertVaultState(
            StateChecker(
                1, // round
                0, // locked amount
                0, // last lockedAmount
                uint128(depositAmount1) + uint128(depositAmount2), // total pending
                0, // queuedWithdrawShares
                0, // lastQueuedWithdrawAmount
                0, // currentQueuedWithdrawShares
                0, // totalShareSupply
                0 // currentRoundPricePerShare
            )
        );
    }

    function test_RevertIfDepositExceedsCap() public {
        vm.deal(depositer1, vaultCap);
        vm.prank(depositer1);
        vault.depositETH{value: vaultCap}();

        assertEq(weth.balanceOf(address(vault)), vaultCap);

        assertDepositReceipt(
            DepositReceiptChecker(
                depositer1, // depositer
                1, // round
                uint104(vaultCap), // amount
                0 // unredeemed shares
            )
        );

        assertVaultState(
            StateChecker(
                1, // round
                0, // locked amount
                0, // last lockedAmount
                uint128(vaultCap), // total pending
                0, // queuedWithdrawShares
                0, // lastQueuedWithdrawAmount
                0, // currentQueuedWithdrawShares
                0, // totalShareSupply
                0 // currentRoundPricePerShare
            )
        );

        vm.deal(depositer1, 1 ether);
        vm.startPrank(depositer1);
        vm.expectRevert("Exceed cap");
        vault.depositETH{value: 1 ether}();
    }

    function test_RevertIfDepositUnderMinSupply() public {
        vm.startPrank(depositer1);
        vm.expectRevert("Insufficient balance");
        vault.depositETH{value: 0.000001 ether}();
    }

    function test_RevertIfTotalPendingDoesntFit128Bits(
        address _weth,
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams
    ) public {
        _vaultParams.cap = type(uint104).max;
        _vaultParams.asset = address(dummyAsset);
        _weth = address(dummyAsset);
        vm.assume(_weth != address(0));
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));

        vm.prank(owner);
        vault = new StreamVault(
            _weth,
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );

        vm.startPrank(depositer1);
        vm.deal(depositer1, type(uint128).max);
        vm.expectRevert("Exceed cap");
        vault.depositETH{value: type(uint128).max}();
    }

    function test_vaultStateMaintainedThroughDeposits(
        uint56 depositAmount1,
        uint56 depositAmount2
    ) public {
        vm.assume(depositAmount1 > minSupply);
        vm.assume(depositAmount2 > minSupply);
        vm.deal(depositer1, depositAmount1);
        vm.deal(depositer2, depositAmount2);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount1}();
        vm.prank(depositer2);
        vault.depositETH{value: depositAmount2}();

        assertEq(
            weth.balanceOf(address(vault)),
            uint256(depositAmount1) + uint256(depositAmount2)
        );
        // should have zero shares minted
        assertEq(vault.balanceOf(address(vault)), 0);

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount1, 0)
        );

        assertDepositReceipt(
            DepositReceiptChecker(depositer2, 1, depositAmount2, 0)
        );

        assertVaultState(
            StateChecker(
                1,
                0,
                0,
                uint128(depositAmount1) + uint128(depositAmount2),
                0,
                0,
                0,
                0,
                0
            )
        );

        vm.prank(keeper);
        vault.rollToNextRound(
            uint256(depositAmount1) + uint256(depositAmount2)
        );

        assertEq(
            weth.balanceOf(keeper),
            uint256(depositAmount1) + uint256(depositAmount2)
        );
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(
            vault.balanceOf(address(vault)),
            uint256(depositAmount1) + uint256(depositAmount2)
        );
        //deposit receipts shouldn't change yet
        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount1, 0)
        );

        assertDepositReceipt(
            DepositReceiptChecker(depositer2, 1, depositAmount2, 0)
        );

        // vault state should change
        assertVaultState(
            StateChecker(
                2,
                uint104(depositAmount1) + uint104(depositAmount2),
                0,
                0,
                0,
                0,
                0,
                uint256(depositAmount1) + uint256(depositAmount2),
                singleShare
            )
        );
    }

    function test_processesDepositFromPrevRound(
        uint56 depositAmount1,
        uint56 depositAmount2
    ) public {
        vm.assume(depositAmount1 > minSupply);
        vm.assume(depositAmount2 > minSupply);
        vm.deal(depositer1, depositAmount1);
        vm.deal(depositer2, depositAmount2);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount1}();
        vm.prank(depositer2);
        vault.depositETH{value: depositAmount2}();

        assertEq(
            weth.balanceOf(address(vault)),
            uint256(depositAmount1) + uint256(depositAmount2)
        );
        // should have zero shares minted
        assertEq(vault.balanceOf(address(vault)), 0);

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount1, 0)
        );

        assertDepositReceipt(
            DepositReceiptChecker(depositer2, 1, depositAmount2, 0)
        );

        assertVaultState(
            StateChecker(
                1,
                0,
                0,
                uint128(depositAmount1) + uint128(depositAmount2),
                0,
                0,
                0,
                0,
                0
            )
        );

        vm.prank(keeper);
        vault.rollToNextRound(
            uint256(depositAmount1) + uint256(depositAmount2)
        );

        assertEq(
            weth.balanceOf(keeper),
            uint256(depositAmount1) + uint256(depositAmount2)
        );
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(
            vault.balanceOf(address(vault)),
            uint256(depositAmount1) + uint256(depositAmount2)
        );
        //deposit receipts shouldn't change yet
        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount1, 0)
        );

        assertDepositReceipt(
            DepositReceiptChecker(depositer2, 1, depositAmount2, 0)
        );

        // vault state should change
        assertVaultState(
            StateChecker(
                2,
                uint104(depositAmount1) + uint104(depositAmount2),
                0,
                0,
                0,
                0,
                0,
                uint256(depositAmount1) + uint256(depositAmount2),
                singleShare
            )
        );

        uint256 secondaryDepositAmt = 1 ether;
        vm.deal(depositer1, secondaryDepositAmt);
        vm.deal(depositer2, secondaryDepositAmt);
        vm.prank(depositer1);
        vault.depositETH{value: secondaryDepositAmt}();
        vm.prank(depositer2);
        vault.depositETH{value: secondaryDepositAmt}();

        assertEq(weth.balanceOf(address(vault)), secondaryDepositAmt * 2);

        assertDepositReceipt(
            DepositReceiptChecker(
                depositer1,
                2,
                uint104(secondaryDepositAmt),
                uint128(depositAmount1)
            )
        );

        assertDepositReceipt(
            DepositReceiptChecker(
                depositer2,
                2,
                uint104(secondaryDepositAmt),
                uint128(depositAmount2)
            )
        );

        assertVaultState(
            StateChecker(
                2,
                uint104(depositAmount1) + uint104(depositAmount2),
                0,
                uint128(secondaryDepositAmt * 2),
                0,
                0,
                0,
                uint256(depositAmount1) + uint256(depositAmount2),
                singleShare
            )
        );
    }

    function test_RevertIfOverflowDepositAmt(
        address _weth,
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams
    ) public {
        _vaultParams.cap = type(uint104).max;
        _vaultParams.asset = address(dummyAsset);
        _weth = address(dummyAsset);
        vm.assume(_weth != address(0));
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));

        vm.prank(owner);
        vault = new StreamVault(
            _weth,
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );
        uint256 depositAmount = uint256(type(uint104).max) + uint256(1 ether);
        vm.deal(depositer1, depositAmount);
        vm.startPrank(depositer1);
        vm.expectRevert();
        vault.depositETH{value: depositAmount}();
    }

    /************************************************
     *  DEPOSIT TESTS
     ***********************************************/

    function test_RevertIfAmountNotGreaterThanZero() public {
        vm.startPrank(depositer1);
        vm.expectRevert("!amount");
        vault.deposit(0);
    }

    function test_vaultReceivesToken(
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams,
        uint56 depositAmount
    ) public {
        _vaultParams.cap = type(uint104).max;
        _vaultParams.asset = address(dummyAsset);
        _vaultParams.minimumSupply = minSupply;
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));
        vm.assume(depositAmount > minSupply);

        vm.prank(owner);
        vault = new StreamVault(
            address(weth),
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );

        dummyAsset.mint(depositer1, depositAmount);

        vm.startPrank(depositer1);
        dummyAsset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount);

        assertEq(dummyAsset.balanceOf(address(vault)), depositAmount);

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );
    }

    function test_RevertsIfInsufficientBalanceToken(
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams,
        uint56 depositAmount
    ) public {
        _vaultParams.cap = type(uint104).max;
        _vaultParams.asset = address(dummyAsset);
        _vaultParams.minimumSupply = minSupply;
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));
        vm.assume(depositAmount > minSupply);

        vm.prank(owner);
        vault = new StreamVault(
            address(weth),
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );

        dummyAsset.mint(depositer1, depositAmount - 1);

        vm.startPrank(depositer1);
        dummyAsset.approve(address(vault), depositAmount - 1);
        vm.expectRevert();
        vault.deposit(depositAmount);
    }

    function test_RevertIfDepositingWrongAsset(
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams,
        uint56 depositAmount
    ) public {
        _vaultParams.cap = type(uint104).max;
        _vaultParams.asset = address(dummyAsset);
        _vaultParams.minimumSupply = minSupply;
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));
        vm.assume(depositAmount > minSupply);

        vm.prank(owner);
        vault = new StreamVault(
            address(weth),
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );

        weth.mint(depositer1, depositAmount);
        vm.startPrank(depositer1);
        weth.approve(address(vault), depositAmount);
        vm.expectRevert();
        vault.deposit(depositAmount);
    }

    /************************************************
     *  EXTERNAL DEPOSIT ETH FOR TESTS
     ***********************************************/
    function test_vaultReceivesDepositETHForOnCreditorBehalf(
        uint56 depositAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        uint256 preCreditorBalance = address(depositer1).balance;
        vm.startPrank(depositer2);
        vm.deal(depositer2, depositAmount);
        vault.depositETHFor{value: depositAmount}(depositer1);

        uint256 postCreditorBalance = address(depositer1).balance;
        assertEq(preCreditorBalance, postCreditorBalance);

        assertEq(weth.balanceOf(address(vault)), depositAmount);

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );

        assertDepositReceipt(DepositReceiptChecker(depositer2, 0, 0, 0));
    }

    function test_RevertIfDepositETHForAmtIsNotGreaterThanZero() public {
        vm.startPrank(depositer2);
        vm.expectRevert("!value");
        vault.depositETHFor{value: 0}(depositer1);
    }

    function test_RevertIfDepositETHForZeroAdr(uint56 depositAmount) public {
        vm.assume(depositAmount > minSupply);

        vm.deal(depositer2, depositAmount);

        vm.startPrank(depositer2);
        dummyAsset.approve(address(vault), depositAmount);
        vm.expectRevert("!creditor");
        vault.depositFor(depositAmount, address(0));
    }

    function test_RevertsIfVaultAssetIsntWETHInDepositForETH(
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams,
        uint56 depositAmount
    ) public {
        _vaultParams.cap = type(uint104).max;
        _vaultParams.asset = address(dummyAsset);
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));
        vm.assume(depositAmount > minSupply);

        vm.prank(owner);
        vault = new StreamVault(
            address(weth),
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );

        vm.deal(depositer2, depositAmount);
        vm.startPrank(depositer2);
        vm.expectRevert("!WETH");
        vault.depositETHFor{value: depositAmount}(depositer1);
    }

    function test_RevertsIfInsufficientBalanceETHInDepositFor(
        uint56 depositAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer2, depositAmount - 1);
        vm.startPrank(depositer2);
        vm.expectRevert();
        vault.depositETHFor{value: depositAmount}(depositer1);
    }

    /************************************************
     *  EXTERNAL DEPOSIT FOR TESTS
     ***********************************************/

    function test_vaultReceivesDepositForTokenOnCreditorBehalf(
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams,
        uint56 depositAmount
    ) public {
        _vaultParams.cap = type(uint104).max;
        _vaultParams.asset = address(dummyAsset);
        _vaultParams.minimumSupply = minSupply;
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));
        vm.assume(depositAmount > minSupply);

        vm.prank(owner);
        vault = new StreamVault(
            address(weth),
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );

        dummyAsset.mint(depositer2, depositAmount);

        uint256 preCreditorBalance = dummyAsset.balanceOf(depositer1);

        vm.startPrank(depositer2);
        dummyAsset.approve(address(vault), depositAmount);
        vault.depositFor(depositAmount, depositer1);

        uint256 postCreditorBalance = dummyAsset.balanceOf(depositer1);
        assertEq(preCreditorBalance, postCreditorBalance);

        assertEq(dummyAsset.balanceOf(address(vault)), depositAmount);

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );
    }

    function test_RevertIfDepositForAmtIsNotGreaterThanZero(
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams
    ) public {
        _vaultParams.cap = type(uint104).max;
        _vaultParams.asset = address(dummyAsset);
        _vaultParams.minimumSupply = minSupply;
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));

        vm.prank(owner);
        vault = new StreamVault(
            address(weth),
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );

        vm.startPrank(depositer2);

        vm.expectRevert("!amount");
        vault.depositFor(0, depositer1);
    }

    function test_RevertIfDepositForZeroAdr(
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams,
        uint56 depositAmount
    ) public {
        _vaultParams.cap = type(uint104).max;
        _vaultParams.asset = address(dummyAsset);
        _vaultParams.minimumSupply = minSupply;
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));
        vm.assume(depositAmount > minSupply);

        vm.prank(owner);
        vault = new StreamVault(
            address(weth),
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );

        dummyAsset.mint(depositer2, depositAmount);

        vm.startPrank(depositer2);
        dummyAsset.approve(address(vault), depositAmount);
        vm.expectRevert("!creditor");
        vault.depositFor(depositAmount, address(0));
    }

    function test_RevertsIfInsufficientBalanceTokenInDepositFor(
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams,
        uint56 depositAmount
    ) public {
        _vaultParams.cap = type(uint104).max;
        _vaultParams.asset = address(dummyAsset);
        _vaultParams.minimumSupply = minSupply;
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));
        vm.assume(depositAmount > minSupply);

        vm.prank(owner);
        vault = new StreamVault(
            address(weth),
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );

        dummyAsset.mint(depositer2, depositAmount - 1);

        vm.startPrank(depositer2);
        dummyAsset.approve(address(vault), depositAmount - 1);
        vm.expectRevert();
        vault.depositFor(depositAmount, depositer1);
    }

    function test_RevertIfDepositingWrongAssetInDepositFor(
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams,
        uint56 depositAmount
    ) public {
        _vaultParams.cap = type(uint104).max;
        _vaultParams.asset = address(dummyAsset);
        _vaultParams.minimumSupply = minSupply;
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));
        vm.assume(depositAmount > minSupply);

        vm.prank(owner);
        vault = new StreamVault(
            address(weth),
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );

        weth.mint(depositer2, depositAmount);
        vm.startPrank(depositer2);
        weth.approve(address(vault), depositAmount);
        vm.expectRevert();
        vault.depositFor(depositAmount, depositer1);
    }

    /************************************************
     *  DEPOSIT ETH TESTS
     ***********************************************/

    function test_RevertsIfVaultAssetIsntWETH(
        address _keeper,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams memory _vaultParams,
        uint56 depositAmount
    ) public {
        _vaultParams.cap = type(uint104).max;
        _vaultParams.asset = address(dummyAsset);
        vm.assume(_keeper != address(0));
        vm.assume(_vaultParams.cap > 0);
        vm.assume(_vaultParams.asset != address(0));
        vm.assume(depositAmount > minSupply);

        vm.prank(owner);
        vault = new StreamVault(
            address(weth),
            _keeper,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );

        vm.deal(depositer1, depositAmount);
        vm.startPrank(depositer1);
        vm.expectRevert("!WETH");
        vault.depositETH{value: depositAmount}();
    }

    function test_RevertIfValueNotGreaterThanZero() public {
        vm.startPrank(depositer1);
        vm.expectRevert("!value");
        vault.depositETH{value: 0}();
    }

    function test_vaultReceivesWETH(uint56 depositAmount) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        assertEq(weth.balanceOf(address(vault)), depositAmount);
        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );
    }

    function test_RevertsIfInsufficientBalanceETH(uint56 depositAmount) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount - 1);
        vm.startPrank(depositer1);
        vm.expectRevert();
        vault.depositETH{value: depositAmount}();
    }

    /************************************************
     *  SHARES GETTER TESTS
     ***********************************************/

    function test_returnsUnredeemedSharesSingle(uint56 depositAmount) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        // shouldn't have any shares until round rollover
        assertEq(vault.shares(depositer1), 0);

        vm.prank(keeper);
        vault.rollToNextRound(depositAmount);

        // should now have shares
        assertEq(vault.shares(depositer1), depositAmount);
    }

    function test_returnUnredeemedSharesMultiple(
        uint56[5] memory depositAmounts
    ) public {
        uint256 totalAmount;
        for (uint i = 0; i < 5; ++i) {
            vm.assume(depositAmounts[i] > minSupply);
            vm.deal(depositors[i], depositAmounts[i]);
            vm.prank(depositors[i]);
            vault.depositETH{value: depositAmounts[i]}();
            totalAmount += uint256(depositAmounts[i]);
        }

        for (uint i = 0; i < 5; ++i) {
            assertEq(vault.shares(depositors[i]), 0);
        }

        vm.prank(keeper);
        vault.rollToNextRound(totalAmount);

        uint256 pricePerShare = vault.roundPricePerShare(1);

        for (uint i = 0; i < 5; ++i) {
            assertEq(
                (uint256(depositAmounts[i]) * (10 ** 18)) / pricePerShare,
                vault.shares(depositors[i])
            );
        }
    }

    function test_returnsRedeemedSharesSingle(uint56 depositAmount) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        // shouldn't have any shares until round rollover
        assertEq(vault.shares(depositer1), 0);

        vm.prank(keeper);
        vault.rollToNextRound(depositAmount);

        vm.prank(depositer1);
        vault.maxRedeem();

        assertEq(vault.shares(depositer1), depositAmount);
    }

    function test_returnsRedeemedSharesMultiple(
        uint56[5] memory depositAmounts
    ) public {
        uint256 totalAmount;
        for (uint i = 0; i < 5; ++i) {
            vm.assume(depositAmounts[i] > minSupply);
            vm.deal(depositors[i], depositAmounts[i]);
            vm.prank(depositors[i]);
            vault.depositETH{value: depositAmounts[i]}();
            totalAmount += uint256(depositAmounts[i]);
        }

        for (uint i = 0; i < 5; ++i) {
            assertEq(vault.shares(depositors[i]), 0);
        }

        vm.prank(keeper);
        vault.rollToNextRound(totalAmount);

        for (uint i = 0; i < 5; ++i) {
            vm.prank(depositors[i]);
            vault.maxRedeem();
        }

        uint256 pricePerShare = vault.roundPricePerShare(1);

        for (uint i = 0; i < 5; ++i) {
            assertEq(
                (uint256(depositAmounts[i]) * (10 ** 18)) / pricePerShare,
                vault.shares(depositors[i])
            );
        }
    }

    function test_returnsUnredeemedAndRedeemedSharesSingle(
        uint56 depositAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        // shouldn't have any shares until round rollover
        assertEq(vault.shares(depositer1), 0);

        vm.prank(keeper);
        vault.rollToNextRound(depositAmount);

        vm.prank(depositer1);
        vault.maxRedeem();

        assertEq(vault.shares(depositer1), depositAmount);

        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        vm.startPrank(keeper);
        weth.transfer(address(vault), depositAmount);
        vault.rollToNextRound(uint256(depositAmount) * 2);
        vm.stopPrank();

        assertEq(vault.shares(depositer1), uint256(depositAmount) * 2);
    }

    function test_returnsUnredeemedAndRedeemedSharesMultiple(
        uint56[5] memory depositAmounts
    ) public {
        uint256 totalAmount;
        for (uint i = 0; i < 5; ++i) {
            vm.assume(depositAmounts[i] > minSupply);
            vm.deal(depositors[i], depositAmounts[i]);
            vm.prank(depositors[i]);
            vault.depositETH{value: depositAmounts[i]}();
            totalAmount += uint256(depositAmounts[i]);
        }

        for (uint i = 0; i < 5; ++i) {
            assertEq(vault.shares(depositors[i]), 0);
        }

        vm.prank(keeper);
        vault.rollToNextRound(totalAmount);

        for (uint i = 0; i < 5; ++i) {
            vm.prank(depositors[i]);
            vault.maxRedeem();
        }

        uint256 pricePerShare = vault.roundPricePerShare(1);

        for (uint i = 0; i < 5; ++i) {
            assertEq(
                (uint256(depositAmounts[i]) * (10 ** 18)) / pricePerShare,
                vault.shares(depositors[i])
            );
        }

        for (uint i = 0; i < 5; ++i) {
            vm.deal(depositors[i], depositAmounts[i]);
            vm.prank(depositors[i]);
            vault.depositETH{value: depositAmounts[i]}();
        }

        vm.startPrank(keeper);
        weth.transfer(address(vault), totalAmount);
        vault.rollToNextRound(totalAmount * 2);
        vm.stopPrank();

        pricePerShare = vault.roundPricePerShare(2);

        for (uint i = 0; i < 5; ++i) {
            assertEq(
                (uint256(depositAmounts[i]) * 2 * (10 ** 18)) / pricePerShare,
                vault.shares(depositors[i])
            );
        }
    }

    function test_returnsSharesAfterDoubleDeposit(uint56 depositAmount) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        // shouldn't have any shares until round rollover
        assertEq(vault.shares(depositer1), 0);

        vm.prank(keeper);
        vault.rollToNextRound(depositAmount);

        vm.prank(depositer1);
        vault.maxRedeem();

        assertEq(vault.shares(depositer1), depositAmount);

        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        vm.startPrank(keeper);
        weth.transfer(address(vault), depositAmount);
        vault.rollToNextRound(uint256(depositAmount) * 2);
        vm.stopPrank();

        assertEq(vault.shares(depositer1), uint256(depositAmount) * 2);

        vm.deal(depositer1, 1 ether);
        vm.prank(depositer1);
        vault.depositETH{value: 1 ether}();

        assertEq(vault.shares(depositer1), uint256(depositAmount) * 2);
    }

    /************************************************
     *  WITHDRAW INSTANTLY TESTS
     ***********************************************/

    function test_RevertsIfAmountIsNotGreaterThanZero() public {
        uint256 depositAmount = 1 ether;
        vm.deal(depositer1, depositAmount);
        vm.startPrank(depositer1);
        vault.depositETH{value: depositAmount}();

        vm.expectRevert("!amount");
        vault.withdrawInstantly(0);
    }

    function test_RevertsIfInstantWithdrawExceedsDepositAmount(
        uint56 depositAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.deal(depositer1, depositAmount);
        vm.startPrank(depositer1);
        vault.depositETH{value: depositAmount}();

        vm.expectRevert("Exceed amount");
        vault.withdrawInstantly(uint256(depositAmount) + 1);
    }

    function test_RevertsIfAttemptingInstantWithdrawInPrevRound(
        uint56 depositAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        vm.prank(keeper);
        vault.rollToNextRound(depositAmount);

        vm.startPrank(depositer1);
        vm.expectRevert("Invalid round");
        vault.withdrawInstantly(depositAmount);
    }

    function test_fullInstantWithdrawUpdatesDepositReceipt(
        uint56 depositAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );

        vm.prank(depositer1);
        vault.withdrawInstantly(depositAmount);

        assertDepositReceipt(DepositReceiptChecker(depositer1, 1, 0, 0));
    }

    function test_partialInstantWIthdrawUpdatesDepositReceipt() public {
        uint104 depositAmount = 1 ether;

        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount, 0)
        );

        vm.prank(depositer1);
        vault.withdrawInstantly(depositAmount / 2);

        assertDepositReceipt(
            DepositReceiptChecker(depositer1, 1, depositAmount / 2, 0)
        );
    }

    function test_fullInstantWithdrawUpdatesTotalPending(
        uint56 depositAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        (, , , uint128 totalPending, ) = vault.vaultState();
        assertEq(totalPending, depositAmount);

        vm.prank(depositer1);
        vault.withdrawInstantly(depositAmount);

        (, , , totalPending, ) = vault.vaultState();
        assertEq(totalPending, 0);
    }

    function test_partialInstantWithdrawUpdatesTotalPending() public {
        uint104 depositAmount = 1 ether;

        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        (, , , uint128 totalPending, ) = vault.vaultState();
        assertEq(totalPending, depositAmount);

        vm.prank(depositer1);
        vault.withdrawInstantly(depositAmount / 2);
        (, , , totalPending, ) = vault.vaultState();
        assertEq(totalPending, depositAmount / 2);
    }

    function test_fullInstantWithdrawUpdatesBalancesProperly(
        uint56 depositAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();
        assertEq(address(depositer1).balance, 0);
        assertEq(weth.balanceOf(address(vault)), depositAmount);

        vm.prank(depositer1);
        vault.withdrawInstantly(depositAmount);

        assertEq(address(depositer1).balance, depositAmount);
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    function test_partialInstantWithdrawUpdatesBalancesProperly() public {
        uint104 depositAmount = 1 ether;

        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        assertEq(address(depositer1).balance, 0);
        assertEq(weth.balanceOf(address(vault)), depositAmount);

        vm.prank(depositer1);
        vault.withdrawInstantly(depositAmount / 2);

        assertEq(address(depositer1).balance, depositAmount / 2);
        assertEq(weth.balanceOf(address(vault)), depositAmount / 2);
    }

    /************************************************
     *  INITIATE WITHDRAW TESTS
     ***********************************************/

    function test_RevertIfInitatingZeroShareWithdraw(
        uint56 depositAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        vm.prank(keeper);
        vault.rollToNextRound(depositAmount);

        vm.startPrank(depositer1);
        vm.expectRevert("!numShares");
        vault.initiateWithdraw(0);
    }

    function test_maxRedeemsIfDepositerHasUnredeemedShares(
        uint56 depositAmount,
        uint56 withdrawAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.assume(withdrawAmount < depositAmount);
        vm.assume(withdrawAmount > 0);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        vm.prank(keeper);
        vault.rollToNextRound(depositAmount);

        assertEq(vault.balanceOf(address(vault)), depositAmount);

        vm.prank(depositer1);
        vault.initiateWithdraw(withdrawAmount);

        // vault max redeems and transfers back to value the amount withdrawn
        assertEq(vault.balanceOf(depositer1), depositAmount - withdrawAmount);
        assertEq(vault.balanceOf(address(vault)), withdrawAmount);
    }

    function test_RevertIfDepositerHasNoUnreedeemedShares(
        uint56 depositAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.startPrank(depositer1);
        vault.depositETH{value: depositAmount}();
        vm.expectRevert();
        vault.initiateWithdraw(depositAmount);
    }

    function test_withdrawReceiptCreatedForNewWithdraw(
        uint56 depositAmount,
        uint56 withdrawAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.assume(withdrawAmount < depositAmount);
        vm.assume(withdrawAmount > 0);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        vm.prank(keeper);
        vault.rollToNextRound(depositAmount);

        assertWithdrawalReceipt(WithdrawalReceiptChecker(depositer1, 0, 0));

        vm.prank(depositer1);
        vault.initiateWithdraw(withdrawAmount);

        assertWithdrawalReceipt(
            WithdrawalReceiptChecker(depositer1, 2, withdrawAmount)
        );
    }

    function test_doubleWithdrawAddsToWithdrawalReceipt(
        uint56 depositAmount,
        uint56 withdrawAmount1,
        uint56 withdrawAmount2
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.assume(withdrawAmount1 < depositAmount);
        vm.assume(withdrawAmount2 > 0);
        vm.assume(withdrawAmount2 < depositAmount);
        vm.assume(
            uint256(withdrawAmount1) + uint256(withdrawAmount2) <=
                uint256(depositAmount)
        );
        vm.assume(withdrawAmount1 > 0);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        vm.prank(keeper);
        vault.rollToNextRound(depositAmount);

        assertWithdrawalReceipt(WithdrawalReceiptChecker(depositer1, 0, 0));

        vm.prank(depositer1);
        vault.initiateWithdraw(withdrawAmount1);

        assertWithdrawalReceipt(
            WithdrawalReceiptChecker(depositer1, 2, withdrawAmount1)
        );

        vm.prank(depositer1);
        vault.initiateWithdraw(withdrawAmount2);

        assertWithdrawalReceipt(
            WithdrawalReceiptChecker(
                depositer1,
                2,
                withdrawAmount1 + withdrawAmount2
            )
        );
    }

    function test_RevertIfUserHasInsufficientShares(
        uint56 depositAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        vm.prank(keeper);
        vault.rollToNextRound(depositAmount);

        vm.startPrank(depositer1);
        vm.expectRevert();
        vault.initiateWithdraw(depositAmount + 1);
    }

    function test_RevertIfDoubleInitiatingWithdrawInSepRounds() public {
        uint256 depositAmount = 1 ether;
        vm.assume(depositAmount > minSupply);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        vm.prank(keeper);
        vault.rollToNextRound(depositAmount);

        vm.prank(depositer1);
        vault.initiateWithdraw(depositAmount / 2);

        vm.startPrank(keeper);
        weth.transfer(address(vault), depositAmount);
        vault.rollToNextRound(depositAmount);
        vm.stopPrank();

        vm.startPrank(depositer1);
        vm.expectRevert("Existing withdraw");
        vault.initiateWithdraw(depositAmount / 2);
    }

    function test_currentQueuedWithdrawSharesIsMaintained(
        uint56 depositAmount,
        uint56 withdrawAmount
    ) public {
        vm.assume(depositAmount > minSupply);
        vm.assume(withdrawAmount < depositAmount);
        vm.assume(withdrawAmount > 0);
        vm.deal(depositer1, depositAmount);
        vm.prank(depositer1);
        vault.depositETH{value: depositAmount}();

        vm.prank(keeper);
        vault.rollToNextRound(depositAmount);

        assertEq(vault.currentQueuedWithdrawShares(), 0);

        vm.prank(depositer1);
        vault.initiateWithdraw(withdrawAmount);

        assertEq(vault.currentQueuedWithdrawShares(), withdrawAmount);
    }

    /************************************************
     *  HELPER STATE ASSERTIONS
     ***********************************************/

    function assertVaultState(StateChecker memory state) public {
        (
            uint16 round,
            uint104 lockedAmount,
            uint104 lastLockedAmount,
            uint128 totalPending,
            uint128 queuedWithdrawShares
        ) = vault.vaultState();
        uint256 lastQueuedWithdrawAmount = vault.lastQueuedWithdrawAmount();
        uint256 currentQueuedWithdrawShares = vault
            .currentQueuedWithdrawShares();
        uint256 currentRoundPricePerShare;

        if (state.round == 1) {
            currentRoundPricePerShare = vault.roundPricePerShare(round);
        } else {
            currentRoundPricePerShare = vault.roundPricePerShare(round - 1);
        }

        assertEq(round, state.round);

        assertEq(lockedAmount, state.lockedAmount);

        assertEq(lastLockedAmount, state.lastLockedAmount);

        assertEq(totalPending, state.totalPending);

        assertEq(queuedWithdrawShares, state.queuedWithdrawShares);

        assertEq(lastQueuedWithdrawAmount, state.lastQueuedWithdrawAmount);

        assertEq(
            currentQueuedWithdrawShares,
            state.currentQueuedWithdrawShares
        );

        assertEq(currentRoundPricePerShare, state.currentRoundPricePerShare);

        assertEq(vault.totalSupply(), state.totalShareSupply);
    }

    function assertDepositReceipt(DepositReceiptChecker memory receipt) public {
        (uint16 round, uint104 amount, uint128 unredeemedShares) = vault
            .depositReceipts(receipt.depositer);

        assertEq(round, receipt.round);
        assertEq(amount, receipt.amount);
        assertEq(unredeemedShares, receipt.unredeemedShares);
    }

    function assertWithdrawalReceipt(
        WithdrawalReceiptChecker memory receipt
    ) public {
        (uint16 round, uint128 shares) = vault.withdrawals(receipt.withdrawer);

        assertEq(round, receipt.round);
        assertEq(shares, receipt.shares);
    }
}
