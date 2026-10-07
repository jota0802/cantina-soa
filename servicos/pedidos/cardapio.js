// Cliente HTTP do Cardápio. O Pedidos não guarda preço nem disponibilidade:
// pergunta ao Cardápio (contrato em contratos/cardapio.yaml) a cada pedido.

const TEMPO_LIMITE_MS = 2000;

// O Cardápio não respondeu a tempo, está fora do ar ou respondeu com erro.
class CardapioIndisponivel extends Error {}

// Consulta todos os itens em paralelo, uma vez por id distinto.
// Devolve um Map id -> item ({ nome, precoCentavos, disponivel }) ou null se o item não existe.
async function consultarItens(cardapioUrl, ids) {
  const distintos = [...new Set(ids)];
  // Um prazo só para a consulta inteira: no pior caso o cliente espera 2 s, não 2 s por item.
  const prazo = AbortSignal.timeout(TEMPO_LIMITE_MS);
  const itens = await Promise.all(distintos.map((id) => consultarItem(cardapioUrl, id, prazo)));
  return new Map(distintos.map((id, i) => [id, itens[i]]));
}

async function consultarItem(cardapioUrl, id, prazo) {
  let resposta;
  let texto;
  try {
    resposta = await fetch(`${cardapioUrl}/itens/${id}`, { signal: prazo });
    texto = await resposta.text();
  } catch (erro) {
    if (prazo.aborted) {
      throw new CardapioIndisponivel('O Cardápio não respondeu em 2 segundos. Tente de novo em instantes.');
    }
    throw new CardapioIndisponivel(
      `Não foi possível conectar ao Cardápio em ${cardapioUrl} (ele está no ar?). Tente de novo em instantes.`
    );
  }

  if (resposta.status === 404) {
    return null;
  }
  if (resposta.status !== 200) {
    throw new CardapioIndisponivel(
      `O Cardápio respondeu ${resposta.status} ao consultar o item ${id}. Tente de novo em instantes.`
    );
  }

  // Leitor tolerante: usa só os campos de que precisa e ignora o resto.
  let item;
  try {
    item = JSON.parse(texto);
  } catch {
    item = null;
  }
  if (!item || !Number.isInteger(item.precoCentavos) || typeof item.disponivel !== 'boolean') {
    throw new CardapioIndisponivel(`O Cardápio respondeu fora do contrato ao consultar o item ${id}.`);
  }
  return { nome: item.nome, precoCentavos: item.precoCentavos, disponivel: item.disponivel };
}

module.exports = { consultarItens, CardapioIndisponivel };
