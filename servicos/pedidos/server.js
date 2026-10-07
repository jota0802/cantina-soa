// Serviço Pedidos da Cantina.
// Segue o contrato em contratos/pedidos.yaml. Usa só a biblioteca padrão do Node.js (>= 18).

const http = require('node:http');
const dns = require('node:dns');
const path = require('node:path');
const cardapio = require('./cardapio');
const armazenamento = require('./armazenamento');
const outbox = require('./outbox');
const publicador = require('./publicador');

const TAMANHO_MAXIMO_CORPO = 1024 * 1024; // 1 MiB
// Limites do contrato (NovoPedido): cada item vira uma chamada ao Cardápio, e o total
// precisa continuar sendo um inteiro exato.
const MAXIMO_ITENS = 20;
const MAXIMO_QUANTIDADE = 1000;

// Os nossos serviços (Cardápio e Avisos) escutam em IPv4 e IPv6 no mesmo socket quando o
// sistema suporta (o comum hoje em macOS, Linux e Windows); senão, só em IPv4. Nos dois casos
// 127.0.0.1 funciona, então para eles esta linha não atrapalha.
// A linha fica por causa dos serviços dos OUTROS grupos: o Cardápio da prova de fogo ou um
// assinante em ASSINANTES pode escutar só em 127.0.0.1 (o padrão de Flask, uvicorn e de muitos
// exemplos). No macOS e em vários Linux, "localhost" resolve primeiro para ::1. O Node 20 ou
// mais novo tenta ::1 e 127.0.0.1 (autoSelectFamily) e acha o servidor; o Node 18, que o
// projeto ainda aceita, tenta só o primeiro endereço e falha com ECONNREFUSED ::1. Pondo IPv4
// primeiro, "localhost" funciona igual nas duas versões.
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
    assinantes: lerAssinantes(),
    reenvioMs: lerReenvioMs(),
  };
}

// ASSINANTES: endereços que recebem o evento, separados por vírgula, como
// "http://localhost:8083/eventos,http://localhost:8084/eventos". Vazia: não publica nada.
function lerAssinantes() {
  const texto = process.env.ASSINANTES || '';
  const assinantes = [];
  for (const parte of texto.split(',')) {
    const endereco = parte.trim();
    if (endereco === '') continue;
    let url;
    try {
      url = new URL(endereco);
    } catch {
      url = null;
    }
    if (!url || (url.protocol !== 'http:' && url.protocol !== 'https:')) {
      sair(`ASSINANTES deve ter endereços http separados por vírgula, como http://localhost:8083/eventos. Não entendi '${endereco}'.`);
    }
    // O mesmo endereço duas vezes receberia o evento duas vezes; basta uma.
    if (!assinantes.includes(endereco)) {
      assinantes.push(endereco);
    }
  }
  return assinantes;
}

// REENVIO_MS: quanto esperar depois de uma tentativa de entrega que falhou, contando do fim
// dela, antes da próxima (padrão 3000). Não é um relógio fixo: uma tentativa que estoura o
// tempo limite de 2 s deixa o intervalo entre o começo de uma e o da outra em ~5 s.
function lerReenvioMs() {
  const texto = process.env.REENVIO_MS;
  if (texto === undefined || texto === '') {
    return 3000;
  }
  if (!/^[0-9]+$/.test(texto) || Number(texto) < 100) {
    sair(`REENVIO_MS precisa ser um número inteiro de milissegundos, 100 ou mais, recebi '${texto}'.`);
  }
  return Number(texto);
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

  // Evento cantina.pedido.confirmado: grava na outbox (rápido, sem rede) e responde 201.
  // A entrega aos assinantes acontece depois, em segundo plano, e nunca atrasa o pedido.
  let entregas = [];
  try {
    entregas = publicador.publicar(pedido);
  } catch (erro) {
    // O pedido já está confirmado e gravado; um problema na outbox não pode desfazer isso.
    console.error(`[pedidos:${config.porta}] não foi possível gravar o evento do pedido ${pedido.id} na outbox:`, erro);
  }
  responder(res, 201, pedido, { Location: `/pedidos/${pedido.id}` });
  entregas.forEach(publicador.despachar);
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
let arquivoOutbox;
try {
  arquivoDados = armazenamento.abrir(config.dadosDir);
  arquivoOutbox = outbox.abrir(config.dadosDir);
} catch (erro) {
  sair(`não foi possível abrir os dados em ${config.dadosDir}: ${erro.message}`);
}

publicador.configurar({
  assinantes: config.assinantes,
  reenvioMs: config.reenvioMs,
  prefixoLog: `[pedidos:${config.porta}]`,
});

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
  if (config.assinantes.length > 0) {
    console.log(`  Assinantes do evento cantina.pedido.confirmado: ${config.assinantes.join(', ')}`);
  } else {
    console.log('  ASSINANTES vazio: nenhum evento será publicado.');
  }

  // Entregas que ficaram pendentes antes de o Pedidos parar: retoma agora.
  const pendentes = outbox.pendentes();
  console.log(`  Outbox: ${arquivoOutbox} (${pendentes.length} entregas pendentes)`);
  pendentes.forEach(publicador.despachar);

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
// Uma entrega em andamento fica na outbox e é refeita na próxima subida (o assinante
// deduplica pelo par source + id do evento).
function encerrar() {
  console.log('\nPedidos encerrado.');
  process.exit(0);
}
process.on('SIGINT', encerrar);
process.on('SIGTERM', encerrar);
