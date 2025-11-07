# KipuBank V3

(+) se reestructuro el estado del contrato, haciendo a USDC como activo unico
	-Para el caso de retirar, se retirara unicamente USDC

(+) las funciones receive() y fallback() ya no pueden ser usadas! ya que no aceptan parametros, y necesitamos que la web app nos diga la cantidad mínima de USDC que acepta recibir (slippage),
	porque sin eso un bot puede hacer un sanwich attack manipulando el precio de uniswap justo antes de nuestro swap y robando valor al usuario
	-Por lo anterior, ahora existen 3 caminos para depositar (USDC, ETH, SWAPTOKEN), todos almacenan USDC

(+) en los caminos a depositar tokens que no sean USDC, se puede dar el caso que el expected amount devuelto por Uniswap sea menor que el que nos llegue,
	decidi dejarlo de esta manera, ya que el rebalse del tope se puede considerar insignificante
­


Despliegue (con Remix)
1.Abre KipuBank-v3.sol en Remix IDE.

2.Compila el contrato.
  Ve a la pestaña Compiler (icono S) y haz clic en "Compile".

3.Despliega.
  Ve a la pestaña Deploy (icono de Ethereum).
  Elige "Injected Provider - MetaMask" para conectar tu billetera.
  Ingresa los límites del banco en usd con 6 decimales ejemplo ($1000): 1000000000 (1000 + 6 ceros).
  Ingresa los direcciones de tokens USDC y WETH para tu red (sepolia)
  Ingresa la dirección del Router de Uniswap V2 en la red
  Haz clic en "Deploy" y confirma en MetaMask.

Etherscan de mi deploy con codigo verificado: https://sepolia.etherscan.io/address/0x5cd0724deb246b0ff2b18dea751a45ab47dce7f9
Para testear se deployo 
--WETH (0xfff9976782d46cc05630d1f6eb61e95e9aabe65c), y 
--USDC (0x1c7d4b196cb0c7b01d7a3ebde040c96a1997b27d)
--Router V2 de Uniswap (0x881d40237659c251811cec9c364ef91dc08d300c)
