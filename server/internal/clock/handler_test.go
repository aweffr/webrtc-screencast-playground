package clock

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHandlerReturnsOnlyVersionedServerTime(t *testing.T) {
	now := time.Unix(1_752_624_000, 123_456_789)
	request := httptest.NewRequest(http.MethodGet, "/clock", nil)
	recorder := httptest.NewRecorder()

	NewHandler(func() time.Time { return now }).ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
	}
	if got := recorder.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", got)
	}
	if got := recorder.Header().Get("Content-Type"); got != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", got)
	}
	var body map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if got, want := len(body), 2; got != want {
		t.Fatalf("response fields = %v, want exactly two", body)
	}
	if got := body["schema_version"]; got != float64(1) {
		t.Fatalf("schema_version = %v, want 1", got)
	}
	if got := body["server_unix_ns"]; got != float64(now.UnixNano()) {
		t.Fatalf("server_unix_ns = %v, want %d", got, now.UnixNano())
	}
	for _, forbidden := range []string{"session_id", "pairing_code", "credential"} {
		if _, exists := body[forbidden]; exists {
			t.Fatalf("response unexpectedly contains %q", forbidden)
		}
	}
}

func TestHandlerRejectsNonGETMethods(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/clock", nil)
	recorder := httptest.NewRecorder()

	NewHandler(time.Now).ServeHTTP(recorder, request)

	if recorder.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusMethodNotAllowed)
	}
	if got := recorder.Header().Get("Allow"); got != http.MethodGet {
		t.Fatalf("Allow = %q, want GET", got)
	}
}
