(+) se reestructuro el estado del contrato, haciendo a USDC como activo unico

Despliegue (con Remix)
1.Abre KipuBank-v2.sol en Remix IDE.

2.Compila el contrato.
  Ve a la pestaña Compiler (icono S) y haz clic en "Compile".

3.Despliega.
  Ve a la pestaña Deploy (icono de Ethereum).
  Elige "Injected Provider - MetaMask" para conectar tu billetera.
  Ingresa los límites del banco en usd con 18 decimales ejemplo ($100): 100000000000000000000 (100 + 18 ceros).
  Ingresa el price feed de ETH para tu red (sepolia: 0x694AA1769357215DE4FAC081bf1f309aDC325306)
  Haz clic en "Deploy" y confirma en MetaMask.

Etherscan de mi deploy con codigo verificado: https://sepolia.etherscan.io/address/0xbb85b8d8bfff39c6d6382307e04adc372e2023a2
Para testear se agrego WBTC, y 
--agregue LINK (token 0x779877A7B0D9E8603169DdbD7836e478b4624789, priceFeed 0xc59E3633BAAC79493d908e63626716e204A45EdF)
--aprobe el uso de LINK por parte de mi KIPU BANK desde https://sepolia.etherscan.io/token/0x779877A7B0D9E8603169DdbD7836e478b4624789#writeContract
	con transaccion https://sepolia.etherscan.io/tx/0xac5b4c4caa0dddcf7db37b5c5201d95ee239ca4cc670e2f77dbdc0deb9b1d402
--y envie 10LINK (token 0x779877A7B0D9E8603169DdbD7836e478b4624789, monto 10000000000000000000 por 18 decimales)
	con transaccion https://sepolia.etherscan.io/tx/0x9cacea5b06ba5eeaf87e6ad72acaa8d15cf80e5efb06b19e0b5aec1ed3ad7136
--y retire 5LINK (transaccion https://sepolia.etherscan.io/tx/0x446082a5708b90580bfb9816ee7181ed7208074678335a4e3c8e9d13ba90af29)

