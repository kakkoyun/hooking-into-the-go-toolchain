// Command hello is an HTTP server that calls itself, so one request to /hello
// produces three spans: the server span for /hello, the client span for the
// outgoing call, and the server span for /world.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

const addr = "localhost:18080"

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /hello", hello)
	mux.HandleFunc("GET /world", world)

	// Exit on the first SIGINT or SIGTERM, once Shutdown has returned. An
	// otelc-built binary also flushes its telemetry on that signal; the app
	// still owns the exit.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	srv := &http.Server{Addr: addr, Handler: mux}
	done := make(chan struct{})
	go func() {
		defer close(done)
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	// ListenAndServe returns as soon as Shutdown starts; wait for it to finish.
	<-done
}

func hello(w http.ResponseWriter, r *http.Request) {
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, "http://"+addr+"/world", nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	fmt.Fprintf(w, "hello, %s\n", body)
}

// world is where the //demo:log directive rule (log.otelc.yml) applies.
//
//demo:log
func world(w http.ResponseWriter, _ *http.Request) {
	fmt.Fprint(w, "world")
}
