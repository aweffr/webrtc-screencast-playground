package session

import (
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (clock *fakeClock) Now() time.Time {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	return clock.now
}

func (clock *fakeClock) Advance(duration time.Duration) {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	clock.now = clock.now.Add(duration)
}

type sequenceCodes struct {
	mu    sync.Mutex
	codes []string
}

func (generator *sequenceCodes) Generate() (string, error) {
	generator.mu.Lock()
	defer generator.mu.Unlock()
	if len(generator.codes) == 0 {
		return "", errors.New("no codes")
	}
	code := generator.codes[0]
	generator.codes = generator.codes[1:]
	return code, nil
}

func newTestRegistry(clock *fakeClock, codes ...string) *Registry {
	return NewRegistry(clock, &sequenceCodes{codes: codes}, Limits{
		PairingTTL: 10 * time.Minute,
		MaxPending: 10,
		MaxActive:  10,
	})
}

func TestRegisterReceiverCreatesExpiringPendingCode(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 7, 14, 0, 0, 0, 0, time.UTC)
	clock := &fakeClock{now: now}
	registry := newTestRegistry(clock, "01ABCD23")

	pending, err := registry.RegisterReceiver("receiver-1")
	if err != nil {
		t.Fatalf("RegisterReceiver returned error: %v", err)
	}
	if pending.Code != "01ABCD23" || pending.ReceiverID != "receiver-1" || pending.SessionID == "" {
		t.Fatalf("unexpected pending session: %#v", pending)
	}
	if want := now.Add(10 * time.Minute); !pending.ExpiresAt.Equal(want) {
		t.Fatalf("ExpiresAt = %v, want %v", pending.ExpiresAt, want)
	}
	if snapshot := registry.Snapshot(); snapshot.Pending != 1 || snapshot.Active != 0 {
		t.Fatalf("unexpected snapshot: %#v", snapshot)
	}
}

func TestJoinConsumesCodeOnce(t *testing.T) {
	t.Parallel()

	clock := &fakeClock{now: time.Now()}
	registry := newTestRegistry(clock, "01ABCD23")
	pending, err := registry.RegisterReceiver("receiver-1")
	if err != nil {
		t.Fatal(err)
	}

	pair, err := registry.JoinSender("sender-1", "01ab-cd23")
	if err != nil {
		t.Fatalf("JoinSender returned error: %v", err)
	}
	if pair.SessionID != pending.SessionID || pair.ReceiverID != "receiver-1" || pair.SenderID != "sender-1" {
		t.Fatalf("unexpected pair: %#v", pair)
	}
	if _, err := registry.JoinSender("sender-2", "01ABCD23"); !errors.Is(err, ErrCodeUnavailable) {
		t.Fatalf("second join error = %v, want ErrCodeUnavailable", err)
	}
	if snapshot := registry.Snapshot(); snapshot.Pending != 0 || snapshot.Active != 1 {
		t.Fatalf("unexpected snapshot: %#v", snapshot)
	}
}

func TestConcurrentJoinHasExactlyOneWinner(t *testing.T) {
	t.Parallel()

	clock := &fakeClock{now: time.Now()}
	registry := newTestRegistry(clock, "01ABCD23")
	if _, err := registry.RegisterReceiver("receiver-1"); err != nil {
		t.Fatal(err)
	}

	const contenders = 64
	var successes atomic.Int64
	var unexpected atomic.Int64
	var waitGroup sync.WaitGroup
	for index := range contenders {
		waitGroup.Add(1)
		go func(index int) {
			defer waitGroup.Done()
			_, err := registry.JoinSender(fmt.Sprintf("sender-%d", index), "01ABCD23")
			switch {
			case err == nil:
				successes.Add(1)
			case errors.Is(err, ErrCodeUnavailable):
			default:
				unexpected.Add(1)
			}
		}(index)
	}
	waitGroup.Wait()

	if got := successes.Load(); got != 1 {
		t.Fatalf("successful joins = %d, want 1", got)
	}
	if got := unexpected.Load(); got != 0 {
		t.Fatalf("unexpected errors = %d, want 0", got)
	}
}

