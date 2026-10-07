#!/usr/bin/env bash
# Missão 2: verificação do Cardápio. Antes, suba as duas instâncias
# (PORTA=8081 e PORTA=8091, veja servicos/cardapio/README.md).
set -u

cd "$(dirname "$0")/.."
mkdir -p evidencias

{
  for url in \
    http://localhost:8081/itens \
    http://localhost:8081/itens/1 \
    http://localhost:8081/itens/99 \
    http://localhost:8091/itens/1 \
    http://localhost:8081/saude
  do
    echo "\$ curl -i $url"
    curl -i -s "$url" || echo "(falhou: o serviço está no ar nessa porta?)"
    echo
    echo
  done
} 2>&1 | tee evidencias/missao2.txt
