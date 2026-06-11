// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract CustodyChain {
    // ==========================================
    // 1. ESTADOS DEL PAQUETE
    // ==========================================
    enum State {
        Created, // Pedido registrado, esperando recogida
        PickedUp, // Transportista recogió
        InTransit, // En ruta hacia el destino
        Delivered, // Transportista marcó entregado
        Confirmed, // Cliente confirmó conformidad (Camino feliz)
        Disputed, // Cliente abrió una disputa
        Resolved // Cerrado por arbitraje o cancelación
    }

    // ==========================================
    // 2. ESTRUCTURA DE UN ENVÍO
    // ==========================================
    struct Shipment {
        uint256 id;
        address driver; // Transportista
        address client; // Destinatario/Cliente
        uint256 payment; // Pago por el servicio depositado por el cliente (wei)
        uint256 collateral; // Garantía exigida al driver (wei)
        bytes32 photoHash; // Hash de la foto (IPFS)
        State state; // Estado actual en la máquina de estados
        uint256 deliveredAt; // Timestamp de entrega
        uint256 confirmDeadline; // Plazo para confirmar/disputar tras la entrega
        uint256 pickupDeadline; // Plazo máximo para que el driver recoja el paquete
        bytes driverSignature; // Firma criptográfica del driver al entregar
        bytes clientSignature; // Firma criptográfica del cliente al confirmar/disputar
        bool disputeResolved; // Bandera de cierre de disputa
        address[] arbiters; // Jueces asignados a este envío
        uint256 threshold; // Votos mínimos para dictar sentencia
        uint256 votesForClient; // Acumulado de votos a favor del cliente
        uint256 votesForDriver; // Acumulado de votos a favor del driver
    }

    // ==========================================
    // 3. ALMACENAMIENTO (STORAGE)
    // ==========================================
    Shipment[] public shipments;

    // Solución al error del compilador: Mappings extraídos a nivel superior
    mapping(uint256 => mapping(address => bool)) public isArbiterForShipment;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // Tiempos globales de control (Estilo SpawnLedger)
    uint256 public constant DEFAULT_CONFIRM_WINDOW = 30 minutes;
    uint256 public constant DEFAULT_PICKUP_WINDOW = 24 hours;

    // ==========================================
    // 4. EVENTOS (Trazabilidad Total)
    // ==========================================
    event ShipmentCreated(
        uint256 indexed id,
        address indexed driver,
        address indexed client,
        uint256 payment,
        uint256 requiredCollateral
    );
    event PickedUp(
        uint256 indexed id,
        address indexed driver,
        uint256 collateral
    );
    event InTransitUpdate(uint256 indexed id, address indexed driver);
    event Delivered(
        uint256 indexed id,
        address indexed driver,
        bytes32 photoHash
    );
    event Confirmed(uint256 indexed id, address indexed client);
    event AutoConfirmed(
        uint256 indexed id,
        address indexed driver,
        uint256 payout
    );
    event Disputed(uint256 indexed id, address indexed client, string reason);
    event DisputeResolved(
        uint256 indexed id,
        bool inFavorOfClient,
        uint256 votesClient,
        uint256 votesDriver
    );
    event ShipmentCancelled(uint256 indexed id, address indexed client);

    // ==========================================
    // 5. MODIFICADORES
    // ==========================================
    modifier onlyDriver(uint256 _id) {
        require(msg.sender == shipments[_id].driver, "Only driver");
        _;
    }
    modifier onlyClient(uint256 _id) {
        require(msg.sender == shipments[_id].client, "Only client");
        _;
    }
    modifier onlyArbiter(uint256 _id) {
        require(isArbiterForShipment[_id][msg.sender], "Not an arbiter");
        _;
    }
    modifier inState(uint256 _id, State _expected) {
        require(shipments[_id].state == _expected, "Wrong state");
        _;
    }
    modifier notResolved(uint256 _id) {
        require(!shipments[_id].disputeResolved, "Already resolved");
        _;
    }

    // ==========================================
    // 6. FUNCIONES PRINCIPALES
    // ==========================================

    /// @notice Registra el paquete en la ledger. El cliente financia el coste de envío.
    function createShipment(
        address _driver,
        bytes32 _photoHash,
        address[] calldata _arbiters,
        uint256 _threshold,
        uint256 _requiredCollateral
    ) external payable {
        require(_driver != address(0), "Invalid driver");
        require(msg.value > 0, "Payment required");
        require(_arbiters.length > 0, "At least one arbiter");
        require(
            _threshold > 0 && _threshold <= _arbiters.length,
            "Invalid threshold"
        );
        require(_photoHash != bytes32(0), "Photo hash required");

        uint256 id = shipments.length;

        Shipment storage s = shipments.push();
        s.id = id;
        s.driver = _driver;
        s.client = msg.sender;
        s.payment = msg.value;
        s.collateral = _requiredCollateral;
        s.photoHash = _photoHash;
        s.state = State.Created;
        s.pickupDeadline = block.timestamp + DEFAULT_PICKUP_WINDOW;
        s.arbiters = _arbiters;
        s.threshold = _threshold;

        for (uint256 i = 0; i < _arbiters.length; i++) {
            isArbiterForShipment[id][_arbiters[i]] = true;
        }

        emit ShipmentCreated(
            id,
            _driver,
            msg.sender,
            msg.value,
            _requiredCollateral
        );
    }

    /// @notice El driver acepta el transporte depositando su colateral de garantía.
    function pickUp(
        uint256 _id
    ) external payable onlyDriver(_id) inState(_id, State.Created) {
        require(
            msg.value == shipments[_id].collateral,
            "Must deposit exact collateral"
        );

        shipments[_id].state = State.PickedUp;
        emit PickedUp(_id, msg.sender, msg.value);
    }

    /// @notice Cláusula de escape: Si el driver deja colgado al cliente en Created, el cliente rescata sus fondos.
    function cancelShipment(
        uint256 _id
    ) external onlyClient(_id) inState(_id, State.Created) {
        require(
            block.timestamp > shipments[_id].pickupDeadline,
            "Driver still has time to pickup"
        );

        shipments[_id].state = State.Resolved;

        (bool success, ) = shipments[_id].client.call{
            value: shipments[_id].payment
        }("");
        require(success, "Refund failed");

        emit ShipmentCancelled(_id, msg.sender);
    }

    function markInTransit(
        uint256 _id
    ) external onlyDriver(_id) inState(_id, State.PickedUp) {
        shipments[_id].state = State.InTransit;
        emit InTransitUpdate(_id, msg.sender);
    }

    /// @notice Driver entrega y firma criptográficamente los datos físicos (sin block.timestamp volátil).
    function markDelivered(
        uint256 _id,
        bytes32 _photoHash,
        bytes calldata _signature
    ) external onlyDriver(_id) inState(_id, State.InTransit) {
        require(_photoHash != bytes32(0), "Photo required");
        Shipment storage s = shipments[_id];

        bytes32 message = keccak256(abi.encodePacked(_id, _photoHash));
        require(
            recoverSigner(message, _signature) == s.driver,
            "Invalid driver signature"
        );

        s.photoHash = _photoHash;
        s.driverSignature = _signature;
        s.state = State.Delivered;
        s.deliveredAt = block.timestamp;
        s.confirmDeadline = block.timestamp + DEFAULT_CONFIRM_WINDOW;

        emit Delivered(_id, msg.sender, _photoHash);
    }

    /// @notice El cliente firma de conformidad. El driver cobra su recompensa + recupera su fianza.
    function confirmReceipt(
        uint256 _id,
        bytes calldata _signature
    ) external onlyClient(_id) inState(_id, State.Delivered) {
        Shipment storage s = shipments[_id];
        require(
            block.timestamp <= s.confirmDeadline,
            "Confirmation window expired"
        );

        bytes32 message = keccak256(abi.encodePacked(_id, s.photoHash));
        require(
            recoverSigner(message, _signature) == s.client,
            "Invalid client signature"
        );

        s.clientSignature = _signature;
        s.state = State.Confirmed;

        uint256 totalPayout = s.payment + s.collateral;
        (bool success, ) = s.driver.call{value: totalPayout}("");
        require(success, "Payout failed");

        emit Confirmed(_id, msg.sender);
    }

    /// @notice Mecanismo SpawnLedger: Si el cliente ignora el paquete, el sistema liquida a favor del transportista de forma automática.
    function autoConfirm(
        uint256 _id
    ) external inState(_id, State.Delivered) notResolved(_id) {
        Shipment storage s = shipments[_id];
        require(block.timestamp > s.confirmDeadline, "Deadline not passed yet");

        s.state = State.Confirmed;

        uint256 totalPayout = s.payment + s.collateral;
        (bool success, ) = s.driver.call{value: totalPayout}("");
        require(success, "Auto payout failed");

        emit AutoConfirmed(_id, s.driver, totalPayout);
    }

    /// @notice Bloquea fondos y abre juicio descentralizado.
    function dispute(
        uint256 _id,
        string calldata _reason,
        bytes calldata _signature
    ) external onlyClient(_id) inState(_id, State.Delivered) notResolved(_id) {
        Shipment storage s = shipments[_id];
        require(block.timestamp <= s.confirmDeadline, "Dispute window expired");

        bytes32 message = keccak256(abi.encodePacked(_id, _reason));
        require(
            recoverSigner(message, _signature) == s.client,
            "Invalid client signature"
        );

        s.clientSignature = _signature;
        s.state = State.Disputed;

        emit Disputed(_id, msg.sender, _reason);
    }

    /// @notice Los árbitros autorizados (Multisig style) votan de forma transparente e inmutable.
    function vote(
        uint256 _id,
        bool inFavorOfClient
    ) external onlyArbiter(_id) inState(_id, State.Disputed) notResolved(_id) {
        Shipment storage s = shipments[_id];
        require(!hasVoted[_id][msg.sender], "Already voted");

        hasVoted[_id][msg.sender] = true;
        if (inFavorOfClient) {
            s.votesForClient++;
        } else {
            s.votesForDriver++;
        }

        if (s.votesForClient >= s.threshold) {
            _resolveDispute(_id, true);
        } else if (s.votesForDriver >= s.threshold) {
            _resolveDispute(_id, false);
        }
    }

    // CEI Integrado de forma segura
    function _resolveDispute(uint256 _id, bool inFavorOfClient) private {
        Shipment storage s = shipments[_id];
        s.disputeResolved = true;
        s.state = State.Resolved;

        uint256 totalFunds = s.payment + s.collateral;

        if (inFavorOfClient) {
            // Cliente gana: Se le devuelve su pago y se queda el colateral del driver como compensación por daños/pérdida
            (bool success, ) = s.client.call{value: totalFunds}("");
            require(success, "Refund failed");
        } else {
            // Driver gana: Intento de fraude del cliente expuesto. Driver toma todo.
            (bool success, ) = s.driver.call{value: totalFunds}("");
            require(success, "Payment to driver failed");
        }

        emit DisputeResolved(
            _id,
            inFavorOfClient,
            s.votesForClient,
            s.votesForDriver
        );
    }

    // ==========================================
    // 7. UTILIDADES CRIPTOGRÁFICAS (EIP-191)
    // ==========================================
    function recoverSigner(
        bytes32 _message,
        bytes calldata _signature
    ) public pure returns (address) {
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", _message)
        );
        (bytes32 r, bytes32 s, uint8 v) = _splitSignature(_signature);
        return ecrecover(ethSignedHash, v, r, s);
    }

    function _splitSignature(
        bytes calldata _sig
    ) private pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(_sig.length == 65, "Invalid signature length");
        assembly {
            r := calldataload(_sig.offset)
            s := calldataload(add(_sig.offset, 32))
            v := byte(0, calldataload(add(_sig.offset, 64)))
        }
    }

    // Getters limpios para no colapsar la EVM
    function getShipmentState(uint256 _id) external view returns (State) {
        return shipments[_id].state;
    }
}
