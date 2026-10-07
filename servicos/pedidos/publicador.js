// Publicador do evento cantina.pedido.confirmado (Trilha A: webhook).
//
// O Pedidos não sabe quem são os consumidores: a lista vem da variável ASSINANTES.
// Publicar acontece em duas partes:
//   1. publicar(pedido): monta o evento e grava uma entrada na outbox para cada assinante.
//      É síncrono e rápido; o POST /pedidos responde 201 logo depois.
//   2. o despachante (despachar) faz o POST em cada assinante em segundo plano e tenta de
//      novo enquanto o assinante estiver fora. O cliente do pedido nunca espera por isso.

const crypto = require('node:crypto');
const outbox = require('./outbox');

const TEMPO_LIMITE_MS = 2000;

// Só 400 e 413 são erro permanente, porque é o que o contrato avisos.yaml define: o assinante
// recusou o evento, e mandar o mesmo corpo de novo não muda nada. Qualquer outra resposta que
// não seja 2xx (404, 405, 408, 429, 5xx...) e qualquer falha de rede pode passar, então a
// entrega é tentada de novo. Um 404 ou 405 quase sempre é endereço errado em ASSINANTES: o
// log diz isso, e o evento fica na outbox, preso ao endereço errado, sendo tentado para sempre.
// Corrigir ASSINANTES vale só para pedidos novos; para tirar a entrada presa, pare o Pedidos e
// apague-a do outbox.json.
const ERROS_PERMANENTES = [400, 413];
const ENDERECO_SUSPEITO = [404, 405];

let assinantes = [];
let reenvioMs = 3000;
let prefixo = '[pedidos]';

function configurar(opcoes) {
  assinantes = opcoes.assinantes;
  reenvioMs = opcoes.reenvioMs;
  prefixo = opcoes.prefixoLog;
}

// Envelope CloudEvents 1.0 do contrato contratos/pedido-confirmado.json.
function criarEvento(pedido) {
  return {
    specversion: '1.0',
    id: crypto.randomUUID(),
    source: '/cantina/pedidos',
    type: 'cantina.pedido.confirmado',
    time: new Date().toISOString(),
    datacontenttype: 'application/json',
    data: { pedidoId: pedido.id, totalCentavos: pedido.totalCentavos },
  };
}

// Grava na outbox um par (evento, assinante) por assinante e devolve as entradas novas.
// Um evento só, com o mesmo id para todos: cada assinante deduplica pelo par source + id.
function publicar(pedido) {
  if (assinantes.length === 0) {
    return [];
  }
  const evento = criarEvento(pedido);
  const novas = assinantes.map((assinante) => ({ assinante, evento }));
  outbox.adicionar(novas);
  return novas;
}

// ---------- despachante ----------

// Tenta entregar uma entrada da outbox. Cada entrada tem a sua própria "fila de uma pessoa":
// a próxima tentativa só é agendada (setTimeout) depois que a anterior terminou. Assim nunca
// há duas entregas simultâneas da mesma entrada, e um assinante fora do ar não segura os outros.
function despachar(entrada) {
  entregar(entrada).catch((erro) => {
    // Não deveria acontecer (ex.: disco cheio ao regravar a outbox). Loga e tenta de novo depois.
    console.error(`${prefixo} erro inesperado ao entregar o evento ${entrada.evento.id}:`, erro);
    setTimeout(() => despachar(entrada), reenvioMs);
  });
}

async function entregar(entrada) {
  const { assinante, evento } = entrada;
  const resultado = await enviar(assinante, evento);

  if (resultado.tipo === 'entregue') {
    outbox.remover(entrada);
    console.log(`${prefixo} evento ${evento.id} entregue a ${assinante}`);
    return;
  }
  if (resultado.tipo === 'permanente') {
    // 400 ou 413: o assinante recusou este evento. Mandar o mesmo corpo de novo não muda nada.
    outbox.remover(entrada);
    console.log(`${prefixo} evento ${evento.id} para ${assinante} descartado (${resultado.motivo})`);
    return;
  }
  // Rede, tempo limite, 5xx ou outro 4xx: o problema pode passar. A entrada continua na outbox.
  // REENVIO_MS conta a partir de agora, do fim desta tentativa: não é um relógio fixo.
  console.log(
    `${prefixo} evento ${evento.id} para ${assinante} falhou (${resultado.motivo}), nova tentativa em ${segundos(reenvioMs)}`
  );
  setTimeout(() => despachar(entrada), reenvioMs);
}

// Faz o POST e classifica o resultado: entregue, permanente (descartar) ou temporario (tentar de novo).
async function enviar(assinante, evento) {
  const prazo = AbortSignal.timeout(TEMPO_LIMITE_MS);
  let resposta;
  let texto;
  try {
    resposta = await fetch(assinante, {
      method: 'POST',
      headers: { 'Content-Type': 'application/cloudevents+json' },
      body: JSON.stringify(evento),
      signal: prazo,
    });
    texto = await resposta.text();
  } catch (erro) {
    if (prazo.aborted) {
      return { tipo: 'temporario', motivo: `sem resposta em ${segundos(TEMPO_LIMITE_MS)}` };
    }
    const codigo = erro.cause && erro.cause.code;
    if (codigo === 'ECONNREFUSED') {
      return { tipo: 'temporario', motivo: 'conexão recusada: o assinante está fora do ar?' };
    }
    return { tipo: 'temporario', motivo: codigo || (erro.cause && erro.cause.message) || erro.message };
  }

  if (resposta.status >= 200 && resposta.status < 300) {
    return { tipo: 'entregue' };
  }
  const resumo = texto.trim().slice(0, 200);
  let motivo = `respondeu ${resposta.status}` + (resumo ? `: ${resumo}` : '');
  if (ENDERECO_SUSPEITO.includes(resposta.status)) {
    motivo += `. Confira o endereço em ASSINANTES: ${assinante} deve ser a rota POST /eventos do assinante`;
  }
  if (ERROS_PERMANENTES.includes(resposta.status)) {
    return { tipo: 'permanente', motivo };
  }
  return { tipo: 'temporario', motivo };
}

// 3000 -> "3 s"; 1500 -> "1,5 s".
function segundos(ms) {
  return String(ms / 1000).replace('.', ',') + ' s';
}

module.exports = { configurar, publicar, despachar };
