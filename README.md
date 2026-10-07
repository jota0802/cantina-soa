# Cantina SOA

Laboratório de Arquitetura Orientada a Serviços (FIAP · CheckPoint 3). A cantina do câmpus
recebe pedidos pelo celular e avisa quando o pedido é confirmado. O sistema tem três serviços
pequenos, e o que liga um ao outro é só o contrato.

| Serviço | O que faz | Linguagem |
|---|---|---|
| **Cardápio** | Informa o que há para vender | Python 3 (biblioteca padrão) |
| **Pedidos** | Registra a compra consultando o Cardápio | Node.js (biblioteca padrão) |
| **Avisos** | Reage quando um pedido é confirmado | Go (biblioteca padrão) |

Cada serviço está em uma linguagem diferente de propósito: se o contrato basta para eles se
entenderem, nenhum precisa saber como o outro foi escrito.

## Grupo

| Nome | RM |
|---|---|
| João Victor Franco | 556790 |
| Lucca Borges | 554608 |
| Ruan Melo | 557599 |
| Rodrigo Jimenez | 558148 |
| Bruno Leão | 555563 |

## Estrutura

```
cantina-soa/
├── contratos/       os contratos, antes do código
├── servicos/
│   ├── cardapio/
│   ├── pedidos/
│   └── avisos/
├── arquitetura/     fonte e imagem do desenho
├── evidencias/      saídas dos testes de cada missão
└── README.md        como rodar + matriz de princípios
```
