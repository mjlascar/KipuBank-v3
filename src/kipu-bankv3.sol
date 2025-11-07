// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// contrato ReentrancyGuard desde github
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/ReentrancyGuard.sol"; //en la version v5.0.2 para asegurarnos estabilidad (version LTS)
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/access/AccessControl.sol"; //idem
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/extensions/IERC20Metadata.sol";// interfaz para la funcion `decimals()`

import "https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IUniswapV2Router02.sol";// interfaz de Uniswap V2 Router
import "https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol"; // interfaz de WETH (necesaria para swapear ETH)

/**
 * @title KipuBank-v3
 * @author Marcos
 * @notice contrato para depositar tokens y retirar usdc, con fines educativos.
 */

 
contract KipuBankv3 is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    /**
     * @notice rol admin general
     */
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /**
     * @notice rol address con capacidad de pausar contrato
     */
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // direcciones de contratos que accedemos mucho (inmutables para ahorrar gas)
    IUniswapV2Router02 public immutable i_uniswapRouter;
    IWETH public immutable i_weth;
    IERC20 public immutable i_usdc;

    /**
    * @notice Saldos de los usuarios (en USDC)
    */
    mapping(address => uint256) public s_saldos; 
    
    /**
    * @notice Total de USDC depositado en el contrato
    */
    uint256 private s_totalDepositadoUSDC;

    /**
     * @notice limite de retiro EN USDC (con sus decimales)
     */
    uint256 public s_retiroMax;
    /**
     * @notice limite de total depositado EN USDC (con sus decimales)
     */
    uint256 public s_bankCap;

    /**
    * @notice Contador de depositos
    */
    uint256 private s_contadorDepositos;

    /** 
    * @notice Contador de retiros
    */
    uint256 private s_contadorRetiros;


    ///eventos
    event Deposito(address indexed usuario, address indexed token, uint256 monto, uint256 valorUsd);
    event Retiro(address indexed usuario, address indexed token, uint256 monto, uint256 valorUsd);
    event BankCapUpdated(uint256 nuevoCap);
    event RetiroMaxUpdated(uint256 nuevoRetiro);
 
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
    * @notice si los parametros de bankCap/retiroMax no tienen sentido logico
    */
    error KipuBank__ConfiguracionInvalida();

    /** 
    * @notice error para contrato de precio invalido en el constructor
    */
    error KipuBank__DireccionInvalida();
    /** 
    * @notice error cuando el precio del usuario esperado es mayor al supuesto por uniswaap
    */
    error KipuBank__SlippageExcesivo();

    /** 
    * @notice error porque arribo al deposito con swap, cuando debi haber ido al deposito USDC
    */
    error KipuBank__UsarDepositarUSDC();

 
     constructor(uint256 _retiroMax, uint256 _bankCap, address _usdcAddress,address _wethAddress, address _uniswapRouterAddress ) {
        if (_retiroMax > _bankCap) revert KipuBank__ConfiguracionInvalida();
        if (_usdcAddress == address(0) || _wethAddress == address(0) || _uniswapRouterAddress == address(0)) revert KipuBank__DireccionInvalida();
        
        s_retiroMax = _retiroMax;
        s_bankCap = _bankCap;
        i_usdc = IERC20(_usdcAddress);
        i_weth = IWETH(_wethAddress);
        i_uniswapRouter = IUniswapV2Router02(_uniswapRouterAddress);

        // Asignar roles a quien desplega el contrato
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); //rol por defecto para poder añadir otros admins
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

    }
 
    // Funciones Externas

    function depositarUSDC(uint256 _monto) external nonReentrant whenNotPaused {
        if (_monto == 0) revert KipuBank__MontoInvalido();
        // Chequeo de bank cap
        if (s_totalDepositadoUSDC + _monto > s_bankCap) revert KipuBank__TopeDelBancoExcedido(s_totalDepositadoUSDC, _monto, s_bankCap);

        // Efectos
        s_saldos[msg.sender] += _monto;
        s_totalDepositadoUSDC += _monto;
        s_contadorDepositos++;

        // Interacción
        i_usdc.safeTransferFrom(msg.sender, address(this), _monto);

        emit Deposito(msg.sender, address(i_usdc), _monto, _monto); // El valor USD es el monto, es lo mismo porque es USDC
    }

    function depositarETH(uint256 _minAmountOut) external payable nonReentrant whenNotPaused {
        uint256 montoETH = msg.value;
        if (montoETH == 0) revert KipuBank__MontoInvalido();

        // chequeos
        address[] memory path = new address[](2);
        path[0] = address(i_weth); // El "camino" del swap es WETH -> USDC
        path[1] = address(i_usdc);

        uint256[] memory expectedAmounts = i_uniswapRouter.getAmountsOut(montoETH, path); // Consultamos a Uniswap cuánto USDC recibiremos
        uint256 expectedUSDC = expectedAmounts[1];

        if (s_totalDepositadoUSDC + expectedUSDC > s_bankCap) revert KipuBank__TopeDelBancoExcedido(s_totalDepositadoUSDC, expectedUSDC, s_bankCap);
        if (expectedUSDC < _minAmountOut) revert KipuBank__SlippageExcesivo();

        uint256 balanceUSDCPrevio = i_usdc.balanceOf(address(this));        
        // envuelve el ETH en WETH, swapea, y nos envía USDC, con deadline
        i_uniswapRouter.swapExactETHForTokens{value: montoETH}( _minAmountOut, path, address(this), block.timestamp);

        // calcular el USDC real recibido
        uint256 balanceUSDCPosterior = i_usdc.balanceOf(address(this));
        uint256 actualUSDCReceived = balanceUSDCPosterior - balanceUSDCPrevio;

        // Efectos
        s_saldos[msg.sender] += actualUSDCReceived;
        s_totalDepositadoUSDC += actualUSDCReceived;
        s_contadorDepositos++;

        emit Deposito(msg.sender, address(i_weth), montoETH, actualUSDCReceived);
    }

    function depositarToken(address _tokenIn, uint256 _amountIn, uint256 _minAmountOut) external nonReentrant whenNotPaused {
        if (_amountIn == 0) revert KipuBank__MontoInvalido();
        if (_tokenIn == address(i_usdc)) revert KipuBank__UsarDepositarUSDC();

        // chequea
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = address(i_usdc);

        uint256[] memory expectedAmounts = i_uniswapRouter.getAmountsOut(_amountIn, path); //el expected
        uint256 expectedUSDC = expectedAmounts[1];

        if (s_totalDepositadoUSDC + expectedUSDC > s_bankCap) revert KipuBank__TopeDelBancoExcedido(s_totalDepositadoUSDC, expectedUSDC, s_bankCap);
        if (expectedUSDC < _minAmountOut) revert KipuBank__SlippageExcesivo();

        // Traer los tokens del usuario
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);

        // aprobar al Router para que gaste nuestros nuevos tokens
        IERC20(_tokenIn).approve(address(i_uniswapRouter), _amountIn);

        // ejecutar el swap (token -> USDC)
        uint256 balanceUSDCPrevio = i_usdc.balanceOf(address(this));

        // envuelve el ETH en WETH, swapea, y nos envía USDC, con deadline
        i_uniswapRouter.swapExactTokensForTokens(_amountIn, _minAmountOut, path, address(this), block.timestamp );
        
        // calcular el USDC real recibido
        uint256 balanceUSDCPosterior = i_usdc.balanceOf(address(this));
        uint256 actualUSDCReceived = balanceUSDCPosterior - balanceUSDCPrevio;

        // efectos
        s_saldos[msg.sender] += actualUSDCReceived;
        s_totalDepositadoUSDC += actualUSDCReceived;
        s_contadorDepositos++;

        emit Deposito(msg.sender, _tokenIn, _amountIn, actualUSDCReceived);
    }

    /**
     * @notice Permite a un usuario retirar su ETH
     */
    function retirarUSDC(uint256 _monto) external nonReentrant whenNotPaused {
        if (_monto == 0) revert KipuBank__MontoRetiroEsCero();
        
        uint256 saldoUsuario = s_saldos[msg.sender];
        if (_monto > saldoUsuario) revert KipuBank__SaldoInsuficiente(saldoUsuario, _monto);
        
        // el chequeo de umbral ahora es directo, ambos en USD
        if (_monto > s_retiroMax) revert KipuBank__UmbralDeRetiroExcedido(_monto, s_retiroMax); 

        // Efectos
        s_saldos[msg.sender] -= _monto;
        s_totalDepositadoUSDC -= _monto;
        s_contadorRetiros++;
        
        // Interacción (solo USDC)
        i_usdc.safeTransfer(msg.sender, _monto);
        
        emit Retiro(msg.sender, address(i_usdc), _monto, _monto);
    }
    
    // Funciones de Vista (View)

    /**
     * @notice Devuelve el saldo de un usuario, para USDC
     */
    function obtenerSaldoUsuario(address _usuario) external view returns (uint256) {
        return s_saldos[_usuario];
    }
    
    
    /**
     * @notice Devuelve el estado del banco en USDC
     */
    function obtenerEstadoBanco() external view returns (uint256 totalDepositadoUSDC, uint256 topeDelBanco, uint256 numDepositos, uint256 numRetiros) {
        return (s_totalDepositadoUSDC, s_bankCap, s_contadorDepositos, s_contadorRetiros);
    }

    //Funciones administrativas

    /**
     * @notice Permite a un ADMIN cambiar el bankCap
     * @dev Protegida por el modificador onlyRole(ADMIN_ROLE)
     */
    function cambiarBankCap(uint256 _nuevoBankCapUsd) external onlyRole(ADMIN_ROLE) {
        if (s_retiroMax > _nuevoBankCapUsd) revert KipuBank__ConfiguracionInvalida();
        if (s_totalDepositadoUSDC > _nuevoBankCapUsd) revert KipuBank__ConfiguracionInvalida();
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
