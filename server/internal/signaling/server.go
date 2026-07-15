package signaling

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	commonclock "github.com/aweffr/webrtc-screencast-playground/server/internal/clock"
	"github.com/aweffr/webrtc-screencast-playground/server/internal/observability"
	"github.com/aweffr/webrtc-screencast-playground/server/internal/protocol"
	"github.com/aweffr/webrtc-screencast-playground/server/internal/session"
	"github.com/coder/websocket"
)

type realClock struct{}

func (realClock) Now() time.Time { return time.Now() }

type Config struct {
	Clock                       session.Clock
	CodeGenerator               session.CodeGenerator
	PairingTTL                  time.Duration
	MaxPending                  int
	MaxActive                   int
	WriteQueueSize              int
	ReadLimit                   int64
	PingInterval                time.Duration
	ExpireInterval              time.Duration
	RateLimitBurst              int
	RateLimitInterval           time.Duration
	MaxConnections              int
	ConnectionRateLimitBurst    int
	ConnectionRateLimitInterval time.Duration
	TrustedProxyCIDRs           []netip.Prefix
	afterConnectionReserved     func()
}

type Server struct {
	mu sync.Mutex

	config            Config
	logger            *slog.Logger
	registry          *session.Registry
	metrics           *observability.Metrics
	limiter           *sourceLimiter
	connectionLimiter *sourceLimiter
	peers             map[string]*peer
	connectionSlots   int
	closing           bool

	ctx       context.Context
	cancel    context.CancelFunc
	waitGroup sync.WaitGroup
	messageID atomic.Uint64
}

func NewServer(config Config, logger *slog.Logger) *Server {
	if config.Clock == nil {
		config.Clock = realClock{}
	}
	if config.CodeGenerator == nil {
		config.CodeGenerator = session.CryptoCodeGenerator{}
	}
	if config.PairingTTL <= 0 {
		config.PairingTTL = 10 * time.Minute
	}
	if config.MaxPending <= 0 {
		config.MaxPending = 1000
	}
	if config.MaxActive <= 0 {
		config.MaxActive = 1000
	}
	if config.WriteQueueSize <= 0 {
		config.WriteQueueSize = 32
	}
	if config.ReadLimit <= 0 {
		config.ReadLimit = 256 * 1024
	}
	if config.ExpireInterval <= 0 {
		config.ExpireInterval = time.Second
	}
	if config.RateLimitBurst <= 0 {
		config.RateLimitBurst = 20
	}
	if config.RateLimitInterval <= 0 {
		config.RateLimitInterval = time.Second
	}
	if config.MaxConnections <= 0 {
		config.MaxConnections = 2000
	}
	if config.ConnectionRateLimitBurst <= 0 {
		config.ConnectionRateLimitBurst = 40
	}
	if config.ConnectionRateLimitInterval <= 0 {
		config.ConnectionRateLimitInterval = time.Second
	}
	if logger == nil {
		logger = slog.Default()
	}
	ctx, cancel := context.WithCancel(context.Background())
	server := &Server{
		config: config,
		logger: logger,
		registry: session.NewRegistry(config.Clock, config.CodeGenerator, session.Limits{
			PairingTTL: config.PairingTTL,
			MaxPending: config.MaxPending,
			MaxActive:  config.MaxActive,
		}),
		metrics:           observability.NewMetrics(),
		limiter:           newSourceLimiter(config.Clock, config.RateLimitBurst, config.RateLimitInterval),
		connectionLimiter: newSourceLimiter(config.Clock, config.ConnectionRateLimitBurst, config.ConnectionRateLimitInterval),
		peers:             make(map[string]*peer),
		ctx:               ctx,
		cancel:            cancel,
	}
	server.waitGroup.Add(1)
	go server.maintenanceLoop()
	return server
}

func (server *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write([]byte("ok\n"))
	})
	mux.Handle("/clock", commonclock.NewHandler(server.config.Clock.Now))
	mux.Handle("GET /metrics", server.metrics)
	mux.HandleFunc("GET /ws", server.handleWebSocket)
	return mux
}

func (server *Server) RegistrySnapshot() session.Snapshot {
	return server.registry.Snapshot()
}

