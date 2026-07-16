package signaling

import (
	"sync"
	"time"
)

type tokenBucket struct {
	tokens      float64
	lastUpdated time.Time
}

type sourceLimiter struct {
	mu sync.Mutex

	clock    interface{ Now() time.Time }
	burst    float64
	interval time.Duration
	buckets  map[string]tokenBucket
}

func newSourceLimiter(clock interface{ Now() time.Time }, burst int, interval time.Duration) *sourceLimiter {
	return &sourceLimiter{
		clock:    clock,
		burst:    float64(burst),
		interval: interval,
		buckets:  make(map[string]tokenBucket),
	}
}

func (limiter *sourceLimiter) Allow(source string) bool {
	limiter.mu.Lock()
	defer limiter.mu.Unlock()

	now := limiter.clock.Now()
	bucket, exists := limiter.buckets[source]
	if !exists {
		bucket = tokenBucket{tokens: limiter.burst, lastUpdated: now}
	} else if elapsed := now.Sub(bucket.lastUpdated); elapsed > 0 {
		bucket.tokens = min(limiter.burst, bucket.tokens+float64(elapsed)/float64(limiter.interval))
		bucket.lastUpdated = now
	}
	if bucket.tokens < 1 {
		limiter.buckets[source] = bucket
		return false
	}
	bucket.tokens--
	limiter.buckets[source] = bucket
	return true
}

func (limiter *sourceLimiter) Prune() {
	limiter.mu.Lock()
	defer limiter.mu.Unlock()

	now := limiter.clock.Now()
	retention := limiter.interval * time.Duration(int(limiter.burst)+1)
	for source, bucket := range limiter.buckets {
		if now.Sub(bucket.lastUpdated) > retention {
			delete(limiter.buckets, source)
		}
	}
}
