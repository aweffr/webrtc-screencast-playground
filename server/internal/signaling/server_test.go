package signaling

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aweffr/webrtc-screencast-playground/server/internal/protocol"
	"github.com/aweffr/webrtc-screencast-playground/server/internal/session"
	"github.com/coder/websocket"
)

type testClock struct {
	mu  sync.Mutex
	now time.Time
}

func (clock *testClock) Now() time.Time {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	return clock.now
}

func (clock *testClock) Advance(duration time.Duration) {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	clock.now = clock.now.Add(duration)
}

type testCodes struct {
	mu    sync.Mutex
	codes []string
}

func (codes *testCodes) Generate() (string, error) {
	codes.mu.Lock()
	defer codes.mu.Unlock()
	code := codes.codes[0]
	codes.codes = codes.codes[1:]
	return code, nil
}

type lockedBuffer struct {
	mu     sync.Mutex
	buffer bytes.Buffer
}

func (buffer *lockedBuffer) Write(data []byte) (int, error) {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	return buffer.buffer.Write(data)
}

func (buffer *lockedBuffer) String() string {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	return buffer.buffer.String()
}

type serverFixture struct {
	server     *Server
	httpServer *httptest.Server
	wsURL      string
	logs       *lockedBuffer
}

func newServerFixture(t *testing.T, queueSize int, codes ...string) *serverFixture {
	t.Helper()
	clock := &testClock{now: time.Date(2026, 7, 14, 0, 0, 0, 0, time.UTC)}
	logs := &lockedBuffer{}
	logger := slog.New(slog.NewJSONHandler(logs, nil))
	server := NewServer(Config{
		Clock:          clock,
		CodeGenerator:  &testCodes{codes: codes},
		PairingTTL:     10 * time.Minute,
		MaxPending:     10,
		MaxActive:      10,
		WriteQueueSize: queueSize,
		ReadLimit:      256 * 1024,
		PingInterval:   0,
	}, logger)
	httpServer := httptest.NewServer(server.Handler())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
		httpServer.Close()
	})
	return &serverFixture{
		server:     server,
		httpServer: httpServer,
		wsURL:      "ws" + strings.TrimPrefix(httpServer.URL, "http") + "/ws",
		logs:       logs,
	}
}

func (fixture *serverFixture) dial(t *testing.T) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	connection, _, err := websocket.Dial(ctx, fixture.wsURL, nil)
	if err != nil {
		t.Fatalf("websocket.Dial returned error: %v", err)
	}
	t.Cleanup(func() { connection.CloseNow() })
	return connection
}

