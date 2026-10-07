// Outbox do Pedidos: a lista de eventos que ainda precisam ser entregues aos assinantes.
//
// Cada entrada é um par (evento, assinante). Ela entra aqui no momento em que o pedido é
// confirmado e só sai quando o assinante aceita o evento (2xx) ou o recusa de vez (400 ou 413).
// Como fica num arquivo (dados/outbox.json), as entregas pendentes sobrevivem a um
// reinício do Pedidos.

const fs = require('node:fs');
const path = require('node:path');
const { gravarJson } = require('./armazenamento');

let arquivo;
let entradas = [];

function abrir(diretorio) {
  fs.mkdirSync(diretorio, { recursive: true });
  arquivo = path.join(diretorio, 'outbox.json');
  if (fs.existsSync(arquivo)) {
    entradas = JSON.parse(fs.readFileSync(arquivo, 'utf8'));
  }
  return arquivo;
}

function pendentes() {
  return [...entradas];
}

// Gravação síncrona e atômica (.tmp + rename), como a dos pedidos.
function adicionar(novas) {
  const novaLista = [...entradas, ...novas];
  gravarJson(arquivo, novaLista);
  entradas = novaLista;
}

function remover(entrada) {
  const novaLista = entradas.filter((e) => e !== entrada);
  gravarJson(arquivo, novaLista);
  entradas = novaLista;
}

module.exports = { abrir, pendentes, adicionar, remover };
