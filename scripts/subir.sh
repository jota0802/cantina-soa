#!/usr/bin/env bash
# Sobe os três serviços da Cantina num terminal só, para a demonstração.
#
#   Cardápio (Python) na 8081, Avisos (Go) na 8083 e Pedidos (Node) na 8082, com o Pedidos
#   publicando o evento para o Avisos (ASSINANTES=http://localhost:8083/eventos).
#
# Cada linha de log sai com o nome do serviço na frente, como [cardapio], [avisos] ou [pedidos].
# Ctrl+C derruba os três. Se alguma das três portas já estiver em uso, o script para antes de subir.
#
# Uso, na raiz do repositório:
#   bash scripts/subir.sh
#
# Portas (padrão: as oficiais): PORTA_CARDAPIO=8081 PORTA_PEDIDOS=8082 PORTA_AVISOS=8083
#   Ex.: PORTA_PEDIDOS=9082 bash scripts/subir.sh
# Dados do Pedidos: por padrão numa pasta temporária (cada demonstração começa do pedido 1).
#   Para guardar entre uma subida e outra: DADOS_DIR=servicos/pedidos/dados bash scripts/subir.sh
#
# Precisa de: python3, node (18+), go e curl.
set -u

cd "$(dirname "$0")/.."

PORTA_CARDAPIO=${PORTA_CARDAPIO:-8081}
PORTA_PEDIDOS=${PORTA_PEDIDOS:-8082}
PORTA_AVISOS=${PORTA_AVISOS:-8083}
PYTHON=${PYTHON:-python3}

for programa in "$PYTHON" node go curl; do
  if ! command -v "$programa" > /dev/null 2>&1; then
    echo "Erro: '$programa' não foi encontrado no PATH." >&2
    exit 1
  fi
done

# Nada escuta nessa porta? O curl sai com o código 7 quando a conexão é recusada.
porta_livre() { # porta_livre porta
  curl -s -o /dev/null --max-time 1 "http://localhost:$1/" 2> /dev/null
  [ $? -eq 7 ]
}

# Um serviço esquecido numa das portas (ex.: um Pedidos da Missão 3 em outro terminal) responderia
# no lugar do que este script sobe, e o aviso nunca apareceria aqui. Então para logo no começo.
for porta in "$PORTA_CARDAPIO" "$PORTA_PEDIDOS" "$PORTA_AVISOS"; do
  if ! porta_livre "$porta"; then
    echo "Erro: a porta $porta já está em uso (outro serviço ainda no ar?). Pare o que está nela" >&2
    echo "ou use as variáveis PORTA_*." >&2
    exit 1
  fi
done

TMP=$(mktemp -d)
DADOS_DIR=${DADOS_DIR:-$TMP/dados}
PIDS=""

encerrar() { # encerrar código_de_saída
  trap - INT TERM EXIT
  echo
  echo "Derrubando os serviços..."
  for pid in $PIDS; do
    kill "$pid" 2> /dev/null
  done
  for pid in $PIDS; do
    wait "$pid" 2> /dev/null
  done
  rm -rf "$TMP"
  echo "Pronto: tudo parado."
  exit "$1"
}
# Ctrl+C (INT) e TERM são o jeito normal de parar: saem com 0. EXIT cobre um erro na subida.
trap 'encerrar 0' INT TERM
trap 'encerrar $?' EXIT

# Põe "[nome]" no começo de cada linha. Linhas vazias e linhas que já começam com "[" (como
# "[avisos] ..." ou "[pedidos:8082] ...") passam como estão.
prefixar() {
  local linha
  while IFS= read -r linha; do
    case "$linha" in
      "" | "["*) printf '%s\n' "$linha" ;;
      *) printf '%s %s\n' "$1" "$linha" ;;
    esac
  done
}

# Espera GET /saude responder 200 (até ~10 s).
esperar_saude() { # esperar_saude nome porta pid
  local i
  for i in $(seq 1 100); do
    if curl -fsS -o /dev/null "http://localhost:$2/saude" 2> /dev/null; then
      return 0
    fi
    if ! kill -0 "$3" 2> /dev/null; then
      echo "Erro: $1 parou ao subir (veja a mensagem acima)."
      return 1
    fi
    sleep 0.1
  done
  echo "Erro: $1 não respondeu em http://localhost:$2/saude."
  return 1
}

echo "Compilando o Avisos (Go) numa pasta temporária..."
AVISOS_BIN="$TMP/avisos$(go env GOEXE)"
if ! (cd servicos/avisos && go build -o "$AVISOS_BIN" .); then
  echo "Erro: o Avisos não compilou."
  exit 1
fi

# "> >(prefixar ...)" manda a saída para o prefixar, e "$!" continua sendo o PID do serviço.
PORTA=$PORTA_CARDAPIO "$PYTHON" -u servicos/cardapio/app.py > >(prefixar "[cardapio]") 2>&1 < /dev/null &
PID=$!
PIDS="$PIDS $PID"
esperar_saude Cardápio "$PORTA_CARDAPIO" "$PID" || exit 1

PORTA=$PORTA_AVISOS NOME=avisos "$AVISOS_BIN" > >(prefixar "[avisos]") 2>&1 < /dev/null &
PID=$!
PIDS="$PIDS $PID"
esperar_saude Avisos "$PORTA_AVISOS" "$PID" || exit 1

PORTA=$PORTA_PEDIDOS CARDAPIO_URL="http://localhost:$PORTA_CARDAPIO" DADOS_DIR="$DADOS_DIR" \
  ASSINANTES="http://localhost:$PORTA_AVISOS/eventos" \
  node servicos/pedidos/server.js > >(prefixar "[pedidos]") 2>&1 < /dev/null &
PID=$!
PIDS="$PIDS $PID"
esperar_saude Pedidos "$PORTA_PEDIDOS" "$PID" || exit 1

cat << FIM

----------------------------------------------------------------------
Cantina no ar:
  Cardápio  http://localhost:$PORTA_CARDAPIO/itens
  Pedidos   http://localhost:$PORTA_PEDIDOS/pedidos
  Avisos    http://localhost:$PORTA_AVISOS/eventos  (recebe o evento do Pedidos)

Em outro terminal, na raiz do repositório:
  curl -i -X POST http://localhost:$PORTA_PEDIDOS/pedidos -H "Content-Type: application/json" --data @servicos/pedidos/pedido.json

Aqui deve aparecer: [avisos] Pedido 1 confirmado, total R\$ 25,00
Ctrl+C derruba os três.
----------------------------------------------------------------------

FIM

# Fica aqui até o Ctrl+C (ou até os três pararem sozinhos).
wait
