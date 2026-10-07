#!/usr/bin/env bash
# Missão 4: o Pedidos publica cantina.pedido.confirmado e o Avisos reage (Trilha A, webhook).
#
# O script é automático: ele mesmo compila o Avisos, sobe e derruba quatro processos (o Cardápio,
# o Pedidos e dois Avisos), em quatro portas, e mostra cada passo. Não precisa subir nada antes;
# as portas só precisam estar livres (o script confere isso antes de começar e para com erro).
#
#   Passo 1  Cardápio, Avisos e Pedidos no ar; um pedido gera o aviso no Avisos.
#   Passo 2  Avisos fora do ar: o pedido sai 201 do mesmo jeito, e rápido; o Pedidos vai reenviar.
#   Passo 3  Avisos de volta: o reenvio chega e o aviso do pedido 2 aparece (nada se perdeu).
#   Passo 4  Deduplicação: o mesmo evento do pedido 2 (mesmo source e id) é mandado de novo,
#            direto ao Avisos, com curl. Ele responde 202 e loga "repetido, ignorado", sem novo aviso.
#   Passo 5  A outbox sobrevive a um reinício: com o Avisos fora, sai o pedido 3; o Pedidos é
#            reiniciado (mesmo DADOS_DIR); o Avisos volta e o evento do pedido 3 chega uma vez só.
#   Passo 6  Um segundo Avisos (avisos-2, porta 8084) só por configuração: muda ASSINANTES e
#            reinicia o Pedidos, sem mudar o código. Os dois recebem o pedido 4.
#   Passo 7  O script derruba os quatro processos e confere que as portas ficaram livres.
#
# Uso, na raiz do repositório:
#   bash scripts/missao4.sh               grava a saída em evidencias/missao4.txt
#   bash scripts/missao4.sh --sem-gravar  só mostra na tela (para testar)
#
# Gravação segura: a saída vai primeiro para um arquivo temporário e só substitui
# evidencias/missao4.txt se o roteiro terminar com todas as conferências [ok]. Com Ctrl+C ou
# com alguma falha, o arquivo antigo fica como estava.
#
# Portas (padrão: as oficiais): PORTA_CARDAPIO=8081 PORTA_PEDIDOS=8082 PORTA_AVISOS=8083 PORTA_AVISOS2=8084
#   Ex.: PORTA_PEDIDOS=9082 bash scripts/missao4.sh --sem-gravar
#
# Precisa de: python3, node (18+), go e curl. Logs e dados ficam numa pasta temporária,
# apagada no fim (inclusive com Ctrl+C).
set -u

cd "$(dirname "$0")/.."

PORTA_CARDAPIO=${PORTA_CARDAPIO:-8081}
PORTA_PEDIDOS=${PORTA_PEDIDOS:-8082}
PORTA_AVISOS=${PORTA_AVISOS:-8083}
PORTA_AVISOS2=${PORTA_AVISOS2:-8084}
PYTHON=${PYTHON:-python3}

GRAVAR=sim
case "${1:-}" in
  "") ;;
  --sem-gravar) GRAVAR=nao ;;
  *)
    echo "Uso: bash scripts/missao4.sh [--sem-gravar]" >&2
    exit 1
    ;;
esac

for programa in "$PYTHON" node go curl; do
  if ! command -v "$programa" > /dev/null 2>&1; then
    echo "Erro: '$programa' não foi encontrado no PATH." >&2
    exit 1
  fi
done

PEDIDO=servicos/pedidos/pedido.json
ASSINANTE1="http://localhost:$PORTA_AVISOS/eventos"
ASSINANTE2="http://localhost:$PORTA_AVISOS2/eventos"

# ---------- funções de apoio ----------

# Imprime "$ <comando>" e a saída, como apareceria no terminal. A saída fica em SAIDA.
rodar() {
  echo
  echo "\$ $1"
  SAIDA=$(eval "$1" 2>&1)
  echo "$SAIDA"
}

