/*
-----------------------------------------------------------------
FILE INFORMATION
-----------------------------------------------------------------

file:       SelfDestructible.sol
version:    1.2
author:     Anton Jurisevic

date:       2018-05-29

-----------------------------------------------------------------
MODULE DESCRIPTION
-----------------------------------------------------------------

This contract allows an inheriting contract to be destroyed after
its owner indicates an intention and then waits for a period
without changing their mind. All tron contained in the contract
is forwarded to a nominated beneficiary upon destruction.

-----------------------------------------------------------------
*/

pragma solidity 0.5.9;

import './Owned.sol';

/**
 * @title A contract that can be destroyed by its owner after a delay elapses.
 */
contract SelfDestructible is Owned {
	uint256 public initiationTime;
	bool public selfDestructInitiated;
	address public selfDestructBeneficiary;
	uint256 public constant SELFDESTRUCT_DELAY = 4 weeks;

	/**
	 * @dev Constructor
	 * @param _owner The account which controls this contract.
	 */
	constructor(address _owner) public Owned(_owner) {
		require(_owner != address(0), 'Owner must not be zero');
		selfDestructBeneficiary = _owner;
		emit SelfDestructBeneficiaryUpdated(_owner);
	}

	/**
	 * @notice Set the beneficiary address of this contract.
	 * @dev Only the contract owner may call this. The provided beneficiary must be non-null.
	 * @param _beneficiary The address to pay any trx contained in this contract to upon self-destruction.
	 */
	function setSelfDestructBeneficiary(address _beneficiary) external onlyOwner {
		require(_beneficiary != address(0), 'Beneficiary must not be zero');
		selfDestructBeneficiary = _beneficiary;
		emit SelfDestructBeneficiaryUpdated(_beneficiary);
	}

	/**
	 * @notice Begin the self-destruction counter of this contract.
	 * Once the delay has elapsed, the contract may be self-destructed.
	 * @dev Only the contract owner may call this.
	 */
	function initiateSelfDestruct() external onlyOwner {
		initiationTime = now;
		selfDestructInitiated = true;
		emit SelfDestructInitiated(SELFDESTRUCT_DELAY);
	}

	/**
	 * @notice Terminate and reset the self-destruction timer.
	 * @dev Only the contract owner may call this.
	 */
	function terminateSelfDestruct() external onlyOwner {
		initiationTime = 0;
		selfDestructInitiated = false;
		emit SelfDestructTerminated();
	}

	/**
	 * @notice If the self-destruction delay has elapsed, destroy this contract and
	 * remit any tron it owns to the beneficiary address.
	 * @dev Only the contract owner may call this.
	 */
	function selfDestruct() external onlyOwner {
		require(selfDestructInitiated, 'Self Destruct not yet initiated');
		require(initiationTime + SELFDESTRUCT_DELAY < now, 'Self destruct delay not met');
		address beneficiary = selfDestructBeneficiary;
		address payable _beneficiary = address(uint160(beneficiary));

		emit SelfDestructed(beneficiary);
		selfdestruct(_beneficiary);
	}

	event SelfDestructTerminated();
	event SelfDestructed(address _beneficiary);
	event SelfDestructInitiated(uint256 selfDestructDelay);
	event SelfDestructBeneficiaryUpdated(address newBeneficiary);
}
