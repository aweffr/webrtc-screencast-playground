package clock

import (
	"encoding/json"
	"net/http"
	"time"
)

type response struct {
	SchemaVersion int   `json:"schema_version"`
	ServerUnixNS  int64 `json:"server_unix_ns"`
}

// NewHandler exposes the server clock without attaching any session or pairing state.
func NewHandler(now func() time.Time) http.Handler {
	if now == nil {
		panic("clock: nil time source")
	}
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet {
			writer.Header().Set("Allow", http.MethodGet)
			http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		writer.Header().Set("Cache-Control", "no-store")
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(response{
			SchemaVersion: 1,
			ServerUnixNS:  now().UnixNano(),
		})
	})
}
