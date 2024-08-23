# Olympix analysis results

## Vulnerability analysis/Code scanning
1. Look at the the repo's code scanning results here: On github, open the repo, and go to `Security>Code Scanning`.

# Testing results

## Unit testing
1. In this directory, you can see two test files - `OpixEigen.t.sol` and `OpixDelegationUnit.t.sol`. In both of these files, all the functions that start with `test` were created completely by the AI with no human intervention.
2. For both of these test files, you also have a corresponding test report image in this directory. These contain metrics like the time it took to generate these tests, the amount of credits it took, the percentage increase in branch/line coverage etc.

## Mutation testing
For an overview, look at the attached `mutation-test-report.png` which provides some stats regarding number of mutants, mutant survival rate etc. 
1. You see a csv file `mutation_tests.csv` (which we recommend that you open in a spreadsheet software). This file contains a report of all the mutants, each row in this file in one mutant that was generated. A mutant is said to be "killed" if there exists a test in the test suite that was passing before this mutant was introduced but now starts failing. Higher mutant kill score means that the test suite is more robust at detecting changes.