func (server *Server) Shutdown(ctx context.Context) error {
	server.mu.Lock()
	server.closing = true
	peers := make([]*peer, 0, len(server.peers))
	for _, connectedPeer := range server.peers {
		peers = append(peers, connectedPeer)
	}
	server.mu.Unlock()
	server.cancel()
	for _, connectedPeer := range peers {
		connectedPeer.stop()
	}

	done := make(chan struct{})
	go func() {
		server.waitGroup.Wait()
		close(done)
	}()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (server *Server) handleWebSocket(writer http.ResponseWriter, request *http.Request) {
	source := clientSource(request, server.config.TrustedProxyCIDRs)
	if !server.connectionLimiter.Allow(source) {
		server.metrics.Rejection("rate_limited")
		http.Error(writer, "too many connection attempts", http.StatusTooManyRequests)
		return
	}
	if !server.reserveConnection() {
		server.metrics.Rejection("capacity")
		http.Error(writer, "connection capacity reached", http.StatusServiceUnavailable)
		return
	}
	defer server.releaseConnection()
	if server.config.afterConnectionReserved != nil {
		server.config.afterConnectionReserved()
	}

	connection, err := websocket.Accept(writer, request, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		server.logger.Warn("websocket_accept_failed", "error", err.Error())
		return
	}
	connection.SetReadLimit(server.config.ReadLimit)
	peerID, err := randomID()
	if err != nil {
		connection.CloseNow()
		return
	}
	connectedPeer := newPeer(server.ctx, peerID, source, connection, server.config.WriteQueueSize)
	server.mu.Lock()
	server.peers[peerID] = connectedPeer
	server.mu.Unlock()
	server.metrics.ConnectionOpened()
	server.logger.Info("peer_connected", "peer_id", shortID(peerID))

	defer func() {
		server.cleanupPeer(connectedPeer, true, "peer_disconnected")
		connectedPeer.stop()
		server.metrics.ConnectionClosed()
		server.logger.Info("peer_disconnected", "peer_id", shortID(peerID))
	}()
	go connectedPeer.writeLoop(server.config.PingInterval)

	for {
		messageType, data, err := connection.Read(connectedPeer.ctx)
		if err != nil {
			return
		}
		if messageType != websocket.MessageText {
			server.metrics.Rejection("invalid_message")
			server.sendError(connectedPeer, "invalid_message", "text messages are required", "")
			continue
		}
		if !server.handleMessage(connectedPeer, data) {
			return
		}
	}
}

func (server *Server) reserveConnection() bool {
	server.mu.Lock()
	defer server.mu.Unlock()
	if server.closing || server.connectionSlots >= server.config.MaxConnections {
		return false
	}
	server.connectionSlots++
	server.waitGroup.Add(1)
	return true
}

func (server *Server) releaseConnection() {
	server.mu.Lock()
	if server.connectionSlots > 0 {
		server.connectionSlots--
	}
	server.mu.Unlock()
	server.waitGroup.Done()
}

func (server *Server) handleMessage(connectedPeer *peer, data []byte) bool {
	envelope, payload, err := protocol.Decode(data)
	if err != nil {
		server.metrics.Rejection("invalid_message")
		server.sendError(connectedPeer, "invalid_message", "message is invalid", "")
		return true
	}
	server.metrics.Message(string(envelope.Type))

	switch envelope.Type {
	case protocol.TypeReceiverRegister:
		return server.handleRegister(connectedPeer, envelope.MessageID)
	case protocol.TypeSenderJoin:
		return server.handleJoin(connectedPeer, envelope.MessageID, payload.(protocol.SenderJoinPayload))
	case protocol.TypeSDPOffer, protocol.TypeSDPAnswer, protocol.TypeICECandidate, protocol.TypeICEComplete:
		return server.handleRelay(connectedPeer, envelope, data)
	case protocol.TypeSessionHangup:
		return server.handleHangup(connectedPeer, data)
	default:
		server.metrics.Rejection("invalid_state")
		server.sendError(connectedPeer, "invalid_state", "message is not accepted from a client", envelope.MessageID)
		return true
	}
}

func (server *Server) handleRegister(connectedPeer *peer, relatedMessageID string) bool {
	if !server.limiter.Allow(connectedPeer.source) {
		server.metrics.Rejection("rate_limited")
		server.sendError(connectedPeer, "rate_limited", "too many pairing attempts", relatedMessageID)
		return true
	}
	server.mu.Lock()
	hasRole := connectedPeer.role != ""
	server.mu.Unlock()
	if hasRole {
		server.metrics.Rejection("invalid_state")
		server.sendError(connectedPeer, "invalid_state", "role is already registered", relatedMessageID)
		return true
	}
	pending, err := server.registry.RegisterReceiver(connectedPeer.id)
	if err != nil {
		server.handleRegistryError(connectedPeer, relatedMessageID, err)
		return true
	}
	server.mu.Lock()
	connectedPeer.role = protocol.RoleReceiver
	connectedPeer.sessionID = pending.SessionID
	server.mu.Unlock()
	server.updateRegistryMetrics()
	server.send(connectedPeer, protocol.TypeReceiverRegistered, protocol.ReceiverRegisteredPayload{
		SessionID:   pending.SessionID,
		PairingCode: pending.Code,
		ExpiresAt:   pending.ExpiresAt,
	}, false)
	server.logger.Info("receiver_registered", "session_id", pending.SessionID)
	return true
}

func (server *Server) handleJoin(connectedPeer *peer, relatedMessageID string, payload protocol.SenderJoinPayload) bool {
	if !server.limiter.Allow(connectedPeer.source) {
		server.metrics.Rejection("rate_limited")
		server.sendError(connectedPeer, "rate_limited", "too many pairing attempts", relatedMessageID)
		return true
	}
	server.mu.Lock()
	hasRole := connectedPeer.role != ""
	server.mu.Unlock()
	if hasRole {
		server.metrics.Rejection("invalid_state")
		server.sendError(connectedPeer, "invalid_state", "role is already registered", relatedMessageID)
		return true
	}
	pair, err := server.registry.JoinSender(connectedPeer.id, payload.PairingCode)
	if err != nil {
		server.handleRegistryError(connectedPeer, relatedMessageID, err)
		return true
	}

	server.mu.Lock()
	receiver := server.peers[pair.ReceiverID]
	if receiver != nil {
		connectedPeer.role = protocol.RoleSender
		connectedPeer.sessionID = pair.SessionID
		connectedPeer.paired = true
		connectedPeer.counterpart = receiver
		receiver.paired = true
		receiver.counterpart = connectedPeer
	}
	server.mu.Unlock()
	if receiver == nil {
		server.registry.RemovePeer(connectedPeer.id)
		server.updateRegistryMetrics()
		server.metrics.Rejection("internal")
		server.sendError(connectedPeer, "internal", "receiver is unavailable", relatedMessageID)
		return true
	}

	server.metrics.PairingCreated()
	server.updateRegistryMetrics()
	server.send(receiver, protocol.TypeSessionPaired, protocol.SessionPairedPayload{SessionID: pair.SessionID, Role: protocol.RoleReceiver}, false)
	server.send(connectedPeer, protocol.TypeSessionPaired, protocol.SessionPairedPayload{SessionID: pair.SessionID, Role: protocol.RoleSender}, false)
	server.logger.Info("session_paired", "session_id", pair.SessionID)
	return true
}

func (server *Server) handleRelay(connectedPeer *peer, envelope protocol.Envelope, data []byte) bool {
	server.mu.Lock()
	paired := connectedPeer.paired
	role := connectedPeer.role
	counterpart := connectedPeer.counterpart
	server.mu.Unlock()
	if !paired || counterpart == nil || !messageAllowedForRole(role, envelope.Type) {
		server.metrics.Rejection("invalid_state")
		server.sendError(connectedPeer, "invalid_state", "message is not valid in the current session state", envelope.MessageID)
		return true
	}
	if !counterpart.enqueue(outboundMessage{data: append([]byte(nil), data...)}) {
		server.metrics.Rejection("slow_peer")
		server.cleanupPeer(counterpart, true, "slow_peer")
		return false
	}
	return true
}

func (server *Server) handleHangup(connectedPeer *peer, data []byte) bool {
	server.mu.Lock()
	paired := connectedPeer.paired
	counterpart := connectedPeer.counterpart
	server.mu.Unlock()
	if !paired || counterpart == nil {
		server.metrics.Rejection("invalid_state")
		server.sendError(connectedPeer, "invalid_state", "session is not paired", "")
		return true
	}
	server.endPair(connectedPeer)
	if !counterpart.enqueue(outboundMessage{data: append([]byte(nil), data...), closeAfter: true}) {
		counterpart.stop()
	}
	return false
}

func (server *Server) handleRegistryError(connectedPeer *peer, relatedMessageID string, err error) {
	switch {
	case errors.Is(err, session.ErrCodeUnavailable):
		server.metrics.Rejection("code_unavailable")
		server.sendError(connectedPeer, "code_unavailable", "pairing code is unavailable", relatedMessageID)
	case errors.Is(err, session.ErrPendingCapacity), errors.Is(err, session.ErrActiveCapacity):
		server.metrics.Rejection("capacity")
		server.sendError(connectedPeer, "capacity", "signaling service is at capacity", relatedMessageID)
	case errors.Is(err, session.ErrPeerAlreadyRegistered):
		server.metrics.Rejection("invalid_state")
		server.sendError(connectedPeer, "invalid_state", "peer is already registered", relatedMessageID)
	default:
		server.metrics.Rejection("internal")
		server.sendError(connectedPeer, "internal", "signaling service failed", relatedMessageID)
	}
}

func (server *Server) sendError(connectedPeer *peer, code, message, relatedMessageID string) {
	server.send(connectedPeer, protocol.TypeError, protocol.ErrorPayload{
		Code:             code,
		Message:          message,
		RelatedMessageID: relatedMessageID,
	}, false)
}

func (server *Server) send(connectedPeer *peer, messageType protocol.MessageType, payload any, closeAfter bool) {
	data, err := protocol.Encode(server.nextMessageID(), messageType, payload)
	if err != nil {
		server.logger.Error("server_message_encode_failed", "type", string(messageType), "error", err.Error())
		connectedPeer.stop()
		return
	}
	if !connectedPeer.enqueue(outboundMessage{data: data, closeAfter: closeAfter}) {
		server.metrics.Rejection("slow_peer")
		connectedPeer.stop()
	}
}

func (server *Server) cleanupPeer(connectedPeer *peer, notify bool, reason string) {
	server.mu.Lock()
	delete(server.peers, connectedPeer.id)
	counterpart := connectedPeer.counterpart
	connectedPeer.paired = false
	connectedPeer.counterpart = nil
	if counterpart != nil && counterpart.counterpart == connectedPeer {
		counterpart.paired = false
		counterpart.counterpart = nil
	}
	server.mu.Unlock()

	removed := server.registry.RemovePeer(connectedPeer.id)
	server.updateRegistryMetrics()
	if notify && removed != nil && counterpart != nil {
		server.send(counterpart, protocol.TypeSessionHangup, protocol.SessionHangupPayload{Reason: reason}, true)
	}
}

func (server *Server) endPair(connectedPeer *peer) {
	server.mu.Lock()
	counterpart := connectedPeer.counterpart
	connectedPeer.paired = false
	connectedPeer.counterpart = nil
	if counterpart != nil && counterpart.counterpart == connectedPeer {
		counterpart.paired = false
		counterpart.counterpart = nil
	}
	server.mu.Unlock()
	server.registry.RemovePeer(connectedPeer.id)
	server.updateRegistryMetrics()
}

func (server *Server) updateRegistryMetrics() {
	snapshot := server.registry.Snapshot()
	server.metrics.SetRegistry(snapshot.Pending, snapshot.Active)
}

func (server *Server) maintenanceLoop() {
	defer server.waitGroup.Done()
	ticker := time.NewTicker(server.config.ExpireInterval)
	defer ticker.Stop()
	for {
		select {
		case <-server.ctx.Done():
			return
		case <-ticker.C:
			server.limiter.Prune()
			server.connectionLimiter.Prune()
			expired := server.registry.Expire()
			if len(expired) == 0 {
				continue
			}
			server.metrics.Expired(len(expired))
			server.updateRegistryMetrics()
			for _, pending := range expired {
				server.mu.Lock()
				connectedPeer := server.peers[pending.ReceiverID]
				server.mu.Unlock()
				if connectedPeer != nil {
					server.sendError(connectedPeer, "pairing_expired", "pairing code expired", "")
				}
			}
		}
	}
}

func messageAllowedForRole(role protocol.Role, messageType protocol.MessageType) bool {
	switch messageType {
	case protocol.TypeSDPOffer:
		return role == protocol.RoleSender
	case protocol.TypeSDPAnswer:
		return role == protocol.RoleReceiver
	case protocol.TypeICECandidate, protocol.TypeICEComplete:
		return role == protocol.RoleSender || role == protocol.RoleReceiver
	default:
		return false
	}
}

func (server *Server) nextMessageID() string {
	return fmt.Sprintf("server-%d", server.messageID.Add(1))
}

func randomID() (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}

func shortID(value string) string {
	if len(value) <= 8 {
		return value
	}
	return value[:8]
}

func sourceHost(remoteAddress string) string {
	host, _, err := net.SplitHostPort(remoteAddress)
	if err != nil {
		return remoteAddress
	}
	return host
}

func clientSource(request *http.Request, trustedProxyCIDRs []netip.Prefix) string {
	remoteText := sourceHost(request.RemoteAddr)
	remote, err := netip.ParseAddr(remoteText)
	if err != nil {
		return remoteText
	}
	remote = remote.Unmap()
	if !addressInPrefixes(remote, trustedProxyCIDRs) {
		return remote.String()
	}

	forwarded := strings.Split(request.Header.Get("X-Forwarded-For"), ",")
	candidate := remote
	for index := len(forwarded) - 1; index >= 0; index-- {
		if !addressInPrefixes(candidate, trustedProxyCIDRs) {
			return candidate.String()
		}
		value := strings.TrimSpace(forwarded[index])
		if value == "" {
			continue
		}
		address, parseErr := netip.ParseAddr(value)
		if parseErr != nil {
			return candidate.String()
		}
		candidate = address.Unmap()
	}
	return candidate.String()
}

func addressInPrefixes(address netip.Addr, prefixes []netip.Prefix) bool {
	for _, prefix := range prefixes {
		if prefix.Contains(address) {
			return true
		}
	}
	return false
}
