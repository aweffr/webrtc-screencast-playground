package signaling

import (
	"context"
	"sync/atomic"
	"time"

	"github.com/aweffr/webrtc-screencast-playground/server/internal/protocol"
	"github.com/coder/websocket"
)

type outboundMessage struct {
	data       []byte
	closeAfter bool
}

type peer struct {
	id         string
	source     string
	connection *websocket.Conn
	outbound   chan outboundMessage
	ctx        context.Context
	cancel     context.CancelFunc
	closed     atomic.Bool

	// The server mutex protects the fields below.
	role        protocol.Role
	sessionID   string
	paired      bool
	counterpart *peer
}

func newPeer(parent context.Context, id, source string, connection *websocket.Conn, queueSize int) *peer {
	ctx, cancel := context.WithCancel(parent)
	return &peer{
		id:         id,
		source:     source,
		connection: connection,
		outbound:   make(chan outboundMessage, queueSize),
		ctx:        ctx,
		cancel:     cancel,
	}
}

func (peer *peer) enqueue(message outboundMessage) bool {
	if peer.closed.Load() {
		return false
	}
	select {
	case peer.outbound <- message:
		return true
	case <-peer.ctx.Done():
		return false
	default:
		return false
	}
}

func (peer *peer) stop() {
	if peer.closed.CompareAndSwap(false, true) {
		peer.cancel()
		peer.connection.CloseNow()
	}
}

func (peer *peer) writeLoop(pingInterval time.Duration) {
	var ping <-chan time.Time
	var ticker *time.Ticker
	if pingInterval > 0 {
		ticker = time.NewTicker(pingInterval)
		ping = ticker.C
		defer ticker.Stop()
	}
	defer peer.cancel()

	for {
		select {
		case <-peer.ctx.Done():
			return
		case <-ping:
			ctx, cancel := context.WithTimeout(peer.ctx, 5*time.Second)
			err := peer.connection.Ping(ctx)
			cancel()
			if err != nil {
				return
			}
		case message := <-peer.outbound:
			ctx, cancel := context.WithTimeout(peer.ctx, 5*time.Second)
			err := peer.connection.Write(ctx, websocket.MessageText, message.data)
			cancel()
			if err != nil {
				return
			}
			if message.closeAfter {
				_ = peer.connection.Close(websocket.StatusNormalClosure, "session ended")
				return
			}
		}
	}
}
