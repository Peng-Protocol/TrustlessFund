// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.1 (04/11/2025)
// Changelog:
// - 04/11/2025: Derived from MockKarahTester, removed interface. 

contract MockTrustlessTester {
    address public owner;
    constructor(address _owner) { owner = _owner; }
    receive() external payable {}
    
    event ProxyError(string reason);

    function proxyCall(address target, bytes memory data) external {
        require(msg.sender == owner, "Not owner");
        (bool success, bytes memory returnData) = target.call(data);

        // If the call failed, bubble up the revert reason
        if (!success) {
            if (returnData.length > 0) {
                // Generically forward the revert message using assembly.
                // This will work for Error(string), CustomError(string), or any other revert.
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            } else {
                revert("Proxy failed (no revert data)"); // Fallback
            }
        }
    }
}