package appconfig

import (
	"fmt"
	"strconv"
	"time"
)

type Config struct {
	ListenAddr        string
	PairingTTL        time.Duration
	MaxPending        int
	MaxActive         int
	ReadHeaderTimeout time.Duration
	IdleTimeout       time.Duration
	ShutdownTimeout   time.Duration
	RateLimitBurst    int
	RateLimitInterval time.Duration
}

func Load(getenv func(string) string) (Config, error) {
	config := Config{
		ListenAddr:        valueOrDefault(getenv("LISTEN_ADDR"), ":8080"),
		PairingTTL:        10 * time.Minute,
		MaxPending:        1000,
		MaxActive:         1000,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
		ShutdownTimeout:   10 * time.Second,
		RateLimitBurst:    20,
		RateLimitInterval: time.Second,
	}
	var err error
	if config.PairingTTL, err = durationValue(getenv, "PAIRING_TTL", config.PairingTTL); err != nil {
		return Config{}, err
	}
	if config.MaxPending, err = intValue(getenv, "MAX_PENDING", config.MaxPending); err != nil {
		return Config{}, err
	}
	if config.MaxActive, err = intValue(getenv, "MAX_ACTIVE", config.MaxActive); err != nil {
		return Config{}, err
	}
	if config.ReadHeaderTimeout, err = durationValue(getenv, "READ_HEADER_TIMEOUT", config.ReadHeaderTimeout); err != nil {
		return Config{}, err
	}
	if config.IdleTimeout, err = durationValue(getenv, "IDLE_TIMEOUT", config.IdleTimeout); err != nil {
		return Config{}, err
	}
	if config.ShutdownTimeout, err = durationValue(getenv, "SHUTDOWN_TIMEOUT", config.ShutdownTimeout); err != nil {
		return Config{}, err
	}
	if config.RateLimitBurst, err = intValue(getenv, "RATE_LIMIT_BURST", config.RateLimitBurst); err != nil {
		return Config{}, err
	}
	if config.RateLimitInterval, err = durationValue(getenv, "RATE_LIMIT_INTERVAL", config.RateLimitInterval); err != nil {
		return Config{}, err
	}
	return config, nil
}

func durationValue(getenv func(string) string, key string, fallback time.Duration) (time.Duration, error) {
	value := getenv(key)
	if value == "" {
		return fallback, nil
	}
	duration, err := time.ParseDuration(value)
	if err != nil || duration <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration", key)
	}
	return duration, nil
}

func intValue(getenv func(string) string, key string, fallback int) (int, error) {
	value := getenv(key)
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", key)
	}
	return parsed, nil
}

func valueOrDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
