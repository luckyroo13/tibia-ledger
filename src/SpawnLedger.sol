// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract SpawnLedger {
    struct SpawnInfo {
        address currentPlayer;
        uint256 endTime;
        address[] queue;
    }

    uint256 public constant GRACE_PERIOD = 15 minutes;

    // ID Cueva => Información de la cueva
    mapping(uint256 => SpawnInfo) public spawns;

    // Dirección Jugador => (ID Cueva => Timestamp de liberación)
    mapping(address => mapping(uint256 => uint256)) public playerCooldown;

    // Dirección Jugador => Racha de AFK seguidos
    mapping(address => uint256) public afkStreak;

    // Eventos
    event JoinedQueue(
        uint256 indexed spawnId,
        address indexed player,
        uint256 position
    );
    event SpawnClaimed(
        uint256 indexed spawnId,
        address indexed player,
        uint256 endTime
    );
    event PlayerWarned(address indexed player, uint256 indexed spawnId);
    event PlayerBanned(
        address indexed player,
        uint256 indexed spawnId,
        uint256 penaltyEndTime
    );

    // Escoba automática para limpiar inactivos
    function _refreshQueue(uint256 _spawnId) internal {
        SpawnInfo storage spawn = spawns[_spawnId];

        while (
            spawn.queue.length > 0 &&
            block.timestamp > spawn.endTime + GRACE_PERIOD
        ) {
            address afkPlayer = spawn.queue[0];
            _popQueue(_spawnId);
            afkStreak[afkPlayer]++;

            if (afkStreak[afkPlayer] == 1) {
                // 1ra falta: va al final de la cola
                spawn.queue.push(afkPlayer);
                emit PlayerWarned(afkPlayer, _spawnId);
            } else {
                // Reincidente: baneo escalable (2 horas, 3 horas, etc.)
                uint256 penaltyDuration = afkStreak[afkPlayer] * 1 hours;
                playerCooldown[afkPlayer][_spawnId] =
                    block.timestamp +
                    penaltyDuration;
                emit PlayerBanned(
                    afkPlayer,
                    _spawnId,
                    playerCooldown[afkPlayer][_spawnId]
                );
            }

            spawn.endTime = block.timestamp;
        }
    }

    // Formarse en la fila virtual
    function joinQueue(uint256 _spawnId) public {
        require(
            block.timestamp >= playerCooldown[msg.sender][_spawnId],
            "Tienes baneo activo en esta cueva"
        );

        SpawnInfo storage spawn = spawns[_spawnId];

        for (uint256 i = 0; i < spawn.queue.length; i++) {
            require(spawn.queue[i] != msg.sender, "Ya estas en esta fila");
        }
        require(spawn.currentPlayer != msg.sender, "Ya estas cazando aqui");

        spawn.queue.push(msg.sender);
        emit JoinedQueue(_spawnId, msg.sender, spawn.queue.length);
    }

    // Reclamar el spawn
    function claimSpawn(uint256 _spawnId, uint256 _durationHours) public {
        require(
            _durationHours > 0 && _durationHours <= 3,
            "Maximo 3 horas de caza"
        );

        _refreshQueue(_spawnId);

        SpawnInfo storage spawn = spawns[_spawnId];

        require(
            block.timestamp >= playerCooldown[msg.sender][_spawnId],
            "Tienes un baneo activo"
        );
        require(block.timestamp >= spawn.endTime, "La cueva aun esta ocupada");

        if (spawn.queue.length > 0) {
            require(spawn.queue[0] == msg.sender, "No es tu turno de reclamar");
            _popQueue(_spawnId);
        }

        // Reset de historial por entrar a cazar legalmente
        afkStreak[msg.sender] = 0;

        // Si deja gente esperando, el jugador saliente recibe cooldown de 24h
        if (spawn.currentPlayer != address(0) && spawn.queue.length > 0) {
            playerCooldown[spawn.currentPlayer][_spawnId] =
                block.timestamp +
                24 hours;
        }

        spawn.currentPlayer = msg.sender;
        spawn.endTime = block.timestamp + (_durationHours * 1 hours);

        emit SpawnClaimed(_spawnId, msg.sender, spawn.endTime);
    }

    // Funciones auxiliares
    function _popQueue(uint256 _spawnId) internal {
        SpawnInfo storage spawn = spawns[_spawnId];
        for (uint256 i = 0; i < spawn.queue.length - 1; i++) {
            spawn.queue[i] = spawn.queue[i + 1];
        }
        spawn.queue.pop();
    }

    function getQueue(uint256 _spawnId) public view returns (address[] memory) {
        return spawns[_spawnId].queue;
    }
}
