// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../harnesses/EigenHarness.sol";

import "../../contracts/token/BackingEigen.sol";
import "../../contracts/token/Eigen.sol";

abstract contract OlympixUnitTest is Test {
    constructor(string memory name_) {}
}

contract OpixEigenTest is OlympixUnitTest("Eigen") {
    mapping(address => bool) fuzzedOutAddresses;

    address minter1 = 0xbb00DDa2832850a43840A3A86515E3Fe226865F2;
    address minter2 = 0x87787389BB2Eb2EC8Fe4aA6a2e33D671d925A60f;

    ProxyAdmin proxyAdmin;

    EigenHarness eigenImpl;
    Eigen eigen;

    BackingEigen bEIGENImpl;
    BackingEigen bEIGEN;

    uint256 totalSupply = 1.67e9 ether;

    // EVENTS FROM EIGEN.sol
    /// @notice event emitted when the allowedFrom status of an address is set
    event SetAllowedFrom(address indexed from, bool isAllowedFrom);
    /// @notice event emitted when the allowedTo status of an address is set
    event SetAllowedTo(address indexed to, bool isAllowedTo);
    /// @notice event emitted when a minter mints
    event Mint(address indexed minter, uint256 amount);
    /// @notice event emitted when the transfer restrictions are disabled
    event TransferRestrictionsDisabled();

    modifier filterAddress(address fuzzedAddress) {
        vm.assume(!fuzzedOutAddresses[fuzzedAddress]);
        _;
    }

    function setUp() public {
        vm.startPrank(minter1);
        proxyAdmin = new ProxyAdmin();

        // deploy proxies
        eigen = Eigen(address(new TransparentUpgradeableProxy(address(proxyAdmin), address(proxyAdmin), "")));
        bEIGEN = BackingEigen(address(new TransparentUpgradeableProxy(address(proxyAdmin), address(proxyAdmin), "")));

        // deploy impls
        eigenImpl = new EigenHarness(IERC20(address(bEIGEN)));
        bEIGENImpl = new BackingEigen(IERC20(address(eigen)));

        // upgrade proxies
        proxyAdmin.upgrade(TransparentUpgradeableProxy(payable(address(eigen))), address(eigenImpl));
        proxyAdmin.upgrade(TransparentUpgradeableProxy(payable(address(bEIGEN))), address(bEIGENImpl));

        vm.stopPrank();

        fuzzedOutAddresses[minter1] = true;
        fuzzedOutAddresses[minter2] = true;
        fuzzedOutAddresses[address(proxyAdmin)] = true;
        fuzzedOutAddresses[address(eigen)] = true;
        fuzzedOutAddresses[address(bEIGEN)] = true;
        fuzzedOutAddresses[address(0)] = true;
    }

    function test_initialize_FailWhenMintersAndMintingAllowancesHaveDifferentLengths() public {
        address[] memory minters = new address[](1);
        minters[0] = minter1;
    
        uint256[] memory mintingAllowances = new uint256[](2);
        mintingAllowances[0] = 1 ether;
        mintingAllowances[1] = 2 ether;
    
        uint256[] memory mintAllowedAfters = new uint256[](1);
        mintAllowedAfters[0] = 0;
    
        vm.expectRevert("Eigen.initialize: minters and mintingAllowances must be the same length");
        eigen.initialize(minter1, minters, mintingAllowances, mintAllowedAfters);
    }

    function test_initialize_FailWhenMintersAndMintAllowedAftersHaveDifferentLengths() public {
        address[] memory minters = new address[](1);
        minters[0] = minter1;
    
        uint256[] memory mintingAllowances = new uint256[](1);
        mintingAllowances[0] = 1 ether;
    
        uint256[] memory mintAllowedAfters = new uint256[](2);
        mintAllowedAfters[0] = 0;
        mintAllowedAfters[1] = 1;
    
        vm.expectRevert("Eigen.initialize: minters and mintAllowedAfters must be the same length");
        eigen.initialize(minter1, minters, mintingAllowances, mintAllowedAfters);
    }

    function test_setAllowedFrom_SuccessfulSetAllowedFrom() public {
        vm.startPrank(minter1);
    
        address[] memory minters = new address[](1);
        minters[0] = minter1;
    
        uint256[] memory mintingAllowances = new uint256[](1);
        mintingAllowances[0] = 1 ether;
    
        uint256[] memory mintAllowedAfters = new uint256[](1);
        mintAllowedAfters[0] = 0;
    
        eigen.initialize(minter1, minters, mintingAllowances, mintAllowedAfters);
    
        eigen.setAllowedFrom(minter1, false);
    
        vm.stopPrank();
    
        assertEq(eigen.allowedFrom(minter1), false);
    }

    function test_setAllowedTo_SuccessfulSetAllowedTo() public {
        vm.startPrank(minter1);
    
        address[] memory minters = new address[](1);
        minters[0] = minter1;
    
        uint256[] memory mintingAllowances = new uint256[](1);
        mintingAllowances[0] = 1 ether;
    
        uint256[] memory mintAllowedAfters = new uint256[](1);
        mintAllowedAfters[0] = 0;
    
        eigen.initialize(minter1, minters, mintingAllowances, mintAllowedAfters);
    
        eigen.setAllowedTo(minter2, true);
    
        vm.stopPrank();
    
        assertTrue(eigen.allowedTo(minter2));
    }

    function test_disableTransferRestrictions_SuccessfulDisable() public {
        address[] memory minters = new address[](1);
        minters[0] = minter1;
    
        uint256[] memory mintingAllowances = new uint256[](1);
        mintingAllowances[0] = 1 ether;
    
        uint256[] memory mintAllowedAfters = new uint256[](1);
        mintAllowedAfters[0] = 0;
    
        vm.startPrank(minter1);
        eigen.initialize(minter1, minters, mintingAllowances, mintAllowedAfters);
        eigen.disableTransferRestrictions();
        vm.stopPrank();
    
        assertEq(eigen.transferRestrictionsDisabledAfter(), 0);
    }

    function test_mint_FailWhenSenderHasNoMintingAllowance() public {
        vm.startPrank(minter2);
    
        vm.expectRevert("Eigen.mint: msg.sender has no minting allowance");
        eigen.mint();
    
        vm.stopPrank();
    }

    function test_mint_FailWhenSenderIsNotAllowedToMintYet() public {
        address[] memory minters = new address[](1);
        minters[0] = minter1;
    
        uint256[] memory mintingAllowances = new uint256[](1);
        mintingAllowances[0] = 1 ether;
    
        uint256[] memory mintAllowedAfters = new uint256[](1);
        mintAllowedAfters[0] = block.timestamp + 1 days;
    
        vm.startPrank(minter1);
        eigen.initialize(minter1, minters, mintingAllowances, mintAllowedAfters);
    
        vm.expectRevert("Eigen.mint: msg.sender is not allowed to mint yet");
        eigen.mint();
        vm.stopPrank();
    }

    function test_mint_SuccessfulMint() public {
        address[] memory minters = new address[](1);
        minters[0] = minter1;
    
        uint256[] memory mintingAllowances = new uint256[](1);
        mintingAllowances[0] = 1 ether;
    
        uint256[] memory mintAllowedAfters = new uint256[](1);
        mintAllowedAfters[0] = 0;
    
        vm.startPrank(minter1);
        eigen.initialize(minter1, minters, mintingAllowances, mintAllowedAfters);
        eigen.mint();
        vm.stopPrank();
    
        assertEq(eigen.balanceOf(minter1), 1 ether);
        assertEq(eigen.mintingAllowance(minter1), 0);
    }

    function test_multisend_FailWhenReceiversAndAmountsHaveDifferentLengths() public {
        address[] memory receivers = new address[](1);
        receivers[0] = minter2;
    
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;
    
        vm.startPrank(minter1);
        vm.expectRevert("Eigen.multisend: receivers and amounts must be the same length");
        eigen.multisend(receivers, amounts);
        vm.stopPrank();
    }

    function test_beforeTokenTransfer_SuccessfulTransferWhenTransferRestrictionsAreDisabled() public {
        address[] memory minters = new address[](1);
        minters[0] = minter1;
    
        uint256[] memory mintingAllowances = new uint256[](1);
        mintingAllowances[0] = 1 ether;
    
        uint256[] memory mintAllowedAfters = new uint256[](1);
        mintAllowedAfters[0] = 0;
    
        vm.startPrank(minter1);
        eigen.initialize(minter1, minters, mintingAllowances, mintAllowedAfters);
        eigen.disableTransferRestrictions();
        eigen.mint();
        eigen.transfer(minter2, 1 ether);
        vm.stopPrank();
    
        assertEq(eigen.balanceOf(minter1), 0);
        assertEq(eigen.balanceOf(minter2), 1 ether);
    }

    function test_CLOCK_MODE_ReturnsTimestampMode() public {
        string memory clockMode = eigen.CLOCK_MODE();
        assertEq(clockMode, "mode=timestamp");
    }
}