// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Executables } from "scripts/Executables.sol";
import { EIP1967Helper } from "test/mocks/EIP1967Helper.sol";
import { IAddressManager } from "scripts/interfaces/IAddressManager.sol";
import { LibString } from "solady/utils/LibString.sol";
import { Artifacts, Deployment } from "scripts/Artifacts.s.sol";
import { Config } from "scripts/Config.sol";

/// @notice Contains information about a storage slot. Mirrors the layout of the storage
///         slot object in Forge artifacts so that we can deserialize JSON into this struct.
struct StorageSlot {
    uint256 astId;
    string _contract;
    string label;
    uint256 offset;
    string slot;
    string _type;
}

/// @title Deployer
/// @author tynes
/// @notice A contract that can make deploying and interacting with deployments easy.
abstract contract Deployer is Script, Artifacts {
    /// @notice Sets up the artifacts contract.
    function setUp() public virtual override {
        Artifacts.setUp();
    }

    /// @notice Returns the name of the deployment script. Children contracts
    ///         must implement this to ensure that the deploy artifacts can be found.
    ///         This should be the same as the name of the script and is used as the file
    ///         name inside of the `broadcast` directory when looking up deployment artifacts.
    function name() public pure virtual returns (string memory);

    /// @notice Removes the semantic versioning from a contract name. The semver will exist if the contract is compiled
    /// more than once with different versions of the compiler.
    function _stripSemver(string memory _name) internal returns (string memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(
            Executables.echo, " ", _name, " | ", Executables.sed, " -E 's/[.][0-9]+\\.[0-9]+\\.[0-9]+//g'"
        );
        bytes memory res = vm.ffi(cmd);
        return string(res);
    }

    /// @notice Builds the fully qualified name of a contract. Assumes that the
    ///         file name is the same as the contract name but strips semver for the file name.
    function _getFullyQualifiedName(string memory _name) internal returns (string memory) {
        string memory sanitized = _stripSemver(_name);
        return string.concat(sanitized, ".sol:", _name);
    }

    /// @notice Returns the storage layout for a deployed contract.
    function getStorageLayout(string memory _name) public returns (string memory layout_) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.jq, " -r '.storageLayout' < ", _getForgeArtifactPath(_name));
        bytes memory res = vm.ffi(cmd);
        layout_ = string(res);
    }

    /// @notice Returns the abi from a the forge artifact
    function getAbi(string memory _name) public returns (string memory abi_) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.jq, " -r '.abi' < ", _getForgeArtifactPath(_name));
        bytes memory res = vm.ffi(cmd);
        abi_ = string(res);
    }

    /// @notice Returns the methodIdentifiers from the forge artifact
    function getMethodIdentifiers(string memory _name) public returns (string[] memory ids_) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.jq, " '.methodIdentifiers | keys' < ", _getForgeArtifactPath(_name));
        bytes memory res = vm.ffi(cmd);
        ids_ = stdJson.readStringArray(string(res), "");
    }

    function _getForgeArtifactDirectory(string memory _name) internal returns (string memory dir_) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.forge, " config --json | ", Executables.jq, " -r .out");
        bytes memory res = vm.ffi(cmd);
        string memory contractName = _stripSemver(_name);
        dir_ = string.concat(vm.projectRoot(), "/", string(res), "/", contractName, ".sol");
    }

    /// @notice Returns the filesystem path to the artifact path. If the contract was compiled
    ///         with multiple solidity versions then return the first one based on the result of `ls`.
    function _getForgeArtifactPath(string memory _name) internal returns (string memory) {
        string memory directory = _getForgeArtifactDirectory(_name);
        string memory path = string.concat(directory, "/", _name, ".json");
        if (vm.exists(path)) return path;

        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(
            Executables.ls,
            " -1 --color=never ",
            directory,
            " | ",
            Executables.jq,
            " -R -s -c 'split(\"\n\") | map(select(length > 0))'"
        );
        bytes memory res = vm.ffi(cmd);
        string[] memory files = stdJson.readStringArray(string(res), "");
        return string.concat(directory, "/", files[0]);
    }

    /// @notice Returns the forge artifact given a contract name.
    function _getForgeArtifact(string memory _name) internal returns (string memory) {
        string memory forgeArtifactPath = _getForgeArtifactPath(_name);
        return vm.readFile(forgeArtifactPath);
    }

    /// @dev Pulls the `_initialized` storage slot information from the Forge artifacts for a given contract.
    function getInitializedSlot(string memory _contractName) internal returns (StorageSlot memory slot_) {
        string memory storageLayout = getStorageLayout(_contractName);

        string[] memory command = new string[](3);
        command[0] = Executables.bash;
        command[1] = "-c";
        command[2] = string.concat(
            Executables.echo,
            " '",
            storageLayout,
            "'",
            " | ",
            Executables.jq,
            " '.storage[] | select(.label == \"_initialized\" and .type == \"t_uint8\")'"
        );
        bytes memory rawSlot = vm.parseJson(string(vm.ffi(command)));
        slot_ = abi.decode(rawSlot, (StorageSlot));
    }

    /// @dev Returns the value of the internal `_initialized` storage slot for a given contract.
    function loadInitializedSlot(string memory _contractName) public returns (uint8 initialized_) {
        address contractAddress;
        // Check if the contract name ends with `Proxy` and, if so, get the implementation address
        if (LibString.endsWith(_contractName, "Proxy")) {
            contractAddress = EIP1967Helper.getImplementation(getAddress(_contractName));
            _contractName = LibString.slice(_contractName, 0, bytes(_contractName).length - 5);
            // If the EIP1967 implementation address is 0, we try to get the implementation address from legacy
            // AddressManager, which would work if the proxy is ResolvedDelegateProxy like L1CrossDomainMessengerProxy.
            if (contractAddress == address(0)) {
                contractAddress =
                    IAddressManager(mustGetAddress("AddressManager")).getAddress(string.concat("OVM_", _contractName));
            }
        } else {
            contractAddress = mustGetAddress(_contractName);
        }
        StorageSlot memory slot = getInitializedSlot(_contractName);
        bytes32 slotVal = vm.load(contractAddress, bytes32(vm.parseUint(slot.slot)));
        initialized_ = uint8((uint256(slotVal) >> (slot.offset * 8)) & 0xFF);
    }
}
