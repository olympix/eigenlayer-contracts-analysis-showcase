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
}

