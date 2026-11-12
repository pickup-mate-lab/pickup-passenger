package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

type failingPush struct {
	calls    int
	failures int
}

func (f *failingPush) Send(_ context.Context, _, _, _ string) error {
	f.calls++
	if f.calls <= f.failures {
		return errors.New("unavailable")
	}
	return nil
}
func TestPushRetry(t *testing.T) {
	sender := &failingPush{failures: 2}
	if err := sendWithRetry(context.Background(), sender, "token", "message", []time.Duration{0, 0}); err != nil {
		t.Fatal(err)
	}
	if sender.calls != 3 {
		t.Fatalf("got %d attempts, want 3", sender.calls)
	}
}
func TestPushRetryStopsAfterLimit(t *testing.T) {
	sender := &failingPush{failures: 4}
	if err := sendWithRetry(context.Background(), sender, "token", "message", []time.Duration{0, 0}); err == nil {
		t.Fatal("expected error")
	}
	if sender.calls != 3 {
		t.Fatalf("got %d attempts, want 3", sender.calls)
	}
}
func TestPushRetryHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	sender := &failingPush{failures: 5}
	if err := sendWithRetry(ctx, sender, "token", "message", []time.Duration{time.Hour}); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
	if sender.calls > 1 {
		t.Fatalf("got %d attempts after cancellation", sender.calls)
	}
}
