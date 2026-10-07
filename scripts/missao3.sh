#!/usr/bin/env bash
# Missão 3: verificação do Pedidos (Node.js) consultando o Cardápio por HTTP.
#
# Antes, suba os dois serviços (veja servicos/pedidos/README.md):
#   Cardápio na porta 8081 e Pedidos na porta 8082 (CARDAPIO_URL=http://localhost:8081).
#
# Uso, na raiz do repositório:
#   bash scripts/missao3.sh                 cria um pedido, consulta o pedido criado, tenta um item
#                                           indisponível e um inexistente (422) e mostra que o id
#                                           seguinte não foi criado (404). ZERA evidencias/missao3.txt.
#   bash scripts/missao3.sh cardapio-fora   com o Cardápio parado (Ctrl+C no terminal dele) e o
#                                           Pedidos no ar. Confere antes que o Cardápio está mesmo
#                                           fora, faz o POST, mede o tempo do 503 e ACRESCENTA ao arquivo.
#   bash scripts/missao3.sh cardapio-lento  também com o Cardápio parado. O script ocupa a porta do
#                                           Cardápio com um simulador em Python que aceita a conexão
#                                           e nunca responde, faz o POST, mede o tempo do 503,
#                                           derruba o simulador e ACRESCENTA ao arquivo.
#
# Ordem sugerida: o modo padrão, depois pare o Cardápio e rode cardapio-fora e cardapio-lento.
# O script não derruba nem sobe o Cardápio e o Pedidos (só o simulador do modo cardapio-lento).
#
# Portas (padrão: as oficiais): PORTA_CARDAPIO=8081 PORTA_PEDIDOS=8082
#   Ex.: PORTA_CARDAPIO=9081 PORTA_PEDIDOS=9082 bash scripts/missao3.sh
#   (o Pedidos precisa ter subido com CARDAPIO_URL apontando para a mesma PORTA_CARDAPIO)
set -u

cd "$(dirname "$0")/.."
mkdir -p evidencias
ARQUIVO=evidencias/missao3.txt
PORTA_CARDAPIO=${PORTA_CARDAPIO:-8081}
PORTA_PEDIDOS=${PORTA_PEDIDOS:-8082}
PYTHON=${PYTHON:-python3}
PEDIDOS="http://localhost:$PORTA_PEDIDOS"

# Imprime "$ <comando>" e a saída, como apareceria no terminal. A saída fica em SAIDA.
rodar() {
  echo "\$ $1"
  if ! SAIDA=$(eval "$1" 2>&1); then
    SAIDA="$SAIDA
(o comando falhou: o serviço está no ar nessa porta?)"
  fi
  echo "$SAIDA"
  echo
  echo
}

# O serviço responde 200 em GET /saude?
no_ar() { # no_ar porta
  curl -fsS -o /dev/null --max-time 2 "http://localhost:$1/saude" 2> /dev/null
}

# Os modos de falha precisam do Pedidos no ar e do Cardápio fora; senão a evidência sairia errada.
exigir_cardapio_fora() {
  if ! no_ar "$PORTA_PEDIDOS"; then
    echo "Erro: o Pedidos não respondeu em $PEDIDOS/saude. Suba o Pedidos antes." >&2
    exit 1
  fi
  if no_ar "$PORTA_CARDAPIO"; then
    echo "Erro: o Cardápio ainda está no ar na porta $PORTA_CARDAPIO. Pare o Cardápio (Ctrl+C no" >&2
    echo "terminal dele) e rode de novo. Nada foi gravado em $ARQUIVO." >&2
    exit 1
  fi
}

POST_COM_TEMPO="curl -i -sS -X POST $PEDIDOS/pedidos -H \"Content-Type: application/json\" --data \"@servicos/pedidos/pedido.json\" -w '\ntempo_total=%{time_total}s\n'"

case "${1:-}" in
  "")
    : > "$ARQUIVO"
    {
      rodar "curl -i -sS -X POST $PEDIDOS/pedidos -H \"Content-Type: application/json\" --data \"@servicos/pedidos/pedido.json\""

      # O id vem no header Location (/pedidos/{id}) da resposta do POST.
      id=$(printf '%s\n' "$SAIDA" | tr -d '\r' | sed -n 's#^[Ll]ocation: */pedidos/##p')
      if [ -n "$id" ]; then
        rodar "curl -i -sS $PEDIDOS/pedidos/$id"
      else
        echo "(o POST não devolveu Location, então não há pedido para consultar)"
        echo
      fi

      rodar "curl -i -sS -X POST $PEDIDOS/pedidos -H \"Content-Type: application/json\" --data \"@servicos/pedidos/pedido-indisponivel.json\""
      rodar "curl -i -sS -X POST $PEDIDOS/pedidos -H \"Content-Type: application/json\" --data \"@servicos/pedidos/pedido-inexistente.json\""

      # Prova de que os dois 422 não criaram pedido: o id seguinte continua sem existir (404).
      if [ -n "$id" ]; then
        rodar "curl -i -sS $PEDIDOS/pedidos/$((id + 1))"
      fi
    } 2>&1 | tee -a "$ARQUIVO"
    ;;

  cardapio-fora)
    exigir_cardapio_fora
    {
      echo "# Cardápio fora do ar (conferido antes: GET http://localhost:$PORTA_CARDAPIO/saude falhou)."
      echo "# O Pedidos deve responder 503 em no máximo ~2 s."
      echo
      rodar "$POST_COM_TEMPO"
    } 2>&1 | tee -a "$ARQUIVO"
    ;;

  cardapio-lento)
    exigir_cardapio_fora

    # Simulador de Cardápio lento: aceita cada conexão e nunca responde nada.
    PRONTO=$(mktemp)
    "$PYTHON" -u -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(16)
print("pronto")
abertas = []
while True:
    conexao, _ = s.accept()
    abertas.append(conexao)  # guarda a conexão aberta e nunca responde
' "$PORTA_CARDAPIO" > "$PRONTO" 2>&1 &
    PID_LENTO=$!
    # Derruba o simulador no fim, dando certo ou não (inclusive com Ctrl+C).
    trap 'kill "$PID_LENTO" 2> /dev/null; wait "$PID_LENTO" 2> /dev/null; rm -f "$PRONTO"' EXIT
    trap 'exit 130' INT TERM

    for _ in $(seq 1 50); do
      grep -q pronto "$PRONTO" && break
      if ! kill -0 "$PID_LENTO" 2> /dev/null; then
        break
      fi
      sleep 0.1
    done
    if ! grep -q pronto "$PRONTO"; then
      echo "Erro: o simulador não conseguiu ocupar a porta $PORTA_CARDAPIO:" >&2
      cat "$PRONTO" >&2
      exit 1
    fi

    {
      echo "# Cardápio lento (simulado). O Cardápio de verdade estava fora (conferido antes); o script"
      echo "# ocupou a porta $PORTA_CARDAPIO com um programa de teste em Python (socket) que aceita a"
      echo "# conexão e nunca responde. O Pedidos deve desistir em 2 s e responder 503."
      echo
      rodar "$POST_COM_TEMPO"
    } 2>&1 | tee -a "$ARQUIVO"
    ;;

  *)
    echo "Uso: bash scripts/missao3.sh [cardapio-fora | cardapio-lento]" >&2
    exit 1
    ;;
esac