func writeMessage(t *testing.T, connection *websocket.Conn, messageID string, typ protocol.MessageType, payload any) []byte {
	t.Helper()
	data, err := protocol.Encode(messageID, typ, payload)
	if err != nil {
		t.Fatalf("protocol.Encode returned error: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := connection.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatalf("connection.Write returned error: %v", err)
	}
	return data
}

func readMessage(t *testing.T, connection *websocket.Conn) (protocol.Envelope, any, []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	messageType, data, err := connection.Read(ctx)
	if err != nil {
		t.Fatalf("connection.Read returned error: %v", err)
	}
	if messageType != websocket.MessageText {
		t.Fatalf("message type = %v, want text", messageType)
	}
	envelope, payload, err := protocol.Decode(data)
	if err != nil {
		t.Fatalf("protocol.Decode returned error: %v; data=%s", err, data)
	}
	return envelope, payload, data
}

func registerAndPair(t *testing.T, fixture *serverFixture) (receiver, sender *websocket.Conn, sessionID string) {
	t.Helper()
	receiver = fixture.dial(t)
	writeMessage(t, receiver, "receiver-register", protocol.TypeReceiverRegister, protocol.ReceiverRegisterPayload{})
	_, registeredRaw, _ := readMessage(t, receiver)
	registered, ok := registeredRaw.(protocol.ReceiverRegisteredPayload)
	if !ok {
		t.Fatalf("registered payload type = %T", registeredRaw)
	}

	sender = fixture.dial(t)
	writeMessage(t, sender, "sender-join", protocol.TypeSenderJoin, protocol.SenderJoinPayload{PairingCode: registered.PairingCode})
	receiverEnvelope, receiverPairedRaw, _ := readMessage(t, receiver)
	senderEnvelope, senderPairedRaw, _ := readMessage(t, sender)
	if receiverEnvelope.Type != protocol.TypeSessionPaired || senderEnvelope.Type != protocol.TypeSessionPaired {
		t.Fatalf("paired types = %q, %q", receiverEnvelope.Type, senderEnvelope.Type)
	}
	receiverPaired := receiverPairedRaw.(protocol.SessionPairedPayload)
	senderPaired := senderPairedRaw.(protocol.SessionPairedPayload)
	if receiverPaired.Role != protocol.RoleReceiver || senderPaired.Role != protocol.RoleSender || receiverPaired.SessionID != senderPaired.SessionID {
		t.Fatalf("unexpected paired payloads: %#v, %#v", receiverPaired, senderPaired)
	}
	return receiver, sender, receiverPaired.SessionID
}

func TestHealthAndMetricsEndpoints(t *testing.T) {
	t.Parallel()
	fixture := newServerFixture(t, 8, "01ABCD23")

	response, err := http.Get(fixture.httpServer.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("health status = %d", response.StatusCode)
	}
	response, err = http.Get(fixture.httpServer.URL + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if !strings.Contains(string(body), "screencast_signaling_connections_total") {
		t.Fatalf("unexpected metrics: %s", body)
	}
}

func TestWebSocketPairsAndRelaysNegotiationMessages(t *testing.T) {
	t.Parallel()
	fixture := newServerFixture(t, 16, "01ABCD23")
	receiver, sender, _ := registerAndPair(t, fixture)

	offer := writeMessage(t, sender, "offer-1", protocol.TypeSDPOffer, protocol.SDPPayload{SDP: "v=0\r\no=sender\r\n"})
	envelope, payload, relayedOffer := readMessage(t, receiver)
	if envelope.MessageID != "offer-1" || payload.(protocol.SDPPayload).SDP != "v=0\r\no=sender\r\n" || string(relayedOffer) != string(offer) {
		t.Fatalf("offer was not transparently relayed: %s", relayedOffer)
	}

	answer := writeMessage(t, receiver, "answer-1", protocol.TypeSDPAnswer, protocol.SDPPayload{SDP: "v=0\r\no=receiver\r\n"})
	_, _, relayedAnswer := readMessage(t, sender)
	if string(relayedAnswer) != string(answer) {
		t.Fatalf("answer was not transparently relayed: %s", relayedAnswer)
	}

	candidate := writeMessage(t, sender, "ice-1", protocol.TypeICECandidate, protocol.ICECandidatePayload{Candidate: "candidate:1 1 udp 1 127.0.0.1 5000 typ host", SDPMid: "0", SDPMLineIndex: 0})
	_, _, relayedCandidate := readMessage(t, receiver)
	if string(relayedCandidate) != string(candidate) {
		t.Fatalf("candidate was not transparently relayed: %s", relayedCandidate)
	}

	complete := writeMessage(t, receiver, "ice-complete", protocol.TypeICEComplete, protocol.ICECompletePayload{})
	_, _, relayedComplete := readMessage(t, sender)
	if string(relayedComplete) != string(complete) {
		t.Fatalf("ice.complete was not transparently relayed: %s", relayedComplete)
	}

	hangup := writeMessage(t, sender, "hangup", protocol.TypeSessionHangup, protocol.SessionHangupPayload{Reason: "done"})
	_, _, relayedHangup := readMessage(t, receiver)
	if string(relayedHangup) != string(hangup) {
		t.Fatalf("hangup was not transparently relayed: %s", relayedHangup)
	}
	deadline := time.Now().Add(time.Second)
	for fixture.server.RegistrySnapshot().Active != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if snapshot := fixture.server.RegistrySnapshot(); snapshot.Active != 0 || snapshot.Pending != 0 {
		t.Fatalf("registry not cleaned after hangup: %#v", snapshot)
	}
}

func TestSessionLogsUseCanonicalSessionID(t *testing.T) {
	t.Parallel()
	fixture := newServerFixture(t, 8, "01ABCD23")
	_, _, sessionID := registerAndPair(t, fixture)

	if !strings.Contains(fixture.logs.String(), `"session_id":"`+sessionID+`"`) {
		t.Fatalf("logs do not contain canonical session id")
	}
}

func TestWebSocketRejectsMessageInWrongState(t *testing.T) {
	t.Parallel()
	fixture := newServerFixture(t, 8, "01ABCD23")
	connection := fixture.dial(t)
	writeMessage(t, connection, "offer-before-pair", protocol.TypeSDPOffer, protocol.SDPPayload{SDP: "v=0\r\n"})
	envelope, payload, _ := readMessage(t, connection)
	if envelope.Type != protocol.TypeError || payload.(protocol.ErrorPayload).Code != "invalid_state" {
		t.Fatalf("unexpected error: %#v %#v", envelope, payload)
	}
}

func TestPairingCodeCannotBeUsedBySecondSender(t *testing.T) {
	t.Parallel()
	fixture := newServerFixture(t, 8, "01ABCD23")
	receiver := fixture.dial(t)
	writeMessage(t, receiver, "register", protocol.TypeReceiverRegister, protocol.ReceiverRegisterPayload{})
	_, registeredRaw, _ := readMessage(t, receiver)
	code := registeredRaw.(protocol.ReceiverRegisteredPayload).PairingCode

	first := fixture.dial(t)
	writeMessage(t, first, "join-1", protocol.TypeSenderJoin, protocol.SenderJoinPayload{PairingCode: code})
	readMessage(t, receiver)
	readMessage(t, first)

	second := fixture.dial(t)
	writeMessage(t, second, "join-2", protocol.TypeSenderJoin, protocol.SenderJoinPayload{PairingCode: code})
	_, payload, _ := readMessage(t, second)
	if payload.(protocol.ErrorPayload).Code != "code_unavailable" {
		t.Fatalf("unexpected second join error: %#v", payload)
	}
}

func TestDisconnectNotifiesPeerAndCleansSession(t *testing.T) {
	t.Parallel()
	fixture := newServerFixture(t, 8, "01ABCD23")
	receiver, sender, _ := registerAndPair(t, fixture)

	if err := sender.Close(websocket.StatusNormalClosure, "bye"); err != nil {
		t.Fatalf("sender.Close returned error: %v", err)
	}
	envelope, payload, _ := readMessage(t, receiver)
	if envelope.Type != protocol.TypeSessionHangup || payload.(protocol.SessionHangupPayload).Reason != "peer_disconnected" {
		t.Fatalf("unexpected disconnect notification: %#v %#v", envelope, payload)
	}
	deadline := time.Now().Add(time.Second)
	for fixture.server.RegistrySnapshot().Active != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if snapshot := fixture.server.RegistrySnapshot(); snapshot.Active != 0 {
		t.Fatalf("registry not cleaned: %#v", snapshot)
	}
}

func TestMalformedMessageReturnsSafeError(t *testing.T) {
	t.Parallel()
	fixture := newServerFixture(t, 8, "01ABCD23")
	connection := fixture.dial(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	malformed := []byte(`{"version":1,"message_id":"m","type":"receiver.register","payload":{},"pairing_code":"must-not-echo"}`)
	if err := connection.Write(ctx, websocket.MessageText, malformed); err != nil {
		t.Fatal(err)
	}
	_, payload, data := readMessage(t, connection)
	errorPayload := payload.(protocol.ErrorPayload)
	if errorPayload.Code != "invalid_message" || strings.Contains(string(data), "must-not-echo") {
		t.Fatalf("unsafe error response: %s", data)
	}
}

func TestBinaryMessageIsRejected(t *testing.T) {
	t.Parallel()
	fixture := newServerFixture(t, 8, "01ABCD23")
	connection := fixture.dial(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := connection.Write(ctx, websocket.MessageBinary, []byte("secret")); err != nil {
		t.Fatal(err)
	}
	_, payload, _ := readMessage(t, connection)
	if payload.(protocol.ErrorPayload).Code != "invalid_message" {
		t.Fatalf("unexpected error: %#v", payload)
	}
}

func TestOversizedMessageClosesConnection(t *testing.T) {
	t.Parallel()
	fixture := newServerFixture(t, 8, "01ABCD23")
	connection := fixture.dial(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	data, err := json.Marshal(map[string]any{
		"version": 1, "message_id": "large", "type": "sdp.offer",
		"payload": map[string]string{"sdp": strings.Repeat("x", 300*1024)},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := connection.Write(ctx, websocket.MessageText, data); err != nil {
		return
	}
	_, _, err = connection.Read(ctx)
	if err == nil {
		t.Fatal("oversized connection remained open")
	}
}

func TestSlowPeerDoesNotBlockOtherSession(t *testing.T) {
	t.Parallel()
	fixture := newServerFixture(t, 1, "01ABCD23", "45EFGH67")
	slowReceiver, slowSender, _ := registerAndPair(t, fixture)
	_ = slowReceiver

	largeCandidate := protocol.ICECandidatePayload{Candidate: strings.Repeat("c", 12*1024), SDPMid: "0", SDPMLineIndex: 0}
	for index := 0; index < 200; index++ {
		ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
		data, err := protocol.Encode("flood", protocol.TypeICECandidate, largeCandidate)
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		err = slowSender.Write(ctx, websocket.MessageText, data)
		cancel()
		if err != nil {
			break
		}
	}

	receiver := fixture.dial(t)
	writeMessage(t, receiver, "register-fast", protocol.TypeReceiverRegister, protocol.ReceiverRegisterPayload{})
	_, registered, _ := readMessage(t, receiver)
	sender := fixture.dial(t)
	writeMessage(t, sender, "join-fast", protocol.TypeSenderJoin, protocol.SenderJoinPayload{PairingCode: registered.(protocol.ReceiverRegisteredPayload).PairingCode})
	readMessage(t, receiver)
	readMessage(t, sender)
}

func TestRegistrySnapshotTypeMatchesSessionPackage(t *testing.T) {
	t.Parallel()
	fixture := newServerFixture(t, 8, "01ABCD23")
	var snapshot session.Snapshot = fixture.server.RegistrySnapshot()
	if snapshot.Pending != 0 || snapshot.Active != 0 {
		t.Fatalf("unexpected snapshot: %#v", snapshot)
	}
}

func TestRegisterIsRateLimitedBySource(t *testing.T) {
	t.Parallel()
	clock := &testClock{now: time.Date(2026, 7, 14, 0, 0, 0, 0, time.UTC)}
	server := NewServer(Config{
		Clock:             clock,
		CodeGenerator:     &testCodes{codes: []string{"01ABCD23", "45EFGH67"}},
		WriteQueueSize:    8,
		RateLimitBurst:    1,
		RateLimitInterval: time.Hour,
	}, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	httpServer := httptest.NewServer(server.Handler())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
		httpServer.Close()
	})
	url := "ws" + strings.TrimPrefix(httpServer.URL, "http") + "/ws"

	dial := func() *websocket.Conn {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		connection, _, err := websocket.Dial(ctx, url, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { connection.CloseNow() })
		return connection
	}
	first := dial()
	writeMessage(t, first, "register-1", protocol.TypeReceiverRegister, protocol.ReceiverRegisterPayload{})
	readMessage(t, first)
	second := dial()
	writeMessage(t, second, "register-2", protocol.TypeReceiverRegister, protocol.ReceiverRegisterPayload{})
	_, payload, _ := readMessage(t, second)
	if payload.(protocol.ErrorPayload).Code != "rate_limited" {
		t.Fatalf("unexpected rate limit response: %#v", payload)
	}
}

func TestIdleWebSocketConnectionsAreAdmissionLimited(t *testing.T) {
	t.Parallel()
	server := NewServer(Config{
		MaxConnections:           1,
		ConnectionRateLimitBurst: 100,
		WriteQueueSize:           8,
	}, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	httpServer := httptest.NewServer(server.Handler())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
		httpServer.Close()
	})
	url := "ws" + strings.TrimPrefix(httpServer.URL, "http") + "/ws"
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	first, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer first.CloseNow()

	second, response, err := websocket.Dial(ctx, url, nil)
	if second != nil {
		second.CloseNow()
	}
	if err == nil || response == nil || response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("second dial error/status = %v/%v, want HTTP 503", err, response)
	}
}

func TestWebSocketUpgradeIsRateLimitedBeforeAdmission(t *testing.T) {
	t.Parallel()
	server := NewServer(Config{
		MaxConnections:              10,
		ConnectionRateLimitBurst:    1,
		ConnectionRateLimitInterval: time.Hour,
		WriteQueueSize:              8,
	}, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	httpServer := httptest.NewServer(server.Handler())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
		httpServer.Close()
	})
	url := "ws" + strings.TrimPrefix(httpServer.URL, "http") + "/ws"
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	first, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer first.CloseNow()

	second, response, err := websocket.Dial(ctx, url, nil)
	if second != nil {
		second.CloseNow()
	}
	if err == nil || response == nil || response.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("second dial error/status = %v/%v, want HTTP 429", err, response)
	}
}

func TestClientSourceUsesForwardingChainOnlyFromTrustedProxy(t *testing.T) {
	t.Parallel()
	trusted := []netip.Prefix{netip.MustParsePrefix("10.42.0.0/16")}

	proxied := httptest.NewRequest(http.MethodGet, "http://example.test/ws", nil)
	proxied.RemoteAddr = "10.42.3.4:12345"
	proxied.Header.Set("X-Forwarded-For", "203.0.113.7, 10.42.2.9")
	if got := clientSource(proxied, trusted); got != "203.0.113.7" {
		t.Fatalf("trusted proxy source = %q", got)
	}
	proxied.Header.Set("X-Forwarded-For", "garbage, 203.0.113.7")
	if got := clientSource(proxied, trusted); got != "203.0.113.7" {
		t.Fatalf("nearest valid untrusted source = %q", got)
	}

	forged := httptest.NewRequest(http.MethodGet, "http://example.test/ws", nil)
	forged.RemoteAddr = "198.51.100.12:54321"
	forged.Header.Set("X-Forwarded-For", "203.0.113.99")
	if got := clientSource(forged, trusted); got != "198.51.100.12" {
		t.Fatalf("untrusted source = %q", got)
	}
}

func TestMaintenancePrunesConnectionRateLimitSources(t *testing.T) {
	t.Parallel()
	clock := &testClock{now: time.Date(2026, 7, 14, 0, 0, 0, 0, time.UTC)}
	server := NewServer(Config{
		Clock:                       clock,
		ExpireInterval:              time.Millisecond,
		ConnectionRateLimitBurst:    1,
		ConnectionRateLimitInterval: time.Hour,
	}, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	})

	for index := 0; index < 100; index++ {
		server.connectionLimiter.Allow(fmt.Sprintf("203.0.113.%d", index))
	}
	clock.Advance(3 * time.Hour)
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		server.connectionLimiter.mu.Lock()
		remaining := len(server.connectionLimiter.buckets)
		server.connectionLimiter.mu.Unlock()
		if remaining == 0 {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("connection limiter retained expired source buckets")
}

func TestShutdownWaitsForReservedWebSocketHandler(t *testing.T) {
	reserved := make(chan struct{})
	proceed := make(chan struct{})
	server := NewServer(Config{
		WriteQueueSize: 8,
		afterConnectionReserved: func() {
			close(reserved)
			<-proceed
		},
	}, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	httpServer := httptest.NewServer(server.Handler())
	t.Cleanup(func() {
		closeIfOpen(proceed)
		httpServer.Close()
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	})

	dialDone := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		connection, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(httpServer.URL, "http")+"/ws", nil)
		if connection != nil {
			connection.CloseNow()
		}
		dialDone <- err
	}()
	<-reserved

	shutdownDone := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		shutdownDone <- server.Shutdown(ctx)
	}()
	select {
	case err := <-shutdownDone:
		t.Fatalf("shutdown returned before reserved handler completed: %v", err)
	case <-time.After(50 * time.Millisecond):
	}

	close(proceed)
	_ = <-dialDone // Either an accepted socket or a shutdown-related dial error is valid.
	if err := <-shutdownDone; err != nil {
		t.Fatalf("shutdown failed: %v", err)
	}
}

func closeIfOpen(channel chan struct{}) {
	select {
	case <-channel:
	default:
		close(channel)
	}
}

func TestPairingExpiryNotifiesReceiver(t *testing.T) {
	t.Parallel()
	clock := &testClock{now: time.Date(2026, 7, 14, 0, 0, 0, 0, time.UTC)}
	server := NewServer(Config{
		Clock:          clock,
		CodeGenerator:  &testCodes{codes: []string{"01ABCD23"}},
		PairingTTL:     10 * time.Minute,
		ExpireInterval: time.Millisecond,
		WriteQueueSize: 8,
	}, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	httpServer := httptest.NewServer(server.Handler())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
		httpServer.Close()
	})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	receiver, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(httpServer.URL, "http")+"/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { receiver.CloseNow() })
	writeMessage(t, receiver, "register", protocol.TypeReceiverRegister, protocol.ReceiverRegisterPayload{})
	readMessage(t, receiver)
	clock.Advance(10*time.Minute + time.Nanosecond)

	_, payload, _ := readMessage(t, receiver)
	if payload.(protocol.ErrorPayload).Code != "pairing_expired" {
		t.Fatalf("unexpected expiry response: %#v", payload)
	}
}
