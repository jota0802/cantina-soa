// Serviço Avisos da Cantina: assinante da Trilha A (webhook).
// Contrato em contratos/avisos.yaml.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

const tamanhoMaximoCorpo = 1 << 20 // 1 MiB

// CloudEvent é o envelope CloudEvents 1.0 em modo estruturado.
type CloudEvent struct {
	SpecVersion string          `json:"specversion"`
	ID          string          `json:"id"`
	Source      string          `json:"source"`
	Type        string          `json:"type"`
	Data        json.RawMessage `json:"data"`
}

// PedidoConfirmado é o "data" do evento cantina.pedido.confirmado.
// Ponteiros para distinguir "campo ausente" de "valor zero".
type PedidoConfirmado struct {
	PedidoID      *int   `json:"pedidoId"`
	TotalCentavos *int64 `json:"totalCentavos"`
}

type Erro struct {
	Codigo   string `json:"codigo"`
	Mensagem string `json:"mensagem"`
}

// Guarda os eventos já processados. Fica só em memória: um reinício esquece tudo, e o mapa
// cresce a cada evento novo (para o laboratório, tudo bem).
type idsProcessados struct {
	mu  sync.Mutex
	ids map[string]bool
}

// marcar devolve true se o evento é novo (e passa a lembrar dele).
// No CloudEvents 1.0 quem identifica um evento é o par source + id: dois publicadores
// diferentes podem usar o mesmo id. Por isso a chave junta os dois.
func (p *idsProcessados) marcar(source, id string) bool {
	chave := source + " " + id
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.ids[chave] {
		return false
	}
	p.ids[chave] = true
	return true
}

var (
	nome        string
	processados = &idsProcessados{ids: map[string]bool{}}
)

func main() {
	porta := os.Getenv("PORTA")
	if porta == "" {
		fmt.Fprintln(os.Stderr, "Erro: defina a variável de ambiente PORTA (ex.: PORTA=8083 go run .)")
		os.Exit(1)
	}
	nome = os.Getenv("NOME")
	if nome == "" {
		nome = "avisos"
	}
	log.SetFlags(0)
	log.SetPrefix("[" + nome + "] ")

	mux := http.NewServeMux()
	mux.HandleFunc("/eventos", tratarEventos)
	mux.HandleFunc("/saude", tratarSaude)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		responderErro(w, http.StatusNotFound, "rota_inexistente", "A rota "+r.URL.Path+" não existe")
	})

	// Abre a porta antes de logar "ouvindo": se ela estiver ocupada, o erro aparece sozinho.
	ouvinte, err := net.Listen("tcp", ":"+porta)
	if err != nil {
		log.Fatalf("não foi possível iniciar o servidor: %v", err)
	}
	servidor := &http.Server{Handler: mux}

	// Ctrl+C (SIGINT) ou SIGTERM: para de aceitar conexões e termina as que estão em andamento.
	ctx, parar := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer parar()
	encerrado := make(chan struct{})
	go func() {
		<-ctx.Done()
		log.Println("encerrando...")
		desligar, cancelar := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelar()
		servidor.Shutdown(desligar)
		close(encerrado)
	}()

	log.Printf("ouvindo na porta %s", porta)
	if err := servidor.Serve(ouvinte); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("o servidor parou com erro: %v", err)
	}
	<-encerrado
	log.Println("encerrado")
}

