// Serviço Pedidos da Cantina.
// Segue o contrato em contratos/pedidos.yaml. Usa só a biblioteca padrão do Node.js (>= 18).

const http = require('node:http');
const dns = require('node:dns');
const path = require('node:path');
const cardapio = require('./cardapio');
const armazenamento = require('./armazenamento');

const TAMANHO_MAXIMO_CORPO = 1024 * 1024; // 1 MiB
// Limites do contrato (NovoPedido): cada item vira uma chamada ao Cardápio, e o total
// precisa continuar sendo um inteiro exato.
const MAXIMO_ITENS = 20;
const MAXIMO_QUANTIDADE = 1000;

// No Node 18, "localhost" pode virar ::1 primeiro, e o Cardápio escuta só em 127.0.0.1.
dns.setDefaultResultOrder('ipv4first');

function sair(mensagem) {
  console.error('Erro: ' + mensagem);
  process.exit(1);
}

function lerConfiguracao() {
  const portaTexto = process.env.PORTA;
  if (!portaTexto) {
    sair('defina a variável de ambiente PORTA (ex.: PORTA=8082 CARDAPIO_URL=http://localhost:8081 node server.js).');
  }
  if (!/^[0-9]+$/.test(portaTexto)) {
    sair(`PORTA precisa ser um número, recebi '${portaTexto}'.`);
  }
  if (Number(portaTexto) < 1 || Number(portaTexto) > 65535) {
    sair(`PORTA precisa estar entre 1 e 65535, recebi ${portaTexto}.`);
  }

  const cardapioTexto = process.env.CARDAPIO_URL;
  if (!cardapioTexto) {
    sair('defina a variável de ambiente CARDAPIO_URL (ex.: CARDAPIO_URL=http://localhost:8081).');
  }
  let url;
  try {
    url = new URL(cardapioTexto);
  } catch {
    url = null;
  }
  if (!url || (url.protocol !== 'http:' && url.protocol !== 'https:')) {
    sair(`CARDAPIO_URL precisa ser um endereço http, como http://localhost:8081. Recebi '${cardapioTexto}'.`);
  }

  return {
    porta: Number(portaTexto),
    // Aceita com ou sem barra no fim: "http://localhost:8081/" vira "http://localhost:8081".
    cardapioUrl: cardapioTexto.replace(/\/+$/, ''),
    dadosDir: process.env.DADOS_DIR || path.join(__dirname, 'dados'),
  };
}

const config = lerConfiguracao();

// ---------- respostas ----------

function responder(res, status, corpo, cabecalhos = {}) {
  const dados = JSON.stringify(corpo);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(dados),
    ...cabecalhos,
  });
  res.end(dados);
}

// Formato Erro do contrato: { codigo, mensagem, itemId? }
function responderErro(res, status, codigo, mensagem, itemId, cabecalhos) {
  const corpo = { codigo, mensagem };
  if (itemId !== undefined) {
    corpo.itemId = itemId;
  }
  responder(res, status, corpo, cabecalhos);
}

function metodoNaoPermitido(res, permitido) {
  responderErro(res, 405, 'metodo_nao_permitido', `Esta rota só aceita ${permitido}.`, undefined, {
    Allow: permitido,
  });
}

// ---------- POST /pedidos ----------

class CorpoGrandeDemais extends Error {}

function lerCorpo(req) {
  return new Promise((resolve, reject) => {
    const pedacos = [];
    let tamanho = 0;
    req.on('data', (pedaco) => {
      tamanho += pedaco.length;
      // Passou do limite: continua lendo (para poder responder 400), mas sem guardar.
      if (tamanho <= TAMANHO_MAXIMO_CORPO) {
        pedacos.push(pedaco);
      }
    });
    req.on('end', () => {
      if (tamanho > TAMANHO_MAXIMO_CORPO) {
        reject(new CorpoGrandeDemais());
      } else {
        resolve(Buffer.concat(pedacos).toString('utf8'));
      }
    });
    req.on('error', reject);
  });
}

