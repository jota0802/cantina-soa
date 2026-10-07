# Avisos

Serviço da Cantina que avisa quando um pedido é confirmado. Escrito em Go,
só com a biblioteca padrão. Contrato: [`contratos/avisos.yaml`](../../contratos/avisos.yaml).

O grupo usa a **Trilha A (webhook)**: o Pedidos faz `POST /eventos` neste
serviço com o evento `cantina.pedido.confirmado` (CloudEvents 1.0; exemplo em
[`contratos/pedido-confirmado.json`](../../contratos/pedido-confirmado.json) e
regras em [`contratos/pedido-confirmado.schema.json`](../../contratos/pedido-confirmado.schema.json))
e reenvia enquanto o Avisos estiver fora do ar. Ao receber o evento, o Avisos
escreve no terminal:

```
[avisos] Pedido 1 confirmado, total R$ 25,00
```

## Como rodar

Precisa do Go 1.21 ou mais novo.

Bash (Linux, macOS, Git Bash):

```bash
cd servicos/avisos
PORTA=8083 go run .
```

PowerShell (Windows):

```powershell
cd servicos/avisos
$env:PORTA = "8083"; go run .
```

Para parar, `Ctrl+C`.

## Variáveis de ambiente

| Variável | Obrigatória | Para que serve |
|----------|-------------|----------------|
| `PORTA`  | sim         | Porta HTTP (8083 nos testes oficiais). Sem ela o serviço não sobe. |
| `NOME`   | não         | Nome da instância nos logs, entre colchetes. Padrão: `avisos`. |

## Testando na mão

```bash
curl -i -H 'Content-Type: application/cloudevents+json' \
  --data-binary @../../contratos/pedido-confirmado.json \
  http://localhost:8083/eventos
```

Responde `202`. Mandando o mesmo comando de novo, também responde `202`, mas o
log mostra `evento b7e2c1a0-0001 repetido, ignorado` em vez de repetir o aviso.

## Comportamento

- `cantina.pedido.confirmado` novo: gera o aviso e responde `202`.
- Mesmo evento de novo (mesmo `source` e mesmo `id`, que é como o CloudEvents
  identifica um evento): responde `202` sem repetir o aviso (o reenvio é seguro).
- Outro `type`: responde `202` e loga `tipo <type> ignorado`.
- JSON inválido: `400` com `codigo` `requisicao_invalida`.
- JSON válido mas que não é um objeto (lista, texto, número ou `null`), ou
  envelope errado (`specversion` diferente de `"1.0"`, falta
  `id`/`source`/`type` ou algum deles não é texto), `data` sem
  `pedidoId`/`totalCentavos` inteiros, `pedidoId` menor que 1 ou
  `totalCentavos` negativo: `400` com `codigo` `evento_invalido`. A validação
  vem antes da checagem de repetido, então um reenvio com corpo inválido
  também recebe `400`.
- Corpo maior que 1 MiB: `413`. Rota desconhecida: `404` com `codigo`
  `rota_inexistente`. Método errado: `405` com `codigo` `metodo_nao_permitido`
  e o header `Allow`. Todos os erros saem no formato `Erro` do contrato (JSON).

**Limitação:** os eventos já processados ficam só na memória. Se o serviço
reiniciar, ele esquece, e um evento reenviado depois disso gera o aviso de novo.
A lista também cresce a cada evento novo, sem limite; para o laboratório, tudo bem.

**Limitação:** o `encoding/json` do Go ignora maiúsculas e minúsculas nos nomes
dos campos, então `SPECVERSION` ou `ID` também são aceitos. No CloudEvents os
nomes são sempre minúsculos; o Avisos é só mais tolerante que o contrato.
