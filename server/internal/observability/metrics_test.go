package observability

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMetricsRenderPrometheusText(t *testing.T) {
	t.Parallel()

	metrics := NewMetrics()
	metrics.ConnectionOpened()
	metrics.PairingCreated()
	metrics.Message("sdp.offer")
	metrics.Message("sdp.offer")
	metrics.Rejection("invalid_message")
	metrics.Expired(2)
	metrics.SetRegistry(3, 1)

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest("GET", "/metrics", nil)
	metrics.ServeHTTP(recorder, request)

	if recorder.Code != 200 {
		t.Fatalf("status = %d, want 200", recorder.Code)
	}
	if contentType := recorder.Header().Get("Content-Type"); !strings.Contains(contentType, "text/plain") {
		t.Fatalf("Content-Type = %q", contentType)
	}
	wantLines := []string{
		"screencast_signaling_connections_total 1",
		"screencast_signaling_connections_current 1",
		"screencast_signaling_pairings_total 1",
		"screencast_signaling_pending_current 3",
		"screencast_signaling_sessions_current 1",
		`screencast_signaling_messages_total{type="sdp.offer"} 2`,
		`screencast_signaling_rejections_total{reason="invalid_message"} 1`,
		"screencast_signaling_expired_total 2",
	}
	body := recorder.Body.String()
	for _, line := range wantLines {
		if !strings.Contains(body, line+"\n") {
			t.Errorf("metrics body does not contain %q:\n%s", line, body)
		}
	}
}

func TestConnectionClosedDoesNotMakeGaugeNegative(t *testing.T) {
	t.Parallel()

	metrics := NewMetrics()
	metrics.ConnectionClosed()
	metrics.ConnectionOpened()
	metrics.ConnectionClosed()
	metrics.ConnectionClosed()

	recorder := httptest.NewRecorder()
	metrics.ServeHTTP(recorder, httptest.NewRequest("GET", "/metrics", nil))
	if !strings.Contains(recorder.Body.String(), "screencast_signaling_connections_current 0\n") {
		t.Fatalf("unexpected body:\n%s", recorder.Body.String())
	}
}

func TestMetricLabelsCannotContainSensitiveValues(t *testing.T) {
	t.Parallel()

	metrics := NewMetrics()
	for _, value := range []string{"01ABCD23", "v=0\r\nsecret", "candidate:1", `password="secret"`} {
		metrics.Message(value)
		metrics.Rejection(value)
	}

	recorder := httptest.NewRecorder()
	metrics.ServeHTTP(recorder, httptest.NewRequest("GET", "/metrics", nil))
	body := recorder.Body.String()
	for _, sensitive := range []string{"01ABCD23", "v=0", "candidate:1", "secret"} {
		if strings.Contains(body, sensitive) {
			t.Fatalf("metrics leaked %q:\n%s", sensitive, body)
		}
	}
	if !strings.Contains(body, `screencast_signaling_messages_total{type="other"} 4`) {
		t.Fatalf("unknown message types were not collapsed:\n%s", body)
	}
	if !strings.Contains(body, `screencast_signaling_rejections_total{reason="other"} 4`) {
		t.Fatalf("unknown rejection reasons were not collapsed:\n%s", body)
	}
}
