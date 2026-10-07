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

## Como rodar

Pré-requisitos: Python 3.9+, Node.js 18+ e `curl`. Nenhum `pip install` ou `npm install`: os
serviços usam só a biblioteca padrão. Rode cada serviço em um terminal, a partir da raiz do
repositório.

```bash
# Cardápio (duas instâncias, para mostrar que não guardam estado)
PORTA=8081 python3 servicos/cardapio/app.py
PORTA=8091 python3 servicos/cardapio/app.py

# Pedidos
PORTA=8082 CARDAPIO_URL=http://localhost:8081 node servicos/pedidos/server.js
```

No PowerShell, defina as variáveis antes (`$env:PORTA="8081"; python servicos/cardapio/app.py`)
e use `curl.exe` nos testes.

Testes das missões, com os serviços no ar: `bash scripts/missao2.sh` e `bash scripts/missao3.sh`.
As saídas ficam em `evidencias/`.

## Prova de fogo (Missão 3)

**Pendente: fazer na aula de 19/10.** Apontar `CARDAPIO_URL` para o Cardápio de outro grupo, de
preferência em outra linguagem, e repetir o `POST /pedidos` sem alterar uma linha do Pedidos.

| Grupo parceiro | Linguagem do Cardápio deles | Resultado |
|---|---|---|
| _a preencher_ | _a preencher_ | _a preencher_ |
