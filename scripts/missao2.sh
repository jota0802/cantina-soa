#!/usr/bin/env bash
# Missão 2: verificação do Cardápio. Antes, suba as duas instâncias
# (PORTA=8081 e PORTA=8091, veja servicos/cardapio/README.md).
#
# Uso, na raiz do repositório:
#   bash scripts/missao2.sh      roda os cinco curl e grava (zera) evidencias/missao2.txt
#
# Portas (padrão: as oficiais): PORTA_CARDAPIO=8081 PORTA_CARDAPIO2=8091
#   Ex.: PORTA_CARDAPIO=9081 PORTA_CARDAPIO2=9091 bash scripts/missao2.sh
set -u

cd "$(dirname "$0")/.."
mkdir -p evidencias

PORTA_CARDAPIO=${PORTA_CARDAPIO:-8081}
PORTA_CARDAPIO2=${PORTA_CARDAPIO2:-8091}

{
  for url in \
    "http://localhost:$PORTA_CARDAPIO/itens" \
    "http://localhost:$PORTA_CARDAPIO/itens/1" \
    "http://localhost:$PORTA_CARDAPIO/itens/99" \
    "http://localhost:$PORTA_CARDAPIO2/itens/1" \
    "http://localhost:$PORTA_CARDAPIO/saude"
  do
    echo "\$ curl -i $url"
    curl -i -s "$url" || echo "(falhou: o serviço está no ar nessa porta?)"
    echo
    echo
  done
} 2>&1 | tee evidencias/missao2.txt
