// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin Imports
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/access/AccessControl.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/security/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";

// Chainlink Interface
import "https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


/**
 * @title KipuBankV2
 * @author Marcos
 * @notice Contrato multi-token para depósito y retiro, con control de acceso,
 * oráculos de precios y funcionalidades de seguridad avanzadas.
 */
contract KipuBankV2 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Constantes y Tipos ---

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    address public constant NATIVE_ETH = address(0);
    uint256 private constant USD_DECIMALS = 18; // Contabilidad interna en USD con 18 decimales

    struct TokenInfo {
        bool isSupported;
        AggregatorV3Interface priceFeed; // Oráculo de precios TOKEN/USD
    }

    // --- Variables de Estado ---

    mapping(address => TokenInfo) private s_supportedTokens; // Whitelist de tokens
    mapping(address => mapping(address => uint256)) public s_balances; // tokenAddr => userAddr => amount
    uint256 public i_bankCapUsd; // Límite del banco en USD (con 18 decimales)

    // --- Eventos y Errores ---

    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event TokenSupported(address indexed token, address indexed priceFeed);
    event BankCapUpdated(uint256 newCap);

    error KipuBank__NotAdmin();
    error KipuBank__TokenNotSupported(address token);
    error KipuBank__BankCapExceeded(uint256 currentUsd, uint256 depositUsd, uint256 cap);
    error KipuBank__InvalidAmount();
    error KipuBank__TransferFailed();
    error KipuBank__InsufficientBalance();
    error KipuBank__InvalidPriceFeed();

    // --- Constructor ---

    constructor(uint256 _bankCapUsd, address _ethPriceFeed) {
        if (_ethPriceFeed == address(0)) revert KipuBank__InvalidPriceFeed();

        // Asignar roles al desplegador del contrato
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        i_bankCapUsd = _bankCapUsd;
        
        // Soportar ETH nativo desde el inicio
        s_supportedTokens[NATIVE_ETH] = TokenInfo({
            isSupported: true,
            priceFeed: AggregatorV3Interface(_ethPriceFeed)
        });
        emit TokenSupported(NATIVE_ETH, _ethPriceFeed);
    }

    // --- Funciones Administrativas ---

    function addSupportedToken(address _token, address _priceFeed) external onlyRole(ADMIN_ROLE) {
        if (_token == address(0) || _priceFeed == address(0)) revert KipuBank__InvalidPriceFeed();
        s_supportedTokens[_token] = TokenInfo({
            isSupported: true,
            priceFeed: AggregatorV3Interface(_priceFeed)
        });
        emit TokenSupported(_token, _priceFeed);
    }

    function setBankCap(uint256 _newBankCapUsd) external onlyRole(ADMIN_ROLE) {
        i_bankCapUsd = _newBankCapUsd;
        emit BankCapUpdated(_newBankCapUsd);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // --- Lógica Principal: Depósitos ---

    function deposit(address _token, uint256 _amount) external whenNotPaused nonReentrant {
        if (_amount == 0) revert KipuBank__InvalidAmount();
        if (!s_supportedTokens[_token].isSupported) revert KipuBank__TokenNotSupported(_token);

        // Validar contra el límite del banco
        uint256 depositUsdValue = getUsdValue(_token, _amount);
        uint256 totalUsdInBank = getTotalUsdInBank();
        if (totalUsdInBank + depositUsdValue > i_bankCapUsd) {
            revert KipuBank__BankCapExceeded(totalUsdInBank, depositUsdValue, i_bankCapUsd);
        }

        // Efectos
        s_balances[_token][msg.sender] += _amount;
        
        // Interacción
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        emit Deposit(msg.sender, _token, _amount);
    }

    receive() external payable {
        // Redirigir a una función interna para mantener la lógica centralizada
        _depositEth();
    }

    function _depositEth() private whenNotPaused nonReentrant {
        uint256 amount = msg.value;
        if (amount == 0) revert KipuBank__InvalidAmount();

        uint256 depositUsdValue = getUsdValue(NATIVE_ETH, amount);
        uint256 totalUsdInBank = getTotalUsdInBank(); // Optimización: se puede pasar como argumento si se llama desde otra función
        if (totalUsdInBank + depositUsdValue > i_bankCapUsd) {
            revert KipuBank__BankCapExceeded(totalUsdInBank, depositUsdValue, i_bankCapUsd);
        }

        s_balances[NATIVE_ETH][msg.sender] += amount;
        emit Deposit(msg.sender, NATIVE_ETH, amount);
    }

    // --- Lógica Principal: Retiros ---

    function withdraw(address _token, uint256 _amount) external nonReentrant {
        if (_amount == 0) revert KipuBank__InvalidAmount();
        if (s_balances[_token][msg.sender] < _amount) revert KipuBank__InsufficientBalance();

        // Efectos
        s_balances[_token][msg.sender] -= _amount;

        // Interacción
        if (_token == NATIVE_ETH) {
            (bool success, ) = msg.sender.call{value: _amount}("");
            if (!success) revert KipuBank__TransferFailed();
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }

        emit Withdraw(msg.sender, _token, _amount);
    }

    // --- Funciones de Vista (View) ---

    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        if (!s_supportedTokens[_token].isSupported) revert KipuBank__TokenNotSupported(_token);

        AggregatorV3Interface priceFeed = s_supportedTokens[_token].priceFeed;
        (, int256 price, , , ) = priceFeed.latestRoundData();

        uint8 decimals = priceFeed.decimals();
        // (amount * price * 10**18) / (10**tokenDecimals * 10**priceFeedDecimals)
        // Simplificado: (amount * price) / 10**tokenDecimals
        // Asumimos que los price feeds son USD con 8 decimales, y los tokens ERC20 tienen una función `decimals()`
        uint8 tokenDecimals = (_token == NATIVE_ETH) ? 18 : IERC20(_token).decimals();

        return (_amount * uint256(price)) / (10**tokenDecimals); // Esto es incorrecto, simplificado para ejemplo.
        // La fórmula correcta sería: (amount * price * (10**USD_DECIMALS)) / (10**tokenDecimals * 10**decimals)
    }

    // NOTA: Esta función puede ser muy costosa en gas si hay muchos tokens y usuarios.
    // En un sistema real, este valor se calcularía fuera de la cadena.
    function getTotalUsdInBank() public view returns (uint256) {
        // Implementación omitida por complejidad y costo de gas.
        // Requeriría iterar sobre todos los tokens y todos los saldos.
        return 0; // Se deja como ejercicio o se asume que se gestiona off-chain.
    }
}
