# ParabolicGuard AMM — DefensiveV2Pair

[![Solidity](https://img.shields.io/badge/Solidity-%5E0.8.19-blue)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Framework: Foundry](https://img.shields.io/badge/Framework-Foundry-red)](https://book.getfoundry.sh/)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-4.x-purple)](https://openzeppelin.com/contracts/)

> **ParabolicGuard** es una implementación avanzada de una pool de liquidez estilo Uniswap V2 diseñada para mitigar la volatilidad extrema y proteger a los holders a largo plazo mediante una **Resistencia Parabólica Dinámica**.

---

## 📋 Tabla de Contenidos

- [¿Qué soluciona?](#-qué-soluciona)
- [Arquitectura Técnica](#️-arquitectura-técnica)
- [Instalación y Despliegue](#-instalación-y-despliegue)
- [Eventos Principales](#-eventos-principales)
- [Configuración y Gobernanza](#️-configuración-y-gobernanza)
- [Seguridad](#-seguridad)
- [Estructura del Proyecto](#-estructura-del-proyecto)
- [Contribuir](#-contribuir)
- [Licencia](#-licencia)

---

## 🚀 ¿Qué soluciona?

En los AMM tradicionales, las ventas masivas (*dumps*) desangran la liquidez de forma lineal. **ParabolicGuard** introduce una capa de fricción inteligente que desincentiva el comportamiento especulativo sin castigar al ecosistema:

| Problema (AMM estándar) | Solución (ParabolicGuard) |
|---|---|
| Dumps destruyen la liquidez linealmente | Penalización dinámica en ventas de alto impacto |
| LPs sufren Impermanent Loss sin compensación | El 30% del excedente se reinvierte automáticamente en la pool |
| Sin ingresos para el protocolo en eventos de volatilidad | El excedente restante alimenta una tesorería |
| Manipulación de precios en el mismo bloque | Precio de referencia anti-flashloan por bloque |

### Flujo de un swap penalizado

```
Venta grande de Token A
        │
        ▼
¿Impacto > Threshold?
   │           │
  No           Sí → Calcular γ (gamma)
   │                     │
   ▼                     ▼
Swap normal       Swap con penalización
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
         30% → Pool LP         70% → Tesorería
        (mitiga IL)           (recompra/desarrollo)
```

---

## 🛠️ Arquitectura Técnica

### Resistencia Parabólica

La penalización no es fija — crece cuadráticamente según qué tanto supera el umbral definido:

$$\gamma = 1 + k \cdot \left(\frac{\Delta P_{bps} - Threshold}{Threshold}\right)^2$$

Donde:
- **k** (`kFactor`): controla la "dureza" de la curva. Mayor k = mayor penalización.
- **ΔP_bps**: impacto en precio de la operación, expresado en puntos base.
- **Threshold**: umbral a partir del cual se activa la resistencia (ej. 500 bps = 5%).

> Una curva cuadrática significa que operaciones moderadamente grandes son aceptables, pero los *mega-dumps* se vuelven económicamente inviables.

### Compatibilidad con Agregadores

La función `getAmountOut` personalizada permite a routers como **1inch** o **Uniswap** calcular el slippage real *antes* de ejecutar el swap, asegurando que la penalización sea siempre predecible y transparente.

---

## 📦 Instalación y Despliegue

### Prerrequisitos

- [Foundry](https://book.getfoundry.sh/getting-started/installation) instalado
- Node.js y npm (para OpenZeppelin)

### Setup

```bash
# 1. Clonar el repositorio
git clone https://github.com/tu-usuario/parabolic-guard-amm.git
cd parabolic-guard-amm

# 2. Instalar dependencias de OpenZeppelin
npm install @openzeppelin/contracts

# 3. Compilar contratos
forge build

# 4. Ejecutar tests
forge test

# 5. Tests con output detallado
forge test -vvv
```

### Despliegue local (Anvil)

```bash
# Iniciar nodo local
anvil

# Desplegar en red local
forge script script/DeployDefensivePair.s.sol \
    --rpc-url http://127.0.0.1:8545 \
    --broadcast \
    --private-key <TU_CLAVE_PRIVADA>
```

### Despliegue en Testnet

```bash
forge script script/DeployDefensivePair.s.sol \
    --rpc-url <RPC_URL_TESTNET> \
    --broadcast \
    --verify \
    --etherscan-api-key <TU_API_KEY>
```

> ⚠️ **Nunca** expongas tu clave privada en el código. Usa variables de entorno con un archivo `.env` y añádelo a `.gitignore`.

---

## 📊 Eventos Principales

El contrato emite eventos detallados para una transparencia total on-chain:

```solidity
// Se emite cada vez que la resistencia parabólica se activa
event ResistanceApplied(
    address indexed seller,
    uint256 penalty,
    uint256 lpShare,      // Porción reinvertida en la pool
    uint256 treasuryShare // Porción enviada a tesorería
);

// Actualiza las reservas para interfaces y oráculos
event Sync(uint112 reserve0, uint112 reserve1);

// Registra la entrada de capital de los LPs
event LiquidityAdded(
    address indexed provider,
    uint256 amount0,
    uint256 amount1,
    uint256 lpTokensMinted
);
```

---

## ⚙️ Configuración y Gobernanza

El `Owner` puede ajustar los parámetros de defensa para adaptarse al ciclo de vida del token sin necesidad de redesplegar el contrato:

| Función | Parámetros | Descripción |
|---|---|---|
| `setParams(kFactor, threshold)` | `uint256, uint256` | Ajusta la dureza de la curva y el umbral de activación |
| `setLpShare(bps)` | `uint256` | Cambia el porcentaje del excedente que reciben los LPs (en bps) |

**Ejemplo de configuración conservadora (lanzamiento):**
```solidity
setParams(200, 500);  // k=200, threshold=5%
setLpShare(3000);     // 30% para LPs
```

**Ejemplo de configuración agresiva (defensa activa):**
```solidity
setParams(500, 300);  // k=500, threshold=3%
setLpShare(5000);     // 50% para LPs
```

---

## 🔒 Seguridad

- **Anti-Flashloan:** El precio de referencia se actualiza una sola vez por bloque, impidiendo manipulaciones dentro de la misma transacción.
- **SafeCast:** Uso de `SafeCast` de OpenZeppelin para prevenir desbordamientos en las reservas `uint112`.
- **Sin reentrancia:** Sigue el patrón checks-effects-interactions para todas las operaciones de liquidez.

> Si encuentras una vulnerabilidad, por favor repórtala de forma responsable abriendo un issue privado o contactando directamente al equipo.

---

## 📁 Estructura del Proyecto

```
parabolic-guard-amm/
├── src/
│   └── DefensiveV2Pair.sol     # Contrato principal
├── script/
│   └── DeployDefensivePair.s.sol
├── test/
│   └── DefensiveV2Pair.t.sol
├── img/
│   └── parabolic-curve.png     # (opcional) gráfico de la curva γ
├── foundry.toml
├── package.json
└── README.md
```

---

## 🤝 Contribuir

¡Las contribuciones son bienvenidas! Por favor:

1. Haz un fork del repositorio.
2. Crea una rama para tu feature (`git checkout -b feat/mi-mejora`).
3. Asegúrate de que todos los tests pasan (`forge test`).
4. Abre un Pull Request con una descripción clara del cambio.

---

## 📄 Licencia

Distribuido bajo la licencia **MIT**. Consulta el archivo [`LICENSE`](./LICENSE) para más detalles.

---

<div align="center">
  Desarrollado con ❤️ para ecosistemas DeFi resilientes.
</div>
