// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {CustodyChain} from "../src/CustodyChain.sol";

contract CustodyChainTest is Test {
    CustodyChain chain;

    // Wallets criptográficas reales generadas dinámicamente con llave privada para firmas
    Account driver;
    Account client;

    address arbiter1 = address(0x100);
    address arbiter2 = address(0x200);
    address arbiter3 = address(0x300);
    address[] arbiters;

    uint256 payment = 2 ether;
    uint256 collateral = 1 ether;
    bytes32 photoHash = keccak256("initial_package_hash");
    bytes32 deliveryPhotoHash = keccak256("delivered_package_hash");

    function setUp() public {
        driver = makeAccount("driver_wallet");
        client = makeAccount("client_wallet");

        arbiters.push(arbiter1);
        arbiters.push(arbiter2);
        arbiters.push(arbiter3);

        vm.deal(client.addr, 50 ether);
        vm.deal(driver.addr, 50 ether);

        chain = new CustodyChain();
    }

    // --- HELPER DE FIRMAS EIP-191 ---
    function _generateSignature(
        uint256 privateKey,
        bytes32 messageHash
    ) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    // --- HELPER ESTRUCTURAL PARA CAMINO FELIZ ---
    function _setupAndDeliverShipment() internal returns (uint256) {
        vm.prank(client.addr);
        chain.createShipment{value: payment}(
            driver.addr,
            photoHash,
            arbiters,
            2,
            collateral
        );

        vm.prank(driver.addr);
        chain.pickUp{value: collateral}(0);

        vm.prank(driver.addr);
        chain.markInTransit(0);

        bytes32 msgHash = keccak256(
            abi.encodePacked(uint256(0), deliveryPhotoHash)
        );
        bytes memory sig = _generateSignature(driver.key, msgHash);

        vm.prank(driver.addr);
        chain.markDelivered(0, deliveryPhotoHash, sig);
        return 0;
    }

    // ==========================================
    // PRUEBAS DE FLUJO Y COMPORTAMIENTO
    // ==========================================

    function test_HappyPath_NormalFlow() public {
        uint256 id = _setupAndDeliverShipment();
        uint256 driverBalanceBefore = driver.addr.balance;

        bytes32 msgHash = keccak256(abi.encodePacked(id, deliveryPhotoHash));
        bytes memory sig = _generateSignature(client.key, msgHash);

        vm.prank(client.addr);
        chain.confirmReceipt(id, sig);

        assertEq(
            uint(chain.getShipmentState(id)),
            uint(CustodyChain.State.Confirmed)
        );
        assertEq(
            driver.addr.balance,
            driverBalanceBefore + payment + collateral,
            "Driver did not receive pay + deposit"
        );
        assertEq(address(chain).balance, 0, "Vault leak detected");
    }

    function test_SpawnLedger_AutoConfirm() public {
        uint256 id = _setupAndDeliverShipment();
        uint256 driverBalanceBefore = driver.addr.balance;

        // Forzamos el salto temporal más allá de los 30 minutos obligatorios
        vm.warp(block.timestamp + 31 minutes);

        // Cualquier persona puede detonar la escoba automática
        chain.autoConfirm(id);

        assertEq(
            uint(chain.getShipmentState(id)),
            uint(CustodyChain.State.Confirmed)
        );
        assertEq(
            driver.addr.balance,
            driverBalanceBefore + payment + collateral
        );
    }

    function test_Multisig_DisputeResolvedForClient() public {
        uint256 id = _setupAndDeliverShipment();
        uint256 clientBalanceBefore = client.addr.balance;

        bytes32 msgHash = keccak256(abi.encodePacked(id, "Box is broken"));
        bytes memory sig = _generateSignature(client.key, msgHash);

        vm.prank(client.addr);
        chain.dispute(id, "Box is broken", sig);

        assertEq(
            uint(chain.getShipmentState(id)),
            uint(CustodyChain.State.Disputed)
        );

        // Jurado delibera y alcanza el umbral de 2 votos
        vm.prank(arbiter1);
        chain.vote(id, true); // Voto Cliente

        vm.prank(arbiter3);
        chain.vote(id, true); // Voto Cliente -> Cierra disputa

        assertEq(
            uint(chain.getShipmentState(id)),
            uint(CustodyChain.State.Resolved)
        );
        assertEq(
            client.addr.balance,
            clientBalanceBefore + payment + collateral,
            "Client did not recover funds + compensation"
        );
    }

    function test_CancelShipment_ClientRescue() public {
        vm.prank(client.addr);
        chain.createShipment{value: payment}(
            driver.addr,
            photoHash,
            arbiters,
            2,
            collateral
        );

        // El driver desaparece. Saltamos el margen de recogida de 24 horas.
        vm.warp(block.timestamp + 24 hours + 1 seconds);

        uint256 clientBalanceBefore = client.addr.balance;

        vm.prank(client.addr);
        chain.cancelShipment(0);

        assertEq(
            uint(chain.getShipmentState(0)),
            uint(CustodyChain.State.Resolved)
        );
        assertEq(client.addr.balance, clientBalanceBefore + payment);
    }

    // ==========================================
    // PRUEBAS DE SEGURIDAD (REVERTS EXPECTED)
    // ==========================================

    function test_Revert_DoubleVotingForbidden() public {
        uint256 id = _setupAndDeliverShipment();
        bytes32 msgHash = keccak256(abi.encodePacked(id, "Fraud attempt"));
        bytes memory sig = _generateSignature(client.key, msgHash);

        vm.prank(client.addr);
        chain.dispute(id, "Fraud attempt", sig);

        vm.prank(arbiter1);
        chain.vote(id, false);

        // Ataque de doble voto abortado por modificador
        vm.prank(arbiter1);
        vm.expectRevert("Already voted");
        chain.vote(id, false);
    }

    function test_Revert_ClientTriesToDisputeLate() public {
        uint256 id = _setupAndDeliverShipment();
        bytes32 msgHash = keccak256(abi.encodePacked(id, "Late dispute"));
        bytes memory sig = _generateSignature(client.key, msgHash);

        // Viaje en el tiempo que extingue el derecho de réplica (35 minutos)
        vm.warp(block.timestamp + 35 minutes);

        vm.prank(client.addr);
        vm.expectRevert("Dispute window expired");
        chain.dispute(id, "Late dispute", sig);
    }

    function test_Revert_UnauthorizedDriverIntervention() public {
        vm.prank(client.addr);
        chain.createShipment{value: payment}(
            driver.addr,
            photoHash,
            arbiters,
            2,
            collateral
        );

        address attacker = address(0xDEAD);
        vm.deal(attacker, 10 ether);

        // Un tercero malintencionado intenta interceptar y usurpar el rol de transporte
        vm.prank(attacker);
        vm.expectRevert("Only driver");
        chain.pickUp{value: collateral}(0);
    }
}
