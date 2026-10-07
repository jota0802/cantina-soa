"""Serviço Cardápio da Cantina.

Segue o contrato em contratos/cardapio.yaml. Usa só a biblioteca padrão do Python 3.
"""

import json
import os
import re
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

PASTA = os.path.dirname(os.path.abspath(__file__))
ARQUIVO_ITENS = os.path.join(PASTA, "itens.json")


def carregar_itens():
    with open(ARQUIVO_ITENS, encoding="utf-8") as arquivo:
        return json.load(arquivo)


# Dado de referência, igual em todas as instâncias. Nada sobre quem chama é guardado.
ITENS = carregar_itens()


def buscar_item(item_id):
    for item in ITENS:
        if item["id"] == item_id:
            return item
    return None


class CardapioHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        # unquote: /itens/%31 é o mesmo endereço que /itens/1.
        caminho = unquote(urlsplit(self.path).path)
        if caminho != "/":
            caminho = caminho.rstrip("/")
        rota_item = re.fullmatch(r"/itens/([^/]+)", caminho)

        if caminho == "/saude":
            self.responder(200, {"status": "ok", "servico": "cardapio"})
        elif caminho == "/itens":
            self.responder(200, ITENS)
        elif rota_item:
            self.responder_item(rota_item.group(1))
        else:
            self.responder(404, {
                "codigo": "rota_inexistente",
                "mensagem": "Rota não encontrada: " + caminho,
            })

    def responder_item(self, parte_id):
        # O contrato diz que o id é inteiro; qualquer outra coisa é um item que não existe.
        item = None
        if re.fullmatch(r"[0-9]+", parte_id):
            item = buscar_item(int(parte_id))

        if item is None:
            self.responder(404, {
                "codigo": "item_inexistente",
                "mensagem": "O item " + parte_id + " não existe no cardápio.",
            })
        else:
            self.responder(200, item)

    def metodo_nao_permitido(self):
        self.responder(405, {
            "codigo": "metodo_nao_permitido",
            "mensagem": "O Cardápio só aceita GET.",
        }, {"Allow": "GET"})

    do_POST = metodo_nao_permitido
    do_PUT = metodo_nao_permitido
    do_PATCH = metodo_nao_permitido
    do_DELETE = metodo_nao_permitido
    do_HEAD = metodo_nao_permitido
    do_OPTIONS = metodo_nao_permitido

    def responder(self, status, corpo, cabecalhos=None):
        dados = json.dumps(corpo, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(dados)))
        for nome, valor in (cabecalhos or {}).items():
            self.send_header(nome, valor)
        self.end_headers()
        if self.command != "HEAD":  # resposta a HEAD não leva corpo
            self.wfile.write(dados)
        porta = self.server.server_address[1]
        print("[cardapio:%d] %s %s -> %d" % (porta, self.command, self.path, status), flush=True)

    def log_message(self, formato, *args):
        # Silencia o log padrão (stderr); o nosso sai em uma linha no stdout, em responder().
        pass


class ServidorCardapio(ThreadingHTTPServer):
    # Escuta em IPv4 e IPv6 ao mesmo tempo, em todas as interfaces: "localhost" vira ::1 em
    # alguns clientes (Node 18, por exemplo) e outro grupo precisa alcançar pelo IP da rede.
    if socket.has_dualstack_ipv6():
        address_family = socket.AF_INET6

    def server_bind(self):
        if self.address_family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def main():
    porta_texto = os.environ.get("PORTA")
    if not porta_texto:
        print("Erro: defina a variável de ambiente PORTA (ex.: PORTA=8081 python3 app.py).", file=sys.stderr)
        sys.exit(1)
    if not re.fullmatch(r"[0-9]+", porta_texto) or not 1 <= int(porta_texto) <= 65535:
        print("Erro: PORTA precisa ser um número de 1 a 65535, recebi '%s'." % porta_texto, file=sys.stderr)
        sys.exit(1)

    porta = int(porta_texto)
    try:
        servidor = ServidorCardapio(("", porta), CardapioHandler)
    except OSError as erro:
        print("Erro: não consegui abrir a porta %d (%s). Ela já está em uso?" % (porta, erro.strerror), file=sys.stderr)
        sys.exit(1)
    print("Cardápio no ar em http://localhost:%d (%d itens)" % (porta, len(ITENS)), flush=True)
    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        print("\nCardápio encerrado.", flush=True)
    finally:
        servidor.server_close()


if __name__ == "__main__":
    main()
