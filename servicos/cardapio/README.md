# Cardápio

Serviço que informa o que a Cantina tem para vender. Segue o contrato
[`contratos/cardapio.yaml`](../../contratos/cardapio.yaml) e usa só a biblioteca padrão do Python 3
(testado no 3.9).

| Rota | Resposta |
|---|---|
| `GET /itens` | 200 com a lista de itens |
| `GET /itens/{id}` | 200 com o item, ou 404 se ele não existe |
| `GET /saude` | 200 com `{"status":"ok","servico":"cardapio"}` |

Os itens ficam em `itens.json`, nesta pasta. São dados de referência, iguais em todas as
instâncias, e o serviço não guarda nada sobre quem chamou: por isso duas instâncias em portas
diferentes respondem exatamente a mesma coisa.

## Variáveis

| Variável | Obrigatória | Para quê |
|---|---|---|
| `PORTA` | sim | Porta em que o serviço escuta. Sem ela o serviço não sobe. |

## Como rodar

Duas instâncias, uma em cada terminal (é o que a Missão 2 pede).

Bash (Linux, macOS, Git Bash):

```bash
cd servicos/cardapio
PORTA=8081 python3 app.py
# em outro terminal
PORTA=8091 python3 app.py
```

PowerShell (Windows):

```powershell
cd servicos\cardapio
$env:PORTA = "8081"; python app.py
# em outro terminal
$env:PORTA = "8091"; python app.py
```

Cada requisição gera uma linha no terminal, como `[cardapio:8081] GET /itens/1 -> 200`.
Para parar, `Ctrl+C`.

O serviço escuta em todas as interfaces, em IPv4 e IPv6 quando o sistema aceita os dois no
mesmo socket (`socket.has_dualstack_ipv6()`, o comum no macOS, no Linux e no Windows atuais);
senão, só em IPv4. Por isso `localhost`, `127.0.0.1` e o IP da máquina na rede (útil para a
prova de fogo da Missão 3) funcionam.

## Verificação (Missão 2)

Com as duas instâncias no ar, na raiz do repositório:

```bash
bash scripts/missao2.sh
```

O script roda os cinco `curl -i` do enunciado e grava a saída em `evidencias/missao2.txt`.
