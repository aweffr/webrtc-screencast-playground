package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/aweffr/webrtc-screencast-playground/server/internal/appconfig"
	"github.com/aweffr/webrtc-screencast-playground/server/internal/signaling"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	config, err := appconfig.Load(os.Getenv)
	if err != nil {
		logger.Error("configuration_invalid", "error", err.Error())
		os.Exit(2)
	}

	signalingServer := signaling.NewServer(signaling.Config{
		PairingTTL:        config.PairingTTL,
		MaxPending:        config.MaxPending,
		MaxActive:         config.MaxActive,
		RateLimitBurst:    config.RateLimitBurst,
		RateLimitInterval: config.RateLimitInterval,
		PingInterval:      30 * time.Second,
	}, logger)
	httpServer := &http.Server{
		Addr:              config.ListenAddr,
		Handler:           signalingServer.Handler(),
		ReadHeaderTimeout: config.ReadHeaderTimeout,
		IdleTimeout:       config.IdleTimeout,
		MaxHeaderBytes:    16 * 1024,
	}

	serveErrors := make(chan error, 1)
	go func() {
		logger.Info("signaling_started", "listen_addr", config.ListenAddr)
		serveErrors <- httpServer.ListenAndServe()
	}()

	signalContext, stopSignals := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stopSignals()
	select {
	case <-signalContext.Done():
		logger.Info("shutdown_requested")
	case err := <-serveErrors:
		if !errors.Is(err, http.ErrServerClosed) {
			logger.Error("http_server_failed", "error", err.Error())
		}
	}

	shutdownContext, cancel := context.WithTimeout(context.Background(), config.ShutdownTimeout)
	defer cancel()
	if err := httpServer.Shutdown(shutdownContext); err != nil {
		logger.Error("http_shutdown_failed", "error", err.Error())
	}
	if err := signalingServer.Shutdown(shutdownContext); err != nil {
		logger.Error("signaling_shutdown_failed", "error", err.Error())
	}
	logger.Info("signaling_stopped")
}
