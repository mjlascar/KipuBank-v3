// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// contrato ReentrancyGuard desde github
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/ReentrancyGuard.sol"; //en la version v5.0.2 para asegurarnos estabilidad (version LTS)
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/access/AccessControl.sol"; //idem
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/extensions/IERC20Metadata.sol";// interfaz para la funcion `decimals()`

import "https://github.com/smartcontractkit/chainlink/blob/v2.10.0/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol"; //utilizo chainlink para los oraculos de control de precios (en base a USD), v2.10.0 para estabilidad

/**
 * @title KipuBank-v2
 * @author Marcos
 * @notice contrato para depositar y retirar tokens habilitados, con fines educativos.
 */

 
contract KipuBank is ReentrancyGuard, AccessControl, Pausable {
    
    using SafeERC20 for IERC20;

    /**
     * @notice rol admin general
     */
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /**
     * @notice rol address con capacidad de pausar contrato
     */
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /**
     * @notice ETH nativo
     */
    address public constant NATIVE_ETH = address(0);
    /**
     * @notice Constante para definir los decimales de nuestra contabilidad interna en USD
     */
    uint256 private constant USD_DECIMALS = 18;

    /**
     * @notice limite de retiro EN USD
     */
    uint256 public s_retiroMax;
    /**
     * @notice limite de total depositado EN USD
     */
    uint256 public s_bankCap;
    /**
    * @notice Saldos de los usuarios
    */
    mapping(address => mapping(address => uint256)) public s_saldos; //s_saldos[addrTOKEN][direccionUsuario] = cantidad
    /**
    * @notice Whitelist de tokens soportados, y su respectivo oraculo
    */
    struct TokenInfo {
        bool isSupported;
        AggregatorV3Interface priceFeed; // Oraculo de precios TOKEN/USD
    }
    mapping(address => TokenInfo) public s_tokenInfo;

    /**
    * @notice Total de todos los tokens depositado en el contrato EN USD
    */
    uint256 private s_totalDepositado;

    /**
    * @notice Contador de depositos
    */
    uint256 private s_contadorDepositos;

    /** 
    * @notice Contador de retiros
    */
    uint256 private s_contadorRetiros;
 
    // Modificadores
    
    ///**
    // * @notice Revisa si el monto del depósito en receive(R) o fallback(F) es válido y si no excede el tope del banco.
    // */
    //modifier depositoValidoRF() {
    //    uint256 monto = msg.value;
    //    if (monto == 0) revert KipuBank__MontoInvalido();
    //    
    //    uint256 valorUsd = tokenEnUSD(NATIVE_ETH, monto);
    //    if (s_totalDepositado + valorUsd > s_bankCap) revert KipuBank__TopeDelBancoExcedido(s_totalDepositado, valorUsd, s_bankCap);
    //    _;
    //}


    ///eventos
    event Deposito(address indexed usuario, address indexed token, uint256 monto, uint256 valorUsd);
    event Retiro(address indexed usuario, address indexed token, uint256 monto, uint256 valorUsd);
    event BankCapUpdated(uint256 nuevoCap);
    event RetiroMaxUpdated(uint256 nuevoRetiro);
    event TokenSoportadoAgregado(address indexed token, address indexed priceFeed);
 
    /// errores personalizados

    /** 
    * @notice  Se activa si el monto del depósito es invalido
    */
    error KipuBank__MontoInvalido();

    /** 
    * @notice si el deposito excede el limite total del banco
    */
    error KipuBank__TopeDelBancoExcedido(uint256 totalDepositado, uint256 topeBanco, uint256 monto);

    /** 
    * @notice si el monto a retirar es cero
    */
    error KipuBank__MontoRetiroEsCero();

    /** 
    * @notice si el monto a retirar excede el umbral por transaccion
    */
    error KipuBank__UmbralDeRetiroExcedido(uint256 monto, uint256 umbral);

    /** 
    * @notice si el usuario no tiene saldo suficiente para el retiro
    */
    error KipuBank__SaldoInsuficiente(uint256 saldo, uint256 monto);

    /** 
    * @notice si la transferencia de ETH al usuario falla
    */
    error KipuBank__TransferenciaFallida();

    /** 
    * @notice si los parametros de bankCap/retiroMax no tienen sentido logico
    */
    error KipuBank__ConfiguracionInvalida();

    /** 
    * @notice error para tokens no soportados
    */
    error KipuBank__TokenNoSoportado(address token);

    /** 
    * @notice error para tokens que ya están en la whitelist
    */
    error KipuBank__TokenYaSoportado(address token);

    /** 
    * @notice error para oráculos de precios invalidos o que fallen
    */
    error KipuBank__PrecioInvalido(address token);

 
     constructor(uint256 _retiroMax, uint256 _bankCap, address _ethPriceFeed) {
        if (_retiroMax > _bankCap) revert KipuBank__ConfiguracionInvalida();
        if (_ethPriceFeed == address(0)) revert KipuBank__PrecioInvalido(NATIVE_ETH);
        s_retiroMax = _retiroMax;
        s_bankCap = _bankCap;

        // Asignar roles a quien desplega el contrato
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); //rol por defecto para poder añadir otros admins
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        // Soporta ETH nativo desde el despliegue
        s_tokenInfo[NATIVE_ETH] = TokenInfo({
            isSupported: true, 
            priceFeed: AggregatorV3Interface(_ethPriceFeed)
        });
        emit TokenSoportadoAgregado(NATIVE_ETH, _ethPriceFeed);
    }
 
 
    // Funciones Receive y Fallback

    /**
     * @notice Acepta depositos de ETH. Se activa al enviar ETH al contrato sin datos de funcion
       */
    receive() external payable whenNotPaused {
        _depositarEth();
    }

    /**
     * @notice Se activa si se envia ETH con datos a una funcion que no existe
     */
    fallback() external payable whenNotPaused {
        _depositarEth();
    }
 
 
    // Funciones Externas

    function depositarToken(address _token, uint256 _monto) external nonReentrant whenNotPaused {
        if (_monto == 0) revert KipuBank__MontoInvalido();
        if (!s_tokenInfo[_token].isSupported) revert KipuBank__TokenNoSoportado(_token);

        uint256 valorUsd = tokenEnUSD(_token, _monto);
        if (s_totalDepositado + valorUsd > s_bankCap) revert KipuBank__TopeDelBancoExcedido(s_totalDepositado, valorUsd, s_bankCap);

        // Efectos
        s_saldos[_token][msg.sender] += _monto;
        s_totalDepositado += valorUsd;
        s_contadorDepositos++;

        // El usuario debe haber llamado a `approve` en el contrato del token primero
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _monto);

        emit Deposito(msg.sender, _token, _monto, valorUsd);
    }

    /**
     * @notice Permite a un usuario retirar su ETH
     */
    function retirar(address _token, uint256 _monto) external nonReentrant whenNotPaused {
        // Chequeos (podrian ser un modificador pero los dejo asi para variedad)
        if (_monto == 0) revert KipuBank__MontoRetiroEsCero();
        uint256 saldoUsuario = s_saldos[_token][msg.sender];
        if (_monto > saldoUsuario) revert KipuBank__SaldoInsuficiente(saldoUsuario, _monto);
        uint256 valorUsd = tokenEnUSD(_token, _monto);
        if (valorUsd > s_retiroMax) revert KipuBank__UmbralDeRetiroExcedido(valorUsd, s_retiroMax);

        // Efectos
        s_saldos[_token][msg.sender] -= _monto;
        s_totalDepositado -= valorUsd;
        s_contadorRetiros++;
        
        // Interacción
        if (_token == NATIVE_ETH) {
            _transferenciaSegura(msg.sender, _monto);
        } else {
            IERC20(_token).safeTransfer(msg.sender, _monto);
        }
        emit Retiro(msg.sender, _token, _monto, valorUsd);
    }
    
    // Funciones de Vista (View)

    /**
     * @notice Devuelve el saldo de un usuario, para determinado token
     */
    function obtenerSaldoUsuario(address _token, address _usuario) external view returns (uint256) {
        return s_saldos[_token][_usuario];
    }
    
    
    /**
     * @notice Devuelve el estado del banco
     */
    function obtenerEstadoBanco() external view returns (uint256 totalDepositado, uint256 topeDelBanco, uint256 numDepositos, uint256 numRetiros) {
        return (s_totalDepositado, s_bankCap, s_contadorDepositos, s_contadorRetiros);
    }
 
    // Funciones Privadas
    
    /**
     * @notice devuelve el valor en USD de cierta cantidad de tokens ERC20
     */
    function tokenEnUSD(address _token, uint256 _amount) internal view returns (uint256) {
        if (!s_tokenInfo[_token].isSupported) revert KipuBank__TokenNoSoportado(_token);

        AggregatorV3Interface priceFeed = s_tokenInfo[_token].priceFeed;
        (, int256 price, , , ) = priceFeed.latestRoundData();
        if(price <= 0) revert KipuBank__PrecioInvalido(_token);

        uint8 tokenDecimals = (_token == NATIVE_ETH) ? 18 : IERC20Metadata(_token).decimals();
        uint8 priceFeedDecimals = priceFeed.decimals();
        
        // Formula: (cantidadTokens * precioOraculo * 10**decimalesContabilidad) / (10**decimalesToken * 10**decimalesOraculo)
        //esto es porque (_amount/10**tokenDecimals = precio del token real), (uint256(price) / (10**priceFeedDecimals) = total usd real), multiplico todo antes para no perder decimales
        return (_amount * uint256(price) * (10**USD_DECIMALS)) / (10**tokenDecimals * 10**priceFeedDecimals);
    }

    /**
     * @notice Logica interna para manejar los depositos desde el receive() / fallback()
     */
    function _depositarEth() private {
        uint256 monto = msg.value;
        if (monto == 0) revert KipuBank__MontoInvalido();
        
        uint256 valorUsd = tokenEnUSD(NATIVE_ETH, monto);
        if (s_totalDepositado + valorUsd > s_bankCap) revert KipuBank__TopeDelBancoExcedido(s_totalDepositado, valorUsd, s_bankCap);

        //Efectos
        s_saldos[NATIVE_ETH][msg.sender] += monto;
        s_totalDepositado += valorUsd;
        s_contadorDepositos++;
        //Interaccion
        emit Deposito(msg.sender, NATIVE_ETH, monto, valorUsd);
    }

    
    /**
     * @notice Transfiere ETH de forma segura
     */
    function _transferenciaSegura(address _para, uint256 _monto) private {
        (bool success, ) = _para.call{value: _monto}("");
        if (!success) revert KipuBank__TransferenciaFallida();
    }

    //Funciones administrativas
    
    /**
     * @notice Permite a un ADMIN agregar un token a la whitelist
     * @dev Protegida por el modificador onlyRole(ADMIN_ROLE)
     */
    function agregarTokenSoportado(address _token, address _priceFeed) external onlyRole(ADMIN_ROLE) {
        if (s_tokenInfo[_token].isSupported) revert KipuBank__TokenYaSoportado(_token);
        if (_priceFeed == address(0)) revert KipuBank__PrecioInvalido(_token); //es address nula

        s_tokenInfo[_token] = TokenInfo({
            isSupported: true, 
            priceFeed: AggregatorV3Interface(_priceFeed)
        });
        emit TokenSoportadoAgregado(_token, _priceFeed);
    }


    /**
     * @notice Permite a un ADMIN cambiar el bankCap
     * @dev Protegida por el modificador onlyRole(ADMIN_ROLE)
     */
    function cambiarBankCap(uint256 _nuevoBankCapUsd) external onlyRole(ADMIN_ROLE) {
        if (s_retiroMax > _nuevoBankCapUsd) revert KipuBank__ConfiguracionInvalida();
        if (s_totalDepositado > _nuevoBankCapUsd) revert KipuBank__ConfiguracionInvalida();
        s_bankCap = _nuevoBankCapUsd;
        emit BankCapUpdated(_nuevoBankCapUsd);
    }

    /**
     * @notice Permite a un ADMIN cambiar el limite de retiro
     * @dev Protegida por el modificador onlyRole(ADMIN_ROLE)
     */
    function cambiarRetiroMax(uint256 _nuevoRetiroMax) external onlyRole(ADMIN_ROLE) {
        if (_nuevoRetiroMax > s_bankCap) revert KipuBank__ConfiguracionInvalida();
        s_retiroMax = _nuevoRetiroMax;
        emit RetiroMaxUpdated(_nuevoRetiroMax);
    }

    /**
     * @notice Permite a un usuario con rol de PAUSER pausar el contrato
     * @dev Protegida por el modificador onlyRole(PAUSER_ROLE)
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Permite a un usuario con rol de PAUSER despausar el contrato
     * @dev Protegida por el modificador onlyRole(PAUSER_ROLE)
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
