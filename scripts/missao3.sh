#!/usr/bin/env bash
# Missão 3: verificação do Pedidos (Node.js) consultando o Cardápio por HTTP.
#
# Antes, suba os dois serviços (veja servicos/pedidos/README.md):
#   Cardápio na porta 8081 e Pedidos na porta 8082 (CARDAPIO_URL=http://localhost:8081).
#
# Uso, na raiz do repositório:
#   bash scripts/missao3.sh                 cria um pedido, consulta o pedido criado, tenta um item
#                                           indisponível e um inexistente (422) e mostra que o id
#                                           seguinte não foi criado (404). Zera evidencias/missao3.txt.
#   bash scripts/missao3.sh cardapio-fora   derrube o Cardápio (Ctrl+C no terminal dele) ANTES.
#                                           Faz só o POST, mede o tempo do 503 e acrescenta ao arquivo.
#
# O script não derruba nem sobe nenhum serviço sozinho.
set -u

cd "$(dirname "$0")/.."
mkdir -p evidencias
ARQUIVO=evidencias/missao3.txt

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

case "${1:-}" in
  "")
    : > "$ARQUIVO"
    {
      rodar 'curl -i -sS -X POST http://localhost:8082/pedidos -H "Content-Type: application/json" --data "@servicos/pedidos/pedido.json"'

      # O id vem no header Location (/pedidos/{id}) da resposta do POST.
      id=$(printf '%s\n' "$SAIDA" | tr -d '\r' | sed -n 's#^[Ll]ocation: */pedidos/##p')
      if [ -n "$id" ]; then
        rodar "curl -i -sS http://localhost:8082/pedidos/$id"
      else
        echo "(o POST não devolveu Location, então não há pedido para consultar)"
        echo
      fi

      rodar 'curl -i -sS -X POST http://localhost:8082/pedidos -H "Content-Type: application/json" --data "@servicos/pedidos/pedido-indisponivel.json"'
      rodar 'curl -i -sS -X POST http://localhost:8082/pedidos -H "Content-Type: application/json" --data "@servicos/pedidos/pedido-inexistente.json"'

      # Prova de que os dois 422 não criaram pedido: o id seguinte continua sem existir (404).
      if [ -n "$id" ]; then
        rodar "curl -i -sS http://localhost:8082/pedidos/$((id + 1))"
      fi
    } 2>&1 | tee -a "$ARQUIVO"
    ;;
  cardapio-fora)
    {
      echo "# Cardápio fora do ar: o Pedidos deve responder 503 em no máximo ~2 s."
      echo
      rodar "curl -i -sS -X POST http://localhost:8082/pedidos -H \"Content-Type: application/json\" --data \"@servicos/pedidos/pedido.json\" -w '\ntempo_total=%{time_total}s\n'"
    } 2>&1 | tee -a "$ARQUIVO"
    ;;
  *)
    echo "Uso: bash scripts/missao3.sh [cardapio-fora]" >&2
    exit 1
    ;;
esac