func tratarSaude(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		metodoNaoPermitido(w, http.MethodGet)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"ok"}`))
}

func tratarEventos(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		metodoNaoPermitido(w, http.MethodPost)
		return
	}

	corpo, err := io.ReadAll(http.MaxBytesReader(w, r.Body, tamanhoMaximoCorpo))
	var grandeDemais *http.MaxBytesError
	if errors.As(err, &grandeDemais) {
		responderErro(w, http.StatusRequestEntityTooLarge, "requisicao_invalida", "O corpo passa de 1 MiB")
		return
	}
	if err != nil {
		responderErro(w, http.StatusBadRequest, "requisicao_invalida", "Não foi possível ler o corpo da requisição")
		return
	}
	if !json.Valid(corpo) {
		responderErro(w, http.StatusBadRequest, "requisicao_invalida", "O corpo não é um JSON válido")
		return
	}
	// JSON válido, mas o evento precisa ser um objeto: uma lista, um texto, um número ou null não é.
	if bytes.TrimSpace(corpo)[0] != '{' {
		responderErro(w, http.StatusBadRequest, "evento_invalido", "o corpo deve ser um objeto JSON (o envelope CloudEvent), não uma lista, texto, número ou null")
		return
	}
	// É um objeto, mas algum campo pode vir com o tipo errado (ex.: specversion 1.0 sem aspas).
	var evento CloudEvent
	if err := json.Unmarshal(corpo, &evento); err != nil {
		responderErro(w, http.StatusBadRequest, "evento_invalido", "specversion, id, source e type devem ser texto")
		return
	}
	if msg := validarEnvelope(evento); msg != "" {
		responderErro(w, http.StatusBadRequest, "evento_invalido", msg)
		return
	}

	if evento.Type != "cantina.pedido.confirmado" {
		log.Printf("tipo %s ignorado", evento.Type)
		w.WriteHeader(http.StatusAccepted)
		return
	}

	var pedido PedidoConfirmado
	if err := json.Unmarshal(evento.Data, &pedido); err != nil || pedido.PedidoID == nil || pedido.TotalCentavos == nil {
		responderErro(w, http.StatusBadRequest, "evento_invalido", "data deve ser um objeto com pedidoId e totalCentavos inteiros")
		return
	}
	if *pedido.PedidoID < 1 {
		responderErro(w, http.StatusBadRequest, "evento_invalido", "pedidoId deve ser 1 ou mais")
		return
	}
	if *pedido.TotalCentavos < 0 {
		responderErro(w, http.StatusBadRequest, "evento_invalido", "totalCentavos não pode ser negativo")
		return
	}

	// Entrega "pelo menos uma vez": o mesmo evento (source + id) pode chegar de novo e não deve
	// gerar outro aviso.
	if !processados.marcar(evento.Source, evento.ID) {
		log.Printf("evento %s repetido, ignorado", evento.ID)
		w.WriteHeader(http.StatusAccepted)
		return
	}

	log.Printf("Pedido %d confirmado, total %s", *pedido.PedidoID, formatarReais(*pedido.TotalCentavos))
	w.WriteHeader(http.StatusAccepted)
}

// validarEnvelope devolve a mensagem de erro, ou "" se o envelope está certo.
func validarEnvelope(e CloudEvent) string {
	switch {
	case e.SpecVersion != "1.0":
		return `specversion deve ser "1.0"`
	case e.ID == "":
		return "falta o campo id"
	case e.Source == "":
		return "falta o campo source"
	case e.Type == "":
		return "falta o campo type"
	}
	return ""
}

// formatarReais converte centavos (nunca negativos) no padrão brasileiro: 123456 -> "R$ 1.234,56".
func formatarReais(centavos int64) string {
	inteiro := fmt.Sprintf("%d", centavos/100)

	// Ponto a cada três dígitos, da direita para a esquerda.
	var partes []string
	for len(inteiro) > 3 {
		partes = append([]string{inteiro[len(inteiro)-3:]}, partes...)
		inteiro = inteiro[:len(inteiro)-3]
	}
	partes = append([]string{inteiro}, partes...)

	return fmt.Sprintf("R$ %s,%02d", strings.Join(partes, "."), centavos%100)
}

func metodoNaoPermitido(w http.ResponseWriter, permitido string) {
	w.Header().Set("Allow", permitido)
	responderErro(w, http.StatusMethodNotAllowed, "metodo_nao_permitido", "Esta rota só aceita "+permitido)
}

func responderErro(w http.ResponseWriter, status int, codigo, mensagem string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(Erro{Codigo: codigo, Mensagem: mensagem})
}
