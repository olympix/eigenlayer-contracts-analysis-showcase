Use Cases:
1. Fork a current deployment on any network, given a config file
    * Use - simulating upgrades/changes to a current deployment
2. Deploy entire system from the current branch to any network
    * Use - integration tests (mainly want to deploy locally)
3. Easily deploy/upgrade _specific_ contracts on any ENV
    * Use - writing deploy/upgrade scripts
    * Note: this should also update that env's config with new addresses

## Mock Command - Release/Upgrade Scripting

```
make release preprod
```

* Generates a script file (`preprod-<GIT_COMMIT_HEAD>.s.sol`) that automatically loads the config for the `preprod` environment
* `make release preprod --test preprod-<GIT_COMMIT_HEAD>.s.sol`: 
    * Run the script in "test mode", forking preprod locally via anvil and simulating the deploy and upgrade steps specified in the script.
    * Aside from helpful console output, this should generate an output file (to a `.gitignored` directory) that shows what the new config values will be after running for real.
* `make release preprod --run preprod-<GIT_COMMIT_HEAD>.s.sol`:
    * Run the script for real, submitting both deploy and upgrade transactions to preprod, then updating the preprod config with the new addresses
    * If `holesky` or `mainnet` environments are used here, the `upgrade` step should generate multisig transactions that can be signed

## Mock Command - Deploying

```
make deploy preprod
```

* Deploys the entire system to `preprod` using the `DeployAll` script
* Generates an output file that gives the config for this new system. This is generated to a `.gitignored` directory, but if moved into the `config` folder, it can become a named, usable environment

