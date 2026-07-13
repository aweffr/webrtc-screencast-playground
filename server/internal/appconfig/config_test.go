package appconfig

import (
	"testing"
	"time"
)

func TestLoadDefaults(t *testing.T) {
	t.Parallel()

	config, err := Load(func(string) string { return "" })
	if err != nil {
		t.Fatal(err)
	}
	if config.ListenAddr != ":8080" || config.PairingTTL != 10*time.Minute || config.MaxPending != 1000 || config.MaxActive != 1000 {
		t.Fatalf("unexpected defaults: %#v", config)
	}
	if config.ReadHeaderTimeout != 5*time.Second || config.IdleTimeout != 60*time.Second || config.ShutdownTimeout != 10*time.Second {
		t.Fatalf("unexpected timeouts: %#v", config)
	}
}

func TestLoadOverrides(t *testing.T) {
	t.Parallel()

	values := map[string]string{
		"LISTEN_ADDR":         "127.0.0.1:9000",
		"PAIRING_TTL":         "2m",
		"MAX_PENDING":         "12",
		"MAX_ACTIVE":          "34",
		"READ_HEADER_TIMEOUT": "3s",
		"IDLE_TIMEOUT":        "20s",
		"SHUTDOWN_TIMEOUT":    "7s",
		"RATE_LIMIT_BURST":    "5",
		"RATE_LIMIT_INTERVAL": "250ms",
	}
	config, err := Load(func(key string) string { return values[key] })
	if err != nil {
		t.Fatal(err)
	}
	if config.ListenAddr != "127.0.0.1:9000" || config.PairingTTL != 2*time.Minute || config.MaxPending != 12 || config.MaxActive != 34 {
		t.Fatalf("unexpected config: %#v", config)
	}
	if config.RateLimitBurst != 5 || config.RateLimitInterval != 250*time.Millisecond {
		t.Fatalf("unexpected rate config: %#v", config)
	}
}

func TestLoadRejectsInvalidValues(t *testing.T) {
	t.Parallel()

	for key, value := range map[string]string{
		"PAIRING_TTL":         "never",
		"MAX_PENDING":         "0",
		"MAX_ACTIVE":          "-1",
		"READ_HEADER_TIMEOUT": "0s",
		"RATE_LIMIT_BURST":    "none",
		"RATE_LIMIT_INTERVAL": "-1s",
	} {
		key, value := key, value
		t.Run(key, func(t *testing.T) {
			t.Parallel()
			_, err := Load(func(requested string) string {
				if requested == key {
					return value
				}
				return ""
			})
			if err == nil {
				t.Fatal("Load unexpectedly succeeded")
			}
		})
	}
}

func TestLoadParsesConnectionAdmissionAndTrustedProxies(t *testing.T) {
	values := map[string]string{
		"MAX_CONNECTIONS":                "123",
		"CONNECTION_RATE_LIMIT_BURST":    "7",
		"CONNECTION_RATE_LIMIT_INTERVAL": "2s",
		"TRUSTED_PROXY_CIDRS":            "10.42.0.0/16, 127.0.0.1/32",
	}
	config, err := Load(func(key string) string { return values[key] })
	if err != nil {
		t.Fatal(err)
	}
	if config.MaxConnections != 123 || config.ConnectionRateLimitBurst != 7 || config.ConnectionRateLimitInterval != 2*time.Second {
		t.Fatalf("unexpected admission config: %#v", config)
	}
	if len(config.TrustedProxyCIDRs) != 2 || config.TrustedProxyCIDRs[0].String() != "10.42.0.0/16" {
		t.Fatalf("unexpected trusted proxies: %#v", config.TrustedProxyCIDRs)
	}
}
