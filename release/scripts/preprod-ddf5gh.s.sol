pragma solidity ^0.8.12;

import "src/*";

contract preprod_ddf5gh is DeploymentUtils {

    function deploy() external {
        // Deploy contracts
        EigenPod newPodImpl = new EigenPod(
            cfg.ethPOS,
            cfg.eigenPodManager.proxy,
            cfg.eigenPod.GENESIS_TIME
        );

        EigenPodManager newPodManagerImpl = new EigenPodManager(
            cfg.ethPOS,
            cfg.eigenPod.beacon,
            cfg.strategyManager.proxy,
            cfg.slasher.proxy,
            cfg.delegationManager.proxy
        );

        // Update preprod cfg
        cfg.setImpl(EIGENPOD, address(newPodImpl));
        cfg.setImpl(EIGENPODMANAGER, address(newPodManagerImpl));
    }

    function upgrade() external {
        cfg.upgradeImpl(EIGENPOD);
    }
}