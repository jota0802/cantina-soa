# Arquitetura

O desenho está em Mermaid. O arquivo `.mmd` é a fonte; o `.svg` e o `.png` são a imagem gerada a
partir dele. Para mudar o desenho, edite o `.mmd` e renderize de novo.

| Visão | Fonte | Imagem | O que mostra |
|---|---|---|---|
| Estrutura | `estrutura.mmd` | `estrutura.svg`, `estrutura.png` | Os três serviços, a linguagem e a porta de cada um (com a segunda instância do Cardápio e o segundo Avisos), os dados que só ele usa, os contratos em cada seta (inclusive nas duas setas do evento), o evento por webhook e os pontos de falha |
| Sequência | `sequencia.mmd` | `sequencia.svg`, `sequencia.png` | Um pedido do início ao fim: `POST /pedidos`, consulta ao Cardápio em paralelo, gravação, `201` e o evento ao Avisos depois da resposta: `202` tira da outbox, só `400`/`413` descarta, qualquer outra falha deixa o evento na outbox e o Pedidos tenta de novo `REENVIO_MS` depois do fim de cada tentativa que falhou; o Avisos deduplica pelo par `source` + `id`. Também os caminhos `422` (ex.: item 4, Bolo de cenoura, indisponível) e `503` |

A visão de estrutura cresceu a cada entrega: o histórico do Git mostra os contratos sozinhos
(Entrega 1), o Cardápio no ar (Entrega 2), o Pedidos compondo o Cardápio (Entrega 3) e o canal de
eventos com o Avisos (Entrega 4). As versões antigas têm a entrega no título; a atual não. Nas
versões antigas, o que ainda não existia aparece em cinza e tracejado; na versão atual tudo está
no ar.

## Legenda dos traços

| Traço | Significado |
|---|---|
| Linha cheia com seta (`-->`) | Chamada síncrona HTTP + JSON: quem chama espera a resposta |
| Linha pontilhada com seta (`-.->`) | Evento assíncrono: quem publica não espera o consumidor |
| Linha sem seta (`---`) | O serviço e os dados que só ele usa (o Cardápio só lê o `itens.json`; o Pedidos lê e grava os dele) |
| Cilindro | Arquivo de dados |

Cada seta leva o nome do contrato que ela segue (`pedidos.yaml`, `cardapio.yaml`,
`pedido-confirmado.json`, `avisos.yaml`). Na estrutura, os rótulos das duas setas do evento são
caixas cinza no meio da seta (como rótulo de seta, o Mermaid desenhava um em cima do outro). Na
sequência, `->>` (linha cheia) é chamada, `-->>` é resposta, a seta aberta pontilhada (`--)`) é o
evento, `--x` (pontilhada com `x`) é uma tentativa de entrega do evento que falhou e `-x` (cheia
com `x`) é uma chamada síncrona que falhou.

## Decisões do grupo

| Serviço | Linguagem | Porta | Dados (só dele) | Contrato |
|---|---|---|---|---|
| Cardápio | Python 3 | 8081 (segunda instância na 8091) | `servicos/cardapio/itens.json` | `contratos/cardapio.yaml` |
| Pedidos | Node.js | 8082 | `servicos/pedidos/dados/pedidos.json` e a fila de reenvio `outbox.json` | `contratos/pedidos.yaml` |
| Avisos | Go | 8083 (segundo consumidor na 8084) | nenhum arquivo; lembra em memória o par `source` + `id` de cada evento já processado (um reinício esquece) | `contratos/avisos.yaml` |

- **Composição:** o Pedidos chama `GET /itens/{id}` no Cardápio com tempo limite de 2 s. O endereço
  vem da variável `CARDAPIO_URL`, então dá para apontar para a 8081 ou para a 8091 sem mudar código.
- **Trilha de eventos: A, sem broker.** O Pedidos publica `cantina.pedido.confirmado` (CloudEvents)
  fazendo `POST /eventos` em cada endereço da variável `ASSINANTES`. O segundo consumidor (8084)
  entra mudando `ASSINANTES` e reiniciando o Pedidos, sem mudar código. O Avisos responde `202`.
  Só `400` e `413` são erro permanente (é o que `avisos.yaml` define): o evento sai da outbox sem
  reenvio. Qualquer outra falha (assinante fora, sem resposta em 2 s, `404`, `405`, `5xx`...)
  deixa o evento em `outbox.json`, e o Pedidos tenta de novo `REENVIO_MS` (padrão 3 s) depois do
  fim de cada tentativa que falhou. Não é um relógio fixo: com o assinante travado, cada tentativa
  leva os 2 s do tempo limite, e o intervalo entre o começo de uma e o da outra fica em ~5 s.
- **Ponto de falha 1, Cardápio fora ou lento:** o `POST /pedidos` responde `503` e nenhum pedido é
  criado. Com o Cardápio fora, o `503` sai na hora; com ele lento, em cerca de 2 s (medido:
  2,002 s, em `evidencias/missao3.txt`).
- **Ponto de falha 2, Avisos fora:** o pedido é confirmado (`201`) mesmo assim. O evento espera na
  outbox e, quando o Avisos volta, chega com o mesmo `source` e o mesmo `id`; o Avisos responde
  `202` e não repete o aviso de um evento (par `source` + `id`) que já viu.

## Como renderizar de novo

Precisa de Node.js. O `mermaid-cli` baixa um Chrome headless na primeira vez.

```bash
cd arquitetura
for f in estrutura sequencia; do
  npx -y @mermaid-js/mermaid-cli@latest -i $f.mmd -o $f.svg -b white
  npx -y @mermaid-js/mermaid-cli@latest -i $f.mmd -o $f.png -b white -s 2 --size 2400
done
```

Sem o `--size`, o PNG sai com no máximo 800 px de largura e o texto fica pequeno demais. Se o Chrome
reclamar de sandbox (Linux, Codespaces), crie `puppeteer.json` com `{"args":["--no-sandbox"]}` e
acrescente `-p puppeteer.json` aos comandos. Também dá para colar o `.mmd` em
<https://mermaid.live> para ver o desenho no navegador.