// Devolve a mensagem do problema encontrado, ou null se o corpo segue o NovoPedido do contrato.
function validarNovoPedido(corpo) {
  if (corpo === null || typeof corpo !== 'object' || Array.isArray(corpo)) {
    return 'o corpo deve ser um objeto JSON com a lista itens';
  }
  if (!Array.isArray(corpo.itens) || corpo.itens.length === 0) {
    return 'itens deve ser uma lista com pelo menos um item';
  }
  if (corpo.itens.length > MAXIMO_ITENS) {
    return `itens pode ter no máximo ${MAXIMO_ITENS} itens`;
  }
  for (let i = 0; i < corpo.itens.length; i++) {
    const item = corpo.itens[i];
    if (item === null || typeof item !== 'object' || Array.isArray(item)) {
      return `itens[${i}] deve ser um objeto com itemId e quantidade`;
    }
    // isSafeInteger: 1e20 passa no isInteger, mas já não é um inteiro exato em JavaScript.
    if (!Number.isSafeInteger(item.itemId)) {
      return `itens[${i}].itemId deve ser um número inteiro`;
    }
    if (!Number.isSafeInteger(item.quantidade) || item.quantidade < 1 || item.quantidade > MAXIMO_QUANTIDADE) {
      return `itens[${i}].quantidade deve ser um número inteiro de 1 a ${MAXIMO_QUANTIDADE}`;
    }
  }
  return null;
}

async function criarPedido(req, res) {
  let corpo;
  try {
    corpo = JSON.parse(await lerCorpo(req));
  } catch (erro) {
    const mensagem = erro instanceof CorpoGrandeDemais
      ? 'o corpo da requisição passa de 1 MiB'
      : 'o corpo da requisição não é um JSON válido';
    return responderErro(res, 400, 'requisicao_invalida', mensagem);
  }

  const problema = validarNovoPedido(corpo);
  if (problema) {
    return responderErro(res, 400, 'requisicao_invalida', problema);
  }

  // Só itemId e quantidade: campos a mais no corpo não entram no pedido.
  const itens = corpo.itens.map((item) => ({ itemId: item.itemId, quantidade: item.quantidade }));

  let itensDoCardapio;
  try {
    itensDoCardapio = await cardapio.consultarItens(config.cardapioUrl, itens.map((item) => item.itemId));
  } catch (erro) {
    if (erro instanceof cardapio.CardapioIndisponivel) {
      return responderErro(res, 503, 'cardapio_indisponivel', erro.message);
    }
    throw erro;
  }

  // Confere na ordem do pedido: o primeiro item com problema é o que aparece no erro.
  let totalCentavos = 0;
  for (const { itemId, quantidade } of itens) {
    const item = itensDoCardapio.get(itemId);
    if (item === null) {
      return responderErro(res, 422, 'item_inexistente', `O item ${itemId} não existe no cardápio`, itemId);
    }
    if (!item.disponivel) {
      const nome = item.nome ? ` (${item.nome})` : '';
      return responderErro(res, 422, 'item_indisponivel', `O item ${itemId}${nome} está indisponível`, itemId);
    }
    totalCentavos += item.precoCentavos * quantidade;
  }
  // Com os limites acima só passa daqui se o Cardápio informar um preço absurdo.
  if (!Number.isSafeInteger(totalCentavos)) {
    return responderErro(res, 400, 'requisicao_invalida', 'o total do pedido passa do maior valor que o Pedidos consegue guardar');
  }

  // Só aqui o pedido passa a existir (e o id é consumido): todos os itens foram aprovados.
  const pedido = armazenamento.gravar(itens, totalCentavos);
  responder(res, 201, pedido, { Location: `/pedidos/${pedido.id}` });
}

// ---------- GET /pedidos/{id} ----------

