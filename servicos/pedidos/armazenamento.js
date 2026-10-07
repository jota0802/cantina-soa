// Armazenamento do Pedidos: um arquivo JSON que só este serviço lê e escreve.

const fs = require('node:fs');
const path = require('node:path');

let arquivo;
let pedidos = [];

function abrir(diretorio) {
  fs.mkdirSync(diretorio, { recursive: true });
  arquivo = path.join(diretorio, 'pedidos.json');
  if (fs.existsSync(arquivo)) {
    pedidos = JSON.parse(fs.readFileSync(arquivo, 'utf8'));
  }
  return arquivo;
}

function quantidade() {
  return pedidos.length;
}

function buscar(id) {
  return pedidos.find((pedido) => pedido.id === id) || null;
}

// Grava de forma síncrona: entre escolher o id e salvar não entra outra requisição,
// então dois pedidos simultâneos nunca recebem o mesmo id.
function gravar(itens, totalCentavos) {
  const ultimoId = pedidos.length > 0 ? pedidos[pedidos.length - 1].id : 0;
  const pedido = { id: ultimoId + 1, itens, totalCentavos, status: 'confirmado' };
  const novaLista = [...pedidos, pedido];
  gravarJson(arquivo, novaLista);
  pedidos = novaLista;
  return pedido;
}

// Escreve num .tmp e renomeia: se o processo cair no meio, o arquivo antigo continua inteiro.
// A outbox (outbox.js) grava do mesmo jeito.
function gravarJson(caminho, dados) {
  const temporario = caminho + '.tmp';
  fs.writeFileSync(temporario, JSON.stringify(dados, null, 2) + '\n', 'utf8');
  fs.renameSync(temporario, caminho);
}

module.exports = { abrir, quantidade, buscar, gravar, gravarJson };