func TestExpiredCodeCannotJoin(t *testing.T) {
	t.Parallel()

	clock := &fakeClock{now: time.Now()}
	registry := newTestRegistry(clock, "01ABCD23")
	pending, err := registry.RegisterReceiver("receiver-1")
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(10*time.Minute + time.Nanosecond)

	expired := registry.Expire()
	if len(expired) != 1 || expired[0].SessionID != pending.SessionID {
		t.Fatalf("expired = %#v, want session %q", expired, pending.SessionID)
	}
	if _, err := registry.JoinSender("sender-1", "01ABCD23"); !errors.Is(err, ErrCodeUnavailable) {
		t.Fatalf("JoinSender error = %v, want ErrCodeUnavailable", err)
	}
}

func TestRegisterReceiverSkipsCollidingCode(t *testing.T) {
	t.Parallel()

	clock := &fakeClock{now: time.Now()}
	registry := newTestRegistry(clock, "01ABCD23", "01ABCD23", "45EFGH67")
	first, err := registry.RegisterReceiver("receiver-1")
	if err != nil {
		t.Fatal(err)
	}
	second, err := registry.RegisterReceiver("receiver-2")
	if err != nil {
		t.Fatal(err)
	}
	if first.Code == second.Code || second.Code != "45EFGH67" {
		t.Fatalf("codes = %q, %q", first.Code, second.Code)
	}
}

func TestRegistryEnforcesCapacityAndUniquePeers(t *testing.T) {
	t.Parallel()

	clock := &fakeClock{now: time.Now()}
	registry := NewRegistry(clock, &sequenceCodes{codes: []string{"01ABCD23", "45EFGH67"}}, Limits{
		PairingTTL: 10 * time.Minute,
		MaxPending: 1,
		MaxActive:  1,
	})
	if _, err := registry.RegisterReceiver("receiver-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := registry.RegisterReceiver("receiver-1"); !errors.Is(err, ErrPeerAlreadyRegistered) {
		t.Fatalf("duplicate receiver error = %v", err)
	}
	if _, err := registry.RegisterReceiver("receiver-2"); !errors.Is(err, ErrPendingCapacity) {
		t.Fatalf("capacity error = %v", err)
	}
	if _, err := registry.JoinSender("sender-1", "01ABCD23"); err != nil {
		t.Fatal(err)
	}
	if _, err := registry.RegisterReceiver("receiver-2"); err != nil {
		t.Fatalf("RegisterReceiver after pairing returned error: %v", err)
	}
	if _, err := registry.JoinSender("sender-2", "45EFGH67"); !errors.Is(err, ErrActiveCapacity) {
		t.Fatalf("active capacity error = %v", err)
	}
}

func TestRemovePeerCleansPendingAndActiveIndexes(t *testing.T) {
	t.Parallel()

	clock := &fakeClock{now: time.Now()}
	registry := newTestRegistry(clock, "01ABCD23", "45EFGH67")
	pending, err := registry.RegisterReceiver("receiver-pending")
	if err != nil {
		t.Fatal(err)
	}
	if removed := registry.RemovePeer("receiver-pending"); removed != nil {
		t.Fatalf("removed pending returned pair: %#v", removed)
	}
	if _, err := registry.JoinSender("sender-late", pending.Code); !errors.Is(err, ErrCodeUnavailable) {
		t.Fatalf("join after pending removal error = %v", err)
	}

	if _, err := registry.RegisterReceiver("receiver-active"); err != nil {
		t.Fatal(err)
	}
	pair, err := registry.JoinSender("sender-active", "45EFGH67")
	if err != nil {
		t.Fatal(err)
	}
	removed := registry.RemovePeer("sender-active")
	if removed == nil || *removed != pair {
		t.Fatalf("removed = %#v, want %#v", removed, pair)
	}
	if removedAgain := registry.RemovePeer("receiver-active"); removedAgain != nil {
		t.Fatalf("removed pair twice: %#v", removedAgain)
	}
	if snapshot := registry.Snapshot(); snapshot.Pending != 0 || snapshot.Active != 0 {
		t.Fatalf("unexpected snapshot: %#v", snapshot)
	}
}

func TestCryptoCodeGeneratorProducesValidCodes(t *testing.T) {
	t.Parallel()

	generator := CryptoCodeGenerator{}
	seen := make(map[string]struct{})
	for range 100 {
		code, err := generator.Generate()
		if err != nil {
			t.Fatal(err)
		}
		if len(code) != 8 {
			t.Fatalf("code length = %d, want 8", len(code))
		}
		if _, exists := seen[code]; exists {
			t.Fatalf("unexpected duplicate code %q", code)
		}
		seen[code] = struct{}{}
	}
}