function consultarPedido(res, idTexto) {
  // O contrato diz que o id é inteiro; qualquer outra coisa é um pedido que não existe.
  const pedido = /^[0-9]+$/.test(idTexto) ? armazenamento.buscar(Number(idTexto)) : null;
  if (!pedido) {
    return responderErro(res, 404, 'pedido_inexistente', `O pedido ${idTexto} não existe`);
  }
  responder(res, 200, pedido);
}

// ---------- rotas ----------

async function tratar(req, res) {
  let caminho = new URL(req.url, 'http://localhost').pathname;
  if (caminho !== '/') {
    caminho = caminho.replace(/\/+$/, '');
  }

  if (caminho === '/saude') {
    if (req.method !== 'GET') return metodoNaoPermitido(res, 'GET');
    return responder(res, 200, { status: 'ok', servico: 'pedidos' });
  }
  if (caminho === '/pedidos') {
    if (req.method !== 'POST') return metodoNaoPermitido(res, 'POST');
    return criarPedido(req, res);
  }
  if (caminho.startsWith('/pedidos/')) {
    if (req.method !== 'GET') return metodoNaoPermitido(res, 'GET');
    return consultarPedido(res, caminho.slice('/pedidos/'.length));
  }
  responderErro(res, 404, 'rota_inexistente', `Rota não encontrada: ${caminho}`);
}

const servidor = http.createServer((req, res) => {
  const inicio = Date.now();
  res.on('finish', () => {
    const ms = Date.now() - inicio;
    console.log(`[pedidos:${config.porta}] ${req.method} ${req.url} -> ${res.statusCode} (${ms} ms)`);
  });

  tratar(req, res).catch((erro) => {
    console.error(`[pedidos:${config.porta}] erro inesperado:`, erro);
    if (!res.headersSent) {
      responderErro(res, 500, 'erro_interno', 'Erro inesperado no Pedidos. Veja o log do serviço.');
    }
  });
});

// ---------- início e fim ----------

let arquivoDados;
try {
  arquivoDados = armazenamento.abrir(config.dadosDir);
} catch (erro) {
  sair(`não foi possível abrir os dados em ${config.dadosDir}: ${erro.message}`);
}

servidor.on('error', (erro) => {
  if (erro.code === 'EADDRINUSE') {
    sair(`a porta ${config.porta} já está em uso. Outro processo está escutando nela?`);
  }
  sair(`não foi possível iniciar o servidor: ${erro.message}`);
});

servidor.listen(config.porta, () => {
  console.log(`Pedidos no ar em http://localhost:${config.porta}`);
  console.log(`  Cardápio: ${config.cardapioUrl}`);
  console.log(`  Dados: ${arquivoDados} (${armazenamento.quantidade()} pedidos salvos)`);
  conferirCardapio();
});

// Só avisa, não impede a subida. Pega o engano de CARDAPIO_URL com caminho (ex.: terminando
// em /itens): sem este aviso, todo pedido sairia 422 "item não existe".
async function conferirCardapio() {
  const endereco = `${config.cardapioUrl}/saude`;
  try {
    const resposta = await fetch(endereco, { signal: AbortSignal.timeout(2000) });
    if (resposta.status !== 200) {
      console.warn(`  Aviso: GET ${endereco} respondeu ${resposta.status}. CARDAPIO_URL deve ser só a raiz do Cardápio, como http://localhost:8081.`);
    }
  } catch {
    console.warn(`  Aviso: o Cardápio não respondeu em ${endereco}. Ele está no ar? Confira CARDAPIO_URL.`);
  }
}

// Ctrl+C (SIGINT) ou SIGTERM. A gravação é síncrona, então não há pedido pela metade.
function encerrar() {
  console.log('\nPedidos encerrado.');
  process.exit(0);
}
process.on('SIGINT', encerrar);
process.on('SIGTERM', encerrar);
