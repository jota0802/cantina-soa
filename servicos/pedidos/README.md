# Pedidos

Serviço que registra os pedidos da Cantina. Segue o contrato
[`contratos/pedidos.yaml`](../../contratos/pedidos.yaml) e usa só a biblioteca padrão do Node.js
(18 ou mais novo; nada de `npm install`).

O Pedidos não guarda preço nem disponibilidade. A cada pedido ele pergunta ao **Cardápio, por
HTTP** (`GET /itens/{id}`, uma vez por item, em paralelo), confere se o item existe e está
disponível e calcula o total com o preço que o Cardápio informar. Do Cardápio ele lê só
`precoCentavos`, `disponivel` e `nome`; campos a mais na resposta são ignorados.

Depois de confirmar um pedido, o Pedidos **publica o evento `cantina.pedido.confirmado`** para
os assinantes da variável `ASSINANTES` (Trilha A, webhook). A publicação nunca atrasa nem
derruba o pedido; veja [Evento pedido confirmado](#evento-pedido-confirmado-missão-4).

| Rota | Resposta |
|---|---|
| `POST /pedidos` | 201 com o pedido e o header `Location: /pedidos/{id}` |
| | 400 `requisicao_invalida`: JSON inválido, corpo maior que 1 MiB, `itens` vazio ou com mais de 20 itens, `itemId` fora do formato, `quantidade` fora de 1 a 1000 |
| | 422 `item_inexistente` ou `item_indisponivel`: nenhum pedido é criado |
| | 503 `cardapio_indisponivel`: o Cardápio não respondeu em 2 s, está fora do ar ou respondeu com erro |
| `GET /pedidos/{id}` | 200 com o pedido, ou 404 `pedido_inexistente` |
| `GET /saude` | 200 com `{"status":"ok","servico":"pedidos"}` |

Fora do contrato, um caminho que não existe devolve 404 `rota_inexistente` e um método errado
405 `metodo_nao_permitido` (os dois estão no enum de `Erro`).

O limite de 20 itens existe porque cada item vira uma chamada ao Cardápio: sem ele, um pedido
com centenas de itens abriria centenas de conexões de uma vez e terminaria num 503 enganoso.

A consulta inteira ao Cardápio tem **um** prazo de 2 segundos, compartilhado por todas as
chamadas do pedido: com o Cardápio fora do ar o cliente recebe o 503 na hora, e com o Cardápio
travado, em cerca de 2 s (medido: 2,002 s, em `evidencias/missao3.txt`). Enquanto isso o Pedidos
continua atendendo as outras requisições.

## Evento pedido confirmado (Missão 4)

O evento segue o envelope CloudEvents 1.0 de
[`contratos/pedido-confirmado.json`](../../contratos/pedido-confirmado.json):

```json
{
  "specversion": "1.0",
  "id": "0eaec377-9ead-4b01-af8a-0c2ca008b660",
  "source": "/cantina/pedidos",
  "type": "cantina.pedido.confirmado",
  "time": "2026-10-07T01:35:55.172Z",
  "datacontenttype": "application/json",
  "data": { "pedidoId": 2, "totalCentavos": 2500 }
}
```

O `id` é um UUID novo a cada pedido (`crypto.randomUUID()`) e é o mesmo para todos os
assinantes. O Pedidos faz `POST` dele em cada endereço de `ASSINANTES`, com
`Content-Type: application/cloudevents+json`. O Pedidos não sabe quem são os consumidores:
um segundo Avisos entra mudando `ASSINANTES` e reiniciando o Pedidos, sem mudar código.
As regras do evento (campos obrigatórios, tipos e limites) estão em
[`contratos/pedido-confirmado.schema.json`](../../contratos/pedido-confirmado.schema.json).

### Outbox: o pedido não espera ninguém

Se o `POST /pedidos` esperasse cada assinante responder, um Avisos fora do ar atrasaria (ou
derrubaria) a venda. Por isso a publicação usa uma **outbox**:

1. Ao confirmar, o Pedidos grava o pedido em `pedidos.json` e, logo depois, uma entrada por
   par (evento, assinante) em `outbox.json`. Tudo local, sem rede.
2. Responde **201** ao cliente.
3. Um despachante, em segundo plano, faz o `POST` em cada assinante (`publicador.js`).

| Resposta do assinante | O que o despachante faz |
|---|---|
| 2xx | Entregue: a entrada sai da outbox. |
| 400 ou 413 | Erro permanente, porque é o que `avisos.yaml` define: o assinante recusou o evento, e reenviar o mesmo corpo não muda a resposta. Loga e descarta. |
| Qualquer outro status que não seja 2xx (404, 405, 408, 429, 5xx...), sem conexão ou sem resposta em 2 s | Falha passageira: mantém na outbox e tenta de novo. Num 404 ou 405 o log também pede para conferir o endereço em `ASSINANTES` (quase sempre falta o `/eventos`). |

- Cada entrega tem **tempo limite de 2 s**.
- **`REENVIO_MS` é a espera depois de uma tentativa que falhou**, contada a partir do fim dela,
  e não um relógio fixo. Com o padrão de 3 s, um assinante desligado (conexão recusada na hora)
  recebe uma tentativa a cada ~3 s; um assinante travado (a tentativa só termina quando estoura
  o tempo limite de 2 s) recebe uma a cada ~5 s.
- Não há limite de tentativas: a entrada fica na outbox até ser entregue ou recusada com 400/413.
  Um endereço errado em `ASSINANTES` é tentado para sempre. Corrigir o endereço e reiniciar o
  Pedidos vale só para pedidos novos: a entrada que já está na outbox continua presa ao endereço
  errado (veja abaixo). Para tirá-la, pare o Pedidos, apague essa entrada do `outbox.json` e suba
  de novo.
- Cada entrada tem a sua própria sequência de tentativas: a próxima só é agendada quando a
  anterior terminou, então nunca há duas entregas simultâneas da mesma entrada, e um assinante
  fora do ar não atrasa a entrega aos outros.
- A outbox fica em arquivo: se o Pedidos parar com entregas pendentes, ao subir de novo ele lê
  `outbox.json` e retoma (`Outbox: ... (1 entregas pendentes)` no log de subida).
- A entrega é **pelo menos uma vez**: se o Pedidos cair no meio de uma entrega, ela é feita de
  novo na próxima subida. O Avisos reconhece o evento repetido pelo par `source` + `id` e não
  avisa duas vezes. A ordem entre eventos de pedidos diferentes não é garantida (um reenvio
  pode chegar depois de um evento mais novo).
- Cada entrada guarda o endereço do assinante. Se `ASSINANTES` mudar com entregas pendentes,
  elas continuam indo para o endereço de quando o pedido foi confirmado.
- Limite conhecido: `pedidos.json` e `outbox.json` são dois arquivos. Se o processo cair
  exatamente entre as duas gravações (que são síncronas e seguidas), o pedido fica sem evento.
  A ordem é de propósito: o pedido é gravado primeiro porque o evento leva o id do pedido, e
  porque perder um aviso é menos grave que avisar um pedido que não existe (o que aconteceria
  se o evento fosse gravado antes e o processo caísse antes de gravar o pedido). Um banco de
  dados resolveria isso gravando os dois na mesma transação.

Uma linha de log por tentativa:

```
[pedidos:8082] evento 0eaec377-... entregue a http://localhost:8083/eventos
[pedidos:8082] evento 0eaec377-... para http://localhost:8083/eventos falhou (conexão recusada: o assinante está fora do ar?), nova tentativa em 3 s
[pedidos:8082] evento 0eaec377-... para http://localhost:8083/eventos descartado (respondeu 400: {"codigo":"evento_invalido",...})
[pedidos:8082] evento 0eaec377-... para http://localhost:8083 falhou (respondeu 404: {...}. Confira o endereço em ASSINANTES: http://localhost:8083 deve ser a rota POST /eventos do assinante), nova tentativa em 3 s
```

Sem `ASSINANTES` (ou com ela vazia), o Pedidos não publica nada e avisa uma vez, ao subir:
`ASSINANTES vazio: nenhum evento será publicado.`

## Dados

Os pedidos ficam em `dados/pedidos.json`, nesta pasta, e as entregas pendentes do evento em
`dados/outbox.json` (uma lista vazia, `[]`, quando tudo foi entregue). Só o Pedidos lê e
escreve esses arquivos (o Cardápio e o Avisos não sabem que eles existem). A gravação escreve
num `.tmp` e renomeia, para o arquivo nunca ficar pela metade, e os ids continuam a sequência
depois de reiniciar o serviço. Para começar do zero, apague a pasta `dados/` com o serviço
parado.

## Variáveis

| Variável | Obrigatória | Para quê |
|---|---|---|
| `PORTA` | sim | Porta em que o serviço escuta (8082 nos testes). |
| `CARDAPIO_URL` | sim | Raiz do Cardápio, como `http://localhost:8081` (com ou sem barra no fim, **sem** `/itens`). |
| `DADOS_DIR` | não | Pasta do `pedidos.json` e do `outbox.json`. Padrão: `dados/` nesta pasta (criada se não existir). |
| `ASSINANTES` | não | Endereços que recebem o evento `cantina.pedido.confirmado`, separados por vírgula, como `http://localhost:8083/eventos,http://localhost:8084/eventos`. Vazia ou ausente: não publica nada. |
| `REENVIO_MS` | não | Quanto esperar, em milissegundos, depois de uma tentativa de entrega que falhou (contando do fim dela) antes da próxima. Não é um relógio fixo. Padrão: `3000` (mínimo `100`). |

Sem `PORTA` ou `CARDAPIO_URL` o serviço não sobe e diz o que falta (o mesmo vale para um
endereço de `ASSINANTES` que não seja `http://...` ou um `REENVIO_MS` que não seja um número
inteiro de 100 ou mais). Ao subir, o Pedidos chama
`GET {CARDAPIO_URL}/saude` e, se não vier 200, escreve um aviso no terminal (mas sobe mesmo
assim): é o sinal de que `CARDAPIO_URL` está errado ou de que o Cardápio ainda não está no ar.

## Como rodar

O jeito mais rápido é subir os três serviços de uma vez, num terminal só (Bash, na raiz do
repositório; `Ctrl+C` derruba todos):

```bash
bash scripts/subir.sh
```

Para subir só o Pedidos, primeiro suba o Cardápio na 8081 (veja
[`servicos/cardapio/README.md`](../cardapio/README.md)) e o Avisos na 8083 (veja
[`servicos/avisos/README.md`](../avisos/README.md)). Depois, em outro terminal:

Bash (Linux, macOS, Git Bash):

```bash
cd servicos/pedidos
PORTA=8082 CARDAPIO_URL=http://localhost:8081 ASSINANTES=http://localhost:8083/eventos node server.js
```

PowerShell (Windows):

```powershell
cd servicos\pedidos
$env:PORTA = "8082"; $env:CARDAPIO_URL = "http://localhost:8081"; $env:ASSINANTES = "http://localhost:8083/eventos"; node server.js
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
do pedido criado: o 404 mostra que os dois 422 não criaram pedido. Para os dois 503, pare o
Cardápio com `Ctrl+C`, deixe o Pedidos no ar e rode:

```bash
bash scripts/missao3.sh cardapio-fora    # Cardápio fora do ar: 503 na hora
bash scripts/missao3.sh cardapio-lento   # Cardápio que aceita a conexão e não responde: 503 em ~2 s
```

Os dois modos conferem antes que o Cardápio está mesmo fora (se ele responder em `/saude`, o
script para sem gravar nada). O `cardapio-lento` ocupa a porta do Cardápio com um simulador em
Python que aceita a conexão e nunca responde, faz o pedido medindo o tempo e derruba o
simulador no fim. Tudo vai para `evidencias/missao3.txt`: o modo padrão zera o arquivo, e os
dois modos de falha acrescentam ao fim.

No PowerShell, na raiz do repositório, o pedido de exemplo também pode ser enviado assim:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:8082/pedidos -ContentType "application/json" -InFile servicos/pedidos/pedido.json
```

## Verificação (Missão 4)

Na raiz do repositório, com as portas 8081 a 8084 livres (o script sobe e derruba tudo sozinho,
e confere antes que as portas estão livres, parando com erro se alguma estiver em uso):

```bash
bash scripts/missao4.sh
```

O script compila o Avisos numa pasta temporária, sobe o Cardápio, o Pedidos e dois Avisos e
mostra: o aviso do pedido 1; o pedido 2 saindo 201 em milissegundos com o Avisos fora do ar, e o
Pedidos dizendo que vai reenviar; o aviso do pedido 2 chegando quando o Avisos volta; o mesmo
evento do pedido 2 mandado de novo ao Avisos (202 e `repetido, ignorado`, sem novo aviso); o
pedido 3 criado com o Avisos fora, o Pedidos reiniciado com a entrega pendente na outbox e o
aviso do pedido 3 chegando uma vez só; e um segundo Avisos (`avisos-2`, porta 8084) recebendo o
pedido 4 depois de mudar `ASSINANTES` e reiniciar o Pedidos (o hash dos arquivos `.js` é o mesmo
antes e depois). A saída só substitui `evidencias/missao4.txt` se todas as conferências passarem;
com `--sem-gravar` só aparece na tela. As portas mudam por variável, como
`PORTA_PEDIDOS=9082 bash scripts/missao4.sh --sem-gravar`.

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
