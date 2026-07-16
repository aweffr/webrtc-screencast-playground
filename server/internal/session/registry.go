package session

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/aweffr/webrtc-screencast-playground/server/internal/protocol"
)

var (
	ErrPendingCapacity       = errors.New("pending session capacity reached")
	ErrActiveCapacity        = errors.New("active session capacity reached")
	ErrCodeUnavailable       = errors.New("pairing code unavailable")
	ErrPeerAlreadyRegistered = errors.New("peer already registered")
)

type Clock interface {
	Now() time.Time
}

type CodeGenerator interface {
	Generate() (string, error)
}

type Limits struct {
	PairingTTL time.Duration
	MaxPending int
	MaxActive  int
}

type Pending struct {
	SessionID  string
	ReceiverID string
	Code       string
	ExpiresAt  time.Time
}

type Pair struct {
	SessionID  string
	ReceiverID string
	SenderID   string
}

type Snapshot struct {
	Pending int
	Active  int
}

type Registry struct {
	mu sync.Mutex

	clock  Clock
	codes  CodeGenerator
	limits Limits

	pendingByCode map[string]Pending
	pendingByPeer map[string]string
	pairsByPeer   map[string]Pair
}

func NewRegistry(clock Clock, codes CodeGenerator, limits Limits) *Registry {
	if limits.PairingTTL <= 0 {
		limits.PairingTTL = 10 * time.Minute
	}
	if limits.MaxPending <= 0 {
		limits.MaxPending = 1000
	}
	if limits.MaxActive <= 0 {
		limits.MaxActive = 1000
	}
	return &Registry{
		clock:         clock,
		codes:         codes,
		limits:        limits,
		pendingByCode: make(map[string]Pending),
		pendingByPeer: make(map[string]string),
		pairsByPeer:   make(map[string]Pair),
	}
}

func (registry *Registry) RegisterReceiver(receiverID string) (Pending, error) {
	registry.mu.Lock()
	defer registry.mu.Unlock()

	registry.expireLocked(registry.clock.Now())
	if receiverID == "" {
		return Pending{}, fmt.Errorf("%w: empty peer id", ErrPeerAlreadyRegistered)
	}
	if _, exists := registry.pendingByPeer[receiverID]; exists {
		return Pending{}, ErrPeerAlreadyRegistered
	}
	if _, exists := registry.pairsByPeer[receiverID]; exists {
		return Pending{}, ErrPeerAlreadyRegistered
	}
	if len(registry.pendingByCode) >= registry.limits.MaxPending {
		return Pending{}, ErrPendingCapacity
	}

	code, err := registry.uniqueCodeLocked()
	if err != nil {
		return Pending{}, err
	}
	sessionID, err := randomSessionID()
	if err != nil {
		return Pending{}, fmt.Errorf("generate session id: %w", err)
	}
	pending := Pending{
		SessionID:  sessionID,
		ReceiverID: receiverID,
		Code:       code,
		ExpiresAt:  registry.clock.Now().Add(registry.limits.PairingTTL),
	}
	registry.pendingByCode[code] = pending
	registry.pendingByPeer[receiverID] = code
	return pending, nil
}

func (registry *Registry) JoinSender(senderID, inputCode string) (Pair, error) {
	code, err := protocol.NormalizePairingCode(inputCode)
	if err != nil {
		return Pair{}, ErrCodeUnavailable
	}

	registry.mu.Lock()
	defer registry.mu.Unlock()

	registry.expireLocked(registry.clock.Now())
	if senderID == "" {
		return Pair{}, fmt.Errorf("%w: empty peer id", ErrPeerAlreadyRegistered)
	}
	if _, exists := registry.pendingByPeer[senderID]; exists {
		return Pair{}, ErrPeerAlreadyRegistered
	}
	if _, exists := registry.pairsByPeer[senderID]; exists {
		return Pair{}, ErrPeerAlreadyRegistered
	}
	pending, exists := registry.pendingByCode[code]
	if !exists {
		return Pair{}, ErrCodeUnavailable
	}
	if len(registry.pairsByPeer)/2 >= registry.limits.MaxActive {
		return Pair{}, ErrActiveCapacity
	}

	delete(registry.pendingByCode, code)
	delete(registry.pendingByPeer, pending.ReceiverID)
	pair := Pair{
		SessionID:  pending.SessionID,
		ReceiverID: pending.ReceiverID,
		SenderID:   senderID,
	}
	registry.pairsByPeer[pair.ReceiverID] = pair
	registry.pairsByPeer[pair.SenderID] = pair
	return pair, nil
}

func (registry *Registry) RemovePeer(peerID string) *Pair {
	registry.mu.Lock()
	defer registry.mu.Unlock()

	if code, exists := registry.pendingByPeer[peerID]; exists {
		delete(registry.pendingByPeer, peerID)
		delete(registry.pendingByCode, code)
		return nil
	}
	pair, exists := registry.pairsByPeer[peerID]
	if !exists {
		return nil
	}
	delete(registry.pairsByPeer, pair.ReceiverID)
	delete(registry.pairsByPeer, pair.SenderID)
	return &pair
}

func (registry *Registry) Expire() []Pending {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	return registry.expireLocked(registry.clock.Now())
}

func (registry *Registry) Snapshot() Snapshot {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	return Snapshot{
		Pending: len(registry.pendingByCode),
		Active:  len(registry.pairsByPeer) / 2,
	}
}

func (registry *Registry) expireLocked(now time.Time) []Pending {
	var expired []Pending
	for code, pending := range registry.pendingByCode {
		if now.Before(pending.ExpiresAt) {
			continue
		}
		delete(registry.pendingByCode, code)
		delete(registry.pendingByPeer, pending.ReceiverID)
		expired = append(expired, pending)
	}
	return expired
}

func (registry *Registry) uniqueCodeLocked() (string, error) {
	const attempts = 32
	for range attempts {
		generated, err := registry.codes.Generate()
		if err != nil {
			return "", fmt.Errorf("generate pairing code: %w", err)
		}
		code, err := protocol.NormalizePairingCode(generated)
		if err != nil {
			return "", fmt.Errorf("generate pairing code: %w", err)
		}
		if _, exists := registry.pendingByCode[code]; !exists {
			return code, nil
		}
	}
	return "", errors.New("generate pairing code: collision limit reached")
}

type CryptoCodeGenerator struct{}

func (CryptoCodeGenerator) Generate() (string, error) {
	const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
	randomBytes := make([]byte, protocol.PairingCodeLength)
	if _, err := rand.Read(randomBytes); err != nil {
		return "", err
	}
	code := make([]byte, len(randomBytes))
	for index, value := range randomBytes {
		code[index] = alphabet[int(value)&31]
	}
	return string(code), nil
}

func randomSessionID() (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}
