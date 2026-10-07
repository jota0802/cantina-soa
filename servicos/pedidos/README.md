# Pedidos

Serviço que registra os pedidos da Cantina. Segue o contrato
[`contratos/pedidos.yaml`](../../contratos/pedidos.yaml) e usa só a biblioteca padrão do Node.js
(18 ou mais novo; nada de `npm install`).

O Pedidos não guarda preço nem disponibilidade. A cada pedido ele pergunta ao **Cardápio, por
HTTP** (`GET /itens/{id}`, uma vez por item, em paralelo), confere se o item existe e está
disponível e calcula o total com o preço que o Cardápio informar. Do Cardápio ele lê só
`precoCentavos`, `disponivel` e `nome`; campos a mais na resposta são ignorados.

| Rota | Resposta |
|---|---|
| `POST /pedidos` | 201 com o pedido e o header `Location: /pedidos/{id}` |
| | 400 `requisicao_invalida`: JSON inválido, `itens` vazio ou com mais de 20 itens, `itemId` fora do formato, `quantidade` fora de 1 a 1000 |
| | 422 `item_inexistente` ou `item_indisponivel`: nenhum pedido é criado |
| | 503 `cardapio_indisponivel`: o Cardápio não respondeu em 2 s, está fora do ar ou respondeu com erro |
| `GET /pedidos/{id}` | 200 com o pedido, ou 404 `pedido_inexistente` |
| `GET /saude` | 200 com `{"status":"ok","servico":"pedidos"}` |

Fora do contrato, um caminho que não existe devolve 404 `rota_inexistente` e um método errado
405 `metodo_nao_permitido` (os dois estão no enum de `Erro`).

O limite de 20 itens existe porque cada item vira uma chamada ao Cardápio: sem ele, um pedido
com centenas de itens abriria centenas de conexões de uma vez e terminaria num 503 enganoso.

A consulta inteira ao Cardápio tem **um** prazo de 2 segundos, compartilhado por todas as
chamadas do pedido: com o Cardápio fora do ar ou travado, o cliente recebe o 503 em no máximo
~2 s, e o Pedidos continua atendendo as outras requisições.

## Dados

Os pedidos ficam em `dados/pedidos.json`, nesta pasta. Só o Pedidos lê e escreve esse arquivo
(o Cardápio não sabe que ele existe). A gravação escreve num `.tmp` e renomeia, para o arquivo
nunca ficar pela metade, e os ids continuam a sequência depois de reiniciar o serviço. Para
começar do zero, apague a pasta `dados/` com o serviço parado.

## Variáveis

| Variável | Obrigatória | Para quê |
|---|---|---|
| `PORTA` | sim | Porta em que o serviço escuta (8082 nos testes). |
| `CARDAPIO_URL` | sim | Raiz do Cardápio, como `http://localhost:8081` (com ou sem barra no fim, **sem** `/itens`). |
| `DADOS_DIR` | não | Pasta do `pedidos.json`. Padrão: `dados/` nesta pasta (criada se não existir). |

Sem `PORTA` ou `CARDAPIO_URL` o serviço não sobe e diz o que falta. Ao subir, o Pedidos chama
`GET {CARDAPIO_URL}/saude` e, se não vier 200, escreve um aviso no terminal (mas sobe mesmo
assim): é o sinal de que `CARDAPIO_URL` está errado ou de que o Cardápio ainda não está no ar.

## Como rodar

Primeiro suba o Cardápio na 8081 (veja [`servicos/cardapio/README.md`](../cardapio/README.md)).
Depois, em outro terminal:

Bash (Linux, macOS, Git Bash):

```bash
cd servicos/pedidos
PORTA=8082 CARDAPIO_URL=http://localhost:8081 node server.js
```

PowerShell (Windows):

```powershell
cd servicos\pedidos
$env:PORTA = "8082"; $env:CARDAPIO_URL = "http://localhost:8081"; node server.js
```

`npm start` também funciona, com as mesmas variáveis. Cada requisição gera uma linha no
terminal, como `[pedidos:8082] POST /pedidos -> 201 (12 ms)`. Para parar, `Ctrl+C`.

## Verificação (Missão 3)

Com o Cardápio (8081) e o Pedidos (8082) no ar, na raiz do repositório:

```bash
bash scripts/missao3.sh
```

O script cria o pedido de `pedido.json` (total 2500), consulta o pedido criado, tenta o de
`pedido-indisponivel.json` (422 `item_indisponivel`, Bolo de cenoura) e o de
`pedido-inexistente.json` (422 `item_inexistente`, item 99) e, por fim, consulta o id seguinte ao
do pedido criado: o 404 mostra que os dois 422 não criaram pedido. Para o 503, pare o Cardápio com `Ctrl+C` e rode:

```bash
bash scripts/missao3.sh cardapio-fora
```

Tudo vai para `evidencias/missao3.txt` (a primeira forma zera o arquivo; `cardapio-fora`
acrescenta ao fim).

No PowerShell, o pedido de exemplo também pode ser enviado assim:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:8082/pedidos -ContentType "application/json" -InFile pedido.json
```

## Prova de fogo

`CARDAPIO_URL` apontado para o Cardápio de outro grupo, sem alterar nenhuma linha do Pedidos.
Preencham depois do teste:

| Campo | Resultado |
|---|---|
| Grupo | _(nome ou integrantes do outro grupo)_ |
| Linguagem do Cardápio deles | _(ex.: Java, C#, Go)_ |
| `CARDAPIO_URL` usado | _(ex.: https://...-8081.app.github.dev)_ |
| `POST /pedidos` com `pedido.json` | _(status e `totalCentavos` recebidos)_ |
| Observações | _(algo que precisou de ajuste no ambiente, não no código)_ |

Ao terminar, `CARDAPIO_URL` volta para o Cardápio do grupo (`http://localhost:8081`).
