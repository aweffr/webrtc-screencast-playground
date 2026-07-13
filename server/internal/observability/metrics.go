package observability

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
)

type Metrics struct {
	mu sync.Mutex

	connectionsTotal   uint64
	connectionsCurrent int64
	pairingsTotal      uint64
	pendingCurrent     int64
	sessionsCurrent    int64
	messages           map[string]uint64
	rejections         map[string]uint64
	expiredTotal       uint64
}

func NewMetrics() *Metrics {
	return &Metrics{
		messages:   make(map[string]uint64),
		rejections: make(map[string]uint64),
	}
}

func (metrics *Metrics) ConnectionOpened() {
	metrics.mu.Lock()
	defer metrics.mu.Unlock()
	metrics.connectionsTotal++
	metrics.connectionsCurrent++
}

func (metrics *Metrics) ConnectionClosed() {
	metrics.mu.Lock()
	defer metrics.mu.Unlock()
	if metrics.connectionsCurrent > 0 {
		metrics.connectionsCurrent--
	}
}

func (metrics *Metrics) PairingCreated() {
	metrics.mu.Lock()
	defer metrics.mu.Unlock()
	metrics.pairingsTotal++
}

func (metrics *Metrics) Message(messageType string) {
	metrics.mu.Lock()
	defer metrics.mu.Unlock()
	metrics.messages[safeMessageType(messageType)]++
}

func (metrics *Metrics) Rejection(reason string) {
	metrics.mu.Lock()
	defer metrics.mu.Unlock()
	metrics.rejections[safeRejectionReason(reason)]++
}

func (metrics *Metrics) Expired(count int) {
	if count <= 0 {
		return
	}
	metrics.mu.Lock()
	defer metrics.mu.Unlock()
	metrics.expiredTotal += uint64(count)
}

func (metrics *Metrics) SetRegistry(pending, active int) {
	metrics.mu.Lock()
	defer metrics.mu.Unlock()
	metrics.pendingCurrent = int64(max(pending, 0))
	metrics.sessionsCurrent = int64(max(active, 0))
}

func (metrics *Metrics) ServeHTTP(writer http.ResponseWriter, _ *http.Request) {
	metrics.mu.Lock()
	connectionsTotal := metrics.connectionsTotal
	connectionsCurrent := metrics.connectionsCurrent
	pairingsTotal := metrics.pairingsTotal
	pendingCurrent := metrics.pendingCurrent
	sessionsCurrent := metrics.sessionsCurrent
	expiredTotal := metrics.expiredTotal
	messages := cloneMap(metrics.messages)
	rejections := cloneMap(metrics.rejections)
	metrics.mu.Unlock()

	writer.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	var output strings.Builder
	writeMetric(&output, "screencast_signaling_connections_total", connectionsTotal)
	writeMetric(&output, "screencast_signaling_connections_current", connectionsCurrent)
	writeMetric(&output, "screencast_signaling_pairings_total", pairingsTotal)
	writeMetric(&output, "screencast_signaling_pending_current", pendingCurrent)
	writeMetric(&output, "screencast_signaling_sessions_current", sessionsCurrent)
	writeLabelMetrics(&output, "screencast_signaling_messages_total", "type", messages)
	writeLabelMetrics(&output, "screencast_signaling_rejections_total", "reason", rejections)
	writeMetric(&output, "screencast_signaling_expired_total", expiredTotal)
	_, _ = writer.Write([]byte(output.String()))
}

func writeMetric(output *strings.Builder, name string, value any) {
	fmt.Fprintf(output, "%s %v\n", name, value)
}

func writeLabelMetrics(output *strings.Builder, name, label string, values map[string]uint64) {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		fmt.Fprintf(output, "%s{%s=%q} %d\n", name, label, key, values[key])
	}
}

func cloneMap(source map[string]uint64) map[string]uint64 {
	cloned := make(map[string]uint64, len(source))
	for key, value := range source {
		cloned[key] = value
	}
	return cloned
}

func safeMessageType(value string) string {
	switch value {
	case "receiver.register", "receiver.registered", "sender.join", "session.paired", "sdp.offer", "sdp.answer", "ice.candidate", "ice.complete", "session.hangup", "error":
		return value
	default:
		return "other"
	}
}

func safeRejectionReason(value string) string {
	switch value {
	case "invalid_message", "invalid_state", "rate_limited", "capacity", "code_unavailable", "slow_peer", "internal":
		return value
	default:
		return "other"
	}
}
