// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SpawnLedger} from "../src/SpawnLedger.sol";

contract SpawnLedgerTest is Test {
    SpawnLedger ledger;

    address cazadorActual = address(0x10);
    address jugadorAFK = address(0x20);
    address jugadorAtento = address(0x30);

    uint256 constant ASURAS_PALACE = 1;

    function setUp() public {
        ledger = new SpawnLedger();

        // El cazador actual reclama Asuras por 2 horas en el segundo 1 de la historia
        vm.warp(1);
        vm.prank(cazadorActual);
        ledger.claimSpawn(ASURAS_PALACE, 2);
    }

    // --- TEST: Activar el LeaverBuster estilo LoL ---
    function test_LeaverBuster_PenaltySystem() public {
        // 1. El jugadorAFK y el jugadorAtento se forman en la fila
        vm.prank(jugadorAFK);
        ledger.joinQueue(ASURAS_PALACE);

        vm.prank(jugadorAtento);
        ledger.joinQueue(ASURAS_PALACE);

        // 2. VIAJE EN EL TIEMPO: Adelantamos el reloj 2 horas y 16 minutos.
        // El tiempo de caza terminó y ya se consumieron los 15 minutos de gracia de jugadorAFK.
        uint256 tiempoExpirado = 1 + (2 hours) + (16 minutes);
        vm.warp(tiempoExpirado);

        // 3. El jugadorAtento (que va segundo) intenta reclamar el spawn.
        // Como el primero está AFK, la escoba interna debería patearlo al final.
        vm.prank(jugadorAtento);
        ledger.claimSpawn(ASURAS_PALACE, 2);

        // --- VERIFICACIÓN DE LA 1RA FALTA ---
        // El jugadorAFK no fue baneado aún, pero su racha de faltas subió a 1
        assertEq(
            ledger.afkStreak(jugadorAFK),
            1,
            "La racha de AFK deberia ser 1"
        );

        // El jugadorAtento ahora es el dueno legitimo de la cueva
        (address ownerActual, uint256 endTime) = ledger.spawns(ASURAS_PALACE);
        assertEq(
            ownerActual,
            jugadorAtento,
            "Jugador atento deberia ser el dueno"
        );

        // 4. SEGUNDA FALTA (Reincidente): Adelantamos el reloj otras 2 horas y 16 minutos.
        // Ahora el jugadorAtento terminó su turno, y vuelve a ser el turno de jugadorAFK (que quedó al final).
        uint256 tiempoExpiradoDos = endTime + 16 minutes;
        vm.warp(tiempoExpiradoDos);

        // Viene otra persona o el mismo jugadorAtento a limpiar la cola
        vm.prank(jugadorAtento);
        ledger.claimSpawn(ASURAS_PALACE, 2);

        // --- VERIFICACIÓN DEL BANEO ---
        // La racha del jugadorAFK subió a 2. El contrato debió clavarle el baneo "A la LoL".
        assertEq(
            ledger.afkStreak(jugadorAFK),
            2,
            "La racha de AFK deberia ser 2"
        );

        // Verificamos que tiene un cooldown (baneo) activo de 2 horas en esta cueva
        uint256 baneoHasta = ledger.playerCooldown(jugadorAFK, ASURAS_PALACE);
        assertTrue(
            baneoHasta > block.timestamp,
            "El jugadorAFK deberia estar baneado"
        );

        // Si el jugadorAFK intenta formarse de nuevo estando baneado, el contrato lo rebota
        vm.prank(jugadorAFK);
        vm.expectRevert("Tienes baneo activo en esta cueva");
        ledger.joinQueue(ASURAS_PALACE);
    }
}