passo() {
  echo
  echo "## Passo $1 · $2"
  echo
}

FALHAS=0
conferir() { # conferir "descrição" condição...
  local descricao=$1
  shift
  if "$@"; then
    echo "  [ok] $descricao"
  else
    echo "  [FALHOU] $descricao"
    FALHAS=$((FALHAS + 1))
  fi
}

# Espera GET /saude responder 200 (até ~10 s). Se o processo morrer antes, mostra o log dele.
esperar_saude() { # esperar_saude nome porta pid log
  local i
  for i in $(seq 1 100); do
    if curl -fsS -o /dev/null "http://localhost:$2/saude" 2> /dev/null; then
      return 0
    fi
    if ! kill -0 "$3" 2> /dev/null; then
      echo "Erro: $1 parou ao subir. Log:"
      cat "$4"
      return 1
    fi
    sleep 0.1
  done
  echo "Erro: $1 não respondeu em http://localhost:$2/saude. Log:"
  cat "$4"
  return 1
}

# Espera um texto aparecer num log (até o tempo dado, em segundos).
esperar_log() { # esperar_log arquivo texto segundos
  local i
  for i in $(seq 1 $(($3 * 10))); do
    if grep -qF -- "$2" "$1" 2> /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Espera a outbox do Pedidos ficar vazia ("[]"), até o tempo dado, em segundos.
esperar_outbox_vazia() { # esperar_outbox_vazia segundos
  local i
  for i in $(seq 1 $(($1 * 10))); do
    if grep -q '^\[\]$' "$DADOS_DIR/outbox.json" 2> /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Nada escuta nessa porta? O curl sai com o código 7 quando a conexão é recusada.
porta_livre() { # porta_livre porta
  curl -s -o /dev/null --max-time 1 "http://localhost:$1/" 2> /dev/null
  [ $? -eq 7 ]
}

# Antes de tudo: as quatro portas precisam estar livres. Um serviço esquecido numa delas
# (ex.: um Avisos de outro terminal) responderia no lugar do que o script sobe.
for porta in "$PORTA_CARDAPIO" "$PORTA_PEDIDOS" "$PORTA_AVISOS" "$PORTA_AVISOS2"; do
  if ! porta_livre "$porta"; then
    echo "Erro: a porta $porta já está em uso. Pare o que está nela (ou use as variáveis PORTA_*)." >&2
    echo "Nada foi gravado em evidencias/missao4.txt." >&2
    exit 1
  fi
done

# Hash dos arquivos de código do Pedidos (sha1sum no Linux e Git Bash, shasum no macOS).
if command -v sha1sum > /dev/null 2>&1; then
  HASH=sha1sum
else
  HASH=shasum
fi

# ---------- subir e derrubar ----------

TMP=$(mktemp -d)
DADOS_DIR="$TMP/dados"
# Todo serviço que o script sobe entra em PIDS na mesma hora (antes de esperar o /saude),
# para o derrubar() parar até o que estava subindo quando veio o Ctrl+C.
PIDS=""

# Para todos os serviços que o script subiu e espera cada um terminar.
derrubar() {
  for pid in $PIDS; do
    kill "$pid" 2> /dev/null
  done
  for pid in $PIDS; do
    wait "$pid" 2> /dev/null
  done
  PIDS=""
}

# Derruba tudo e apaga a pasta temporária. Pode ser chamada mais de uma vez.
limpar() {
  derrubar
  rm -rf "$TMP"
}

subir_cardapio() {
  PORTA=$PORTA_CARDAPIO "$PYTHON" -u servicos/cardapio/app.py >> "$TMP/cardapio.log" 2>&1 < /dev/null &
  PID_CARDAPIO=$!
  PIDS="$PIDS $!"
  esperar_saude Cardápio "$PORTA_CARDAPIO" "$PID_CARDAPIO" "$TMP/cardapio.log"
}

subir_avisos() { # subir_avisos nome porta log -> PID em PID_NOVO
  PORTA=$2 NOME=$1 "$AVISOS_BIN" >> "$3" 2>&1 < /dev/null &
  PID_NOVO=$!
  PIDS="$PIDS $!"
  esperar_saude "$1" "$2" "$PID_NOVO" "$3"
}

subir_pedidos() { # subir_pedidos "lista de assinantes"
  PORTA=$PORTA_PEDIDOS CARDAPIO_URL="http://localhost:$PORTA_CARDAPIO" DADOS_DIR="$DADOS_DIR" ASSINANTES="$1" \
    node servicos/pedidos/server.js >> "$TMP/pedidos.log" 2>&1 < /dev/null &
  PID_PEDIDOS=$!
  PIDS="$PIDS $!"
  esperar_saude Pedidos "$PORTA_PEDIDOS" "$PID_PEDIDOS" "$TMP/pedidos.log"
}

parar() { # parar pid
  kill "$1" 2> /dev/null
  wait "$1" 2> /dev/null
}

# Código HTTP da última resposta guardada em SAIDA (curl -i).
status_http() {
  printf '%s\n' "$SAIDA" | tr -d '\r' | sed -n 's#^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p' | tail -n 1
}

# ---------- roteiro ----------

roteiro() {
  echo "# Missão 4: evento cantina.pedido.confirmado (Trilha A, webhook)"
  echo "# $(date '+%d/%m/%Y %H:%M:%S') · node $(node --version) · $(go version | cut -d' ' -f3) · $("$PYTHON" --version 2>&1)"
  echo "# Portas: Cardápio $PORTA_CARDAPIO, Pedidos $PORTA_PEDIDOS, Avisos $PORTA_AVISOS e $PORTA_AVISOS2"
  echo "# TMP=$TMP (logs e DADOS_DIR do Pedidos; apagada no fim)"

  AVISOS_BIN="$TMP/avisos$(go env GOEXE)"
  echo
  echo "\$ (cd servicos/avisos && go build -o \"\$TMP/avisos\" .)"
  if ! (cd servicos/avisos && go build -o "$AVISOS_BIN" .); then
    echo "Erro: o Avisos não compilou."
    return 1
  fi

  # ----- Passo 1 -----
  passo 1 "Cardápio, Avisos e Pedidos no ar; um pedido gera o aviso"
  echo "\$ PORTA=$PORTA_CARDAPIO python3 servicos/cardapio/app.py &"
  subir_cardapio || return 1
  echo "\$ PORTA=$PORTA_AVISOS NOME=avisos \"\$TMP/avisos\" &"
  subir_avisos avisos "$PORTA_AVISOS" "$TMP/avisos.log" || return 1
  PID_AVISOS=$PID_NOVO
  echo "\$ PORTA=$PORTA_PEDIDOS CARDAPIO_URL=http://localhost:$PORTA_CARDAPIO DADOS_DIR=\"\$TMP/dados\" ASSINANTES=$ASSINANTE1 node servicos/pedidos/server.js &"
  subir_pedidos "$ASSINANTE1" || return 1
  echo "(os três responderam 200 em /saude)"

  rodar "curl -i -sS -X POST http://localhost:$PORTA_PEDIDOS/pedidos -H \"Content-Type: application/json\" --data @$PEDIDO"
  conferir "POST /pedidos respondeu 201" test "$(status_http)" = 201

  esperar_log "$TMP/avisos.log" "Pedido 1 confirmado" 5
  rodar "grep \"Pedido 1 \" \"\$TMP/avisos.log\""
  conferir "o Avisos registrou o pedido 1 (R\$ 25,00)" grep -qF "Pedido 1 confirmado, total R\$ 25,00" "$TMP/avisos.log"

  # ----- Passo 2 -----
  passo 2 "Avisos fora do ar: o pedido sai 201 mesmo assim, sem esperar"
  echo "\$ kill $PID_AVISOS   # o Avisos ($PORTA_AVISOS)"
  parar "$PID_AVISOS"

  rodar "curl -i -sS -X POST http://localhost:$PORTA_PEDIDOS/pedidos -H \"Content-Type: application/json\" --data @$PEDIDO -w '\ntempo_total=%{time_total}s\n'"
  conferir "POST /pedidos respondeu 201 com o Avisos fora" test "$(status_http)" = 201
  TEMPO=$(printf '%s\n' "$SAIDA" | sed -n 's/^tempo_total=\([0-9.]*\)s$/\1/p')
  conferir "a resposta veio em menos de 1 s (foi em ${TEMPO:-?} s)" awk -v t="${TEMPO:-9}" 'BEGIN { exit !(t < 1) }'

  esperar_log "$TMP/pedidos.log" "nova tentativa" 5
  rodar "grep -m 2 \"nova tentativa\" \"\$TMP/pedidos.log\""
  conferir "o Pedidos avisou que vai tentar de novo" grep -qF "nova tentativa" "$TMP/pedidos.log"

  rodar "cat \"\$TMP/dados/outbox.json\""
  conferir "o evento do pedido 2 está guardado na outbox" grep -q '"pedidoId": 2' "$DADOS_DIR/outbox.json"
  # Cópia exata do evento do pedido 2, para o Passo 4 mandar o mesmo evento de novo.
  node -e 'const o = require(process.argv[1]); process.stdout.write(JSON.stringify(o[0].evento))' \
    "$DADOS_DIR/outbox.json" > "$TMP/evento-pedido2.json"
  echo "(o script guarda uma cópia deste evento em \$TMP/evento-pedido2.json para o Passo 4)"

  # ----- Passo 3 -----
  passo 3 "Avisos de volta: o reenvio entrega o pedido 2"
  echo "\$ PORTA=$PORTA_AVISOS NOME=avisos \"\$TMP/avisos\" &"
  subir_avisos avisos "$PORTA_AVISOS" "$TMP/avisos.log" || return 1
  PID_AVISOS=$PID_NOVO
  echo "(Avisos de novo no ar; o Pedidos tenta de novo 3 s depois de cada tentativa que falhou)"
  esperar_log "$TMP/avisos.log" "Pedido 2 confirmado" 10

  # As duas últimas linhas do log: o Avisos volta ("ouvindo") e SÓ DEPOIS chega o pedido 2.
  rodar "tail -n 2 \"\$TMP/avisos.log\""
  conferir "o Avisos registrou o pedido 2 depois de voltar" grep -qF "Pedido 2 confirmado, total R\$ 25,00" "$TMP/avisos.log"
  rodar "grep \"entregue\" \"\$TMP/pedidos.log\""
  rodar "cat \"\$TMP/dados/outbox.json\""
  conferir "a outbox ficou vazia" grep -q '^\[\]$' "$DADOS_DIR/outbox.json"

  # ----- Passo 4 -----
  passo 4 "Deduplicação: o mesmo evento chega de novo e não gera outro aviso"
  ID_PEDIDO2=$(node -e 'process.stdout.write(require(process.argv[1]).id)' "$TMP/evento-pedido2.json")
  rodar "cat \"\$TMP/evento-pedido2.json\""
  conferir "é o evento que o Pedidos já entregou no Passo 3 (id $ID_PEDIDO2)" grep -qF "evento $ID_PEDIDO2 entregue a $ASSINANTE1" "$TMP/pedidos.log"
  rodar "curl -i -sS -X POST $ASSINANTE1 -H \"Content-Type: application/cloudevents+json\" --data-binary @\"\$TMP/evento-pedido2.json\""
  conferir "o Avisos respondeu 202 ao evento repetido" test "$(status_http)" = 202
  esperar_log "$TMP/avisos.log" "evento $ID_PEDIDO2 repetido, ignorado" 5
  rodar "tail -n 1 \"\$TMP/avisos.log\""
  conferir "o Avisos logou \"repetido, ignorado\"" grep -qF "evento $ID_PEDIDO2 repetido, ignorado" "$TMP/avisos.log"
  rodar "grep -c \"Pedido 2 confirmado\" \"\$TMP/avisos.log\""
  conferir "o aviso do pedido 2 aparece uma vez só" test "$SAIDA" = 1

  # ----- Passo 5 -----
  passo 5 "A outbox sobrevive a um reinício do Pedidos"
  echo "\$ kill $PID_AVISOS   # o Avisos ($PORTA_AVISOS)"
  parar "$PID_AVISOS"
  rodar "curl -i -sS -X POST http://localhost:$PORTA_PEDIDOS/pedidos -H \"Content-Type: application/json\" --data @$PEDIDO"
  conferir "POST /pedidos respondeu 201 com o Avisos fora" test "$(status_http)" = 201
  rodar "cat \"\$TMP/dados/outbox.json\""
  conferir "o evento do pedido 3 está guardado na outbox" grep -q '"pedidoId": 3' "$DADOS_DIR/outbox.json"

  echo
  echo "\$ kill $PID_PEDIDOS   # o Pedidos ($PORTA_PEDIDOS), com a entrega do pedido 3 pendente"
  parar "$PID_PEDIDOS"
  echo "\$ PORTA=$PORTA_PEDIDOS CARDAPIO_URL=http://localhost:$PORTA_CARDAPIO DADOS_DIR=\"\$TMP/dados\" ASSINANTES=$ASSINANTE1 node servicos/pedidos/server.js &"
  subir_pedidos "$ASSINANTE1" || return 1
  rodar "grep \"entregas pendentes\" \"\$TMP/pedidos.log\" | tail -n 1"
  conferir "o Pedidos reiniciado achou 1 entrega pendente na outbox" grep -qF "(1 entregas pendentes)" "$TMP/pedidos.log"

  echo
  echo "\$ PORTA=$PORTA_AVISOS NOME=avisos \"\$TMP/avisos\" &"
  subir_avisos avisos "$PORTA_AVISOS" "$TMP/avisos.log" || return 1
  PID_AVISOS=$PID_NOVO
  echo "(Avisos de novo no ar; esperando o reenvio e a outbox esvaziar)"
  esperar_log "$TMP/avisos.log" "Pedido 3 confirmado" 10
  esperar_outbox_vazia 10
  rodar "grep -c \"Pedido 3 confirmado\" \"\$TMP/avisos.log\""
  conferir "o aviso do pedido 3 chegou exatamente uma vez" test "$SAIDA" = 1
  rodar "cat \"\$TMP/dados/outbox.json\""
  conferir "a outbox ficou vazia (não sobrou reenvio)" grep -q '^\[\]$' "$DADOS_DIR/outbox.json"

  # ----- Passo 6 -----
  passo 6 "Segundo consumidor: muda ASSINANTES e reinicia o Pedidos, sem mudar o código"
  echo "\$ $HASH servicos/pedidos/*.js"
  HASH_ANTES=$($HASH servicos/pedidos/*.js)
  echo "$HASH_ANTES"
  echo

  echo "\$ PORTA=$PORTA_AVISOS2 NOME=avisos-2 \"\$TMP/avisos\" &"
  subir_avisos avisos-2 "$PORTA_AVISOS2" "$TMP/avisos-2.log" || return 1
  echo "\$ kill $PID_PEDIDOS   # o Pedidos ($PORTA_PEDIDOS)"
  parar "$PID_PEDIDOS"
  echo "\$ PORTA=$PORTA_PEDIDOS CARDAPIO_URL=http://localhost:$PORTA_CARDAPIO DADOS_DIR=\"\$TMP/dados\" ASSINANTES=$ASSINANTE1,$ASSINANTE2 node servicos/pedidos/server.js &"
  subir_pedidos "$ASSINANTE1,$ASSINANTE2" || return 1

  rodar "grep \"Assinantes\" \"\$TMP/pedidos.log\" | tail -n 1"
  rodar "curl -i -sS -X POST http://localhost:$PORTA_PEDIDOS/pedidos -H \"Content-Type: application/json\" --data @$PEDIDO"
  conferir "POST /pedidos respondeu 201" test "$(status_http)" = 201

  esperar_log "$TMP/avisos.log" "Pedido 4 confirmado" 5
  esperar_log "$TMP/avisos-2.log" "Pedido 4 confirmado" 5
  rodar "grep -h \"Pedido 4 \" \"\$TMP/avisos.log\" \"\$TMP/avisos-2.log\""
  conferir "avisos ($PORTA_AVISOS) registrou o pedido 4" grep -qF "Pedido 4 confirmado" "$TMP/avisos.log"
  conferir "avisos-2 ($PORTA_AVISOS2) registrou o pedido 4" grep -qF "Pedido 4 confirmado" "$TMP/avisos-2.log"

  rodar "$HASH servicos/pedidos/*.js"
  conferir "o código do Pedidos não mudou (mesmo hash antes e depois)" test "$HASH_ANTES" = "$SAIDA"

  # ----- fim: derrubar tudo -----
  passo 7 "Fim: o script derruba os quatro processos e confere que as portas ficaram livres"
  echo "\$ kill <PIDs do Cardápio, dos dois Avisos e do Pedidos>"
  derrubar
  for porta in "$PORTA_CARDAPIO" "$PORTA_PEDIDOS" "$PORTA_AVISOS" "$PORTA_AVISOS2"; do
    conferir "nada escuta mais na porta $porta" porta_livre "$porta"
  done

  # ----- saída completa -----
  echo
  echo "## Saída do Avisos"
  rodar "cat \"\$TMP/avisos.log\""
  rodar "cat \"\$TMP/avisos-2.log\""
  echo
  echo "## Saída do Pedidos"
  rodar "cat \"\$TMP/pedidos.log\""

  echo
  echo "## Resultado"
  echo
  if [ "$FALHAS" -eq 0 ]; then
    echo "Tudo certo: todas as conferências passaram."
    return 0
  fi
  echo "$FALHAS conferência(s) falharam. Veja as linhas [FALHOU] acima."
  return 1
}

# Roda o roteiro e SEMPRE derruba os serviços no fim, dando certo ou não. A limpeza é chamada
# aqui, de forma explícita: com o roteiro do lado esquerdo de um "|" (para o tee), ele roda num
# subshell, e o bash 3.2 do macOS não executa o "trap ... EXIT" de um subshell. Os traps ficam
# só para o Ctrl+C no meio do caminho.
executar() {
  trap 'limpar; exit 130' INT TERM
  trap limpar EXIT
  roteiro
  local status=$?
  limpar
  return "$status"
}

if [ "$GRAVAR" = sim ]; then
  mkdir -p evidencias
  SAIDA_TMP=$(mktemp)
  trap 'rm -f "$SAIDA_TMP"' EXIT
  # O Ctrl+C também chega aqui: o script espera o roteiro derrubar tudo e então decide.
  trap ':' INT
  # O tee ignora o Ctrl+C: assim ele continua gravando enquanto o roteiro derruba os serviços.
  executar 2>&1 | (trap '' INT; tee "$SAIDA_TMP")
  STATUS=${PIPESTATUS[0]}
  echo
  if [ "$STATUS" -eq 0 ]; then
    cat "$SAIDA_TMP" > evidencias/missao4.txt
    echo "(saída gravada em evidencias/missao4.txt)"
  else
    echo "(o roteiro foi interrompido ou alguma conferência falhou, código $STATUS: evidencias/missao4.txt NÃO foi alterado)"
  fi
  exit "$STATUS"
fi
executar 2>&1
