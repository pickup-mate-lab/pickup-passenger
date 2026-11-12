package main

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPushOutboxSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pickup.db")
	s := newStore(false)
	if err := s.openStorage(path); err != nil {
		t.Fatal(err)
	}
	s.push = fakePush{sent: make(chan string, 2)}
	s.mu.Lock()
	p := s.create("P", "")
	p.DriverUID = "d"
	p.PassengerPhone = "+821022222222"
	id := p.ID
	s.devices["p"] = deviceRecord{UID: "p", Phone: p.PassengerPhone, Token: "device-token", UpdatedAt: time.Now()}
	if err := s.persistLocked(); err != nil {
		t.Fatal(err)
	}
	s.mu.Unlock()
	if !s.notify(func(d deviceRecord) bool { return d.UID == "p" }, "test", id, 0) {
		t.Fatal("enqueue failed")
	}
	if err := s.db.Close(); err != nil {
		t.Fatal(err)
	}
	next := newStore(false)
	if err := next.openStorage(path); err != nil {
		t.Fatal(err)
	}
	defer next.db.Close()
	sent := make(chan string, 2)
	next.push = fakePush{sent: sent}
	next.processPushOutbox(context.Background(), time.Now())
	select {
	case <-sent:
	case <-time.After(time.Second):
		t.Fatal("did not deliver queued push")
	}
	next.processPushOutbox(context.Background(), time.Now())
	select {
	case <-sent:
		t.Fatal("delivered already-acknowledged push twice")
	default:
	}
}

func TestPushOutboxDropsChangedPickup(t *testing.T) {
	s := newStore(false)
	if err := s.openStorage(filepath.Join(t.TempDir(), "pickup.db")); err != nil {
		t.Fatal(err)
	}
	defer s.db.Close()
	sent := make(chan string, 2)
	s.push = fakePush{sent: sent}
	s.mu.Lock()
	p := s.create("P", "")
	p.DriverUID = "d"
	p.PassengerPhone = "+821022222222"
	p.Revision = 1
	id := p.ID
	s.devices["p"] = deviceRecord{UID: "p", Phone: p.PassengerPhone, Token: "device-token", UpdatedAt: time.Now()}
	s.mu.Unlock()
	if !s.notify(func(d deviceRecord) bool { return d.UID == "p" }, "test", id, 1) {
		t.Fatal("enqueue failed")
	}
	s.mu.Lock()
	p.Revision = 2
	s.mu.Unlock()
	s.processPushOutbox(context.Background(), time.Now())
	select {
	case <-sent:
		t.Fatal("delivered obsolete pickup notification")
	default:
	}
}

func TestPushOutboxRetriesFailure(t *testing.T) {
	s := newStore(false)
	if err := s.openStorage(filepath.Join(t.TempDir(), "pickup.db")); err != nil {
		t.Fatal(err)
	}
	defer s.db.Close()
	push := &failingPush{failures: 1}
	s.push = push
	s.mu.Lock()
	p := s.create("P", "")
	p.DriverUID = "d"
	p.PassengerPhone = "+821022222222"
	id := p.ID
	s.devices["p"] = deviceRecord{UID: "p", Phone: p.PassengerPhone, Token: "device-token", UpdatedAt: time.Now()}
	s.mu.Unlock()
	if !s.notify(func(d deviceRecord) bool { return d.UID == "p" }, "test", id, 0) {
		t.Fatal("enqueue failed")
	}
	s.processPushOutbox(context.Background(), time.Now())
	if push.calls != 1 {
		t.Fatal(push.calls)
	}
	s.processPushOutbox(context.Background(), time.Now().Add(2*time.Minute))
	if push.calls != 2 {
		t.Fatal(push.calls)
	}
}

func TestArrivalQueuePersistsTogetherWithPickup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pickup.db")
	verifier := fakeVerifier{"d": {UID: "d", Phone: "+821011111111"}, "p": {UID: "p", Phone: "+821022222222"}}
	s := newStore(false)
	s.verifier = verifier
	if err := s.openStorage(path); err != nil {
		t.Fatal(err)
	}
	s.push = fakePush{sent: make(chan string, 8)}
	_, _ = call(t, s, "POST", "/api/v1/device", "p", map[string]any{"token": "device-token"})
	_, created := call(t, s, "POST", "/api/v1/pickups", "d", map[string]any{"contactName": "P", "passengerPhone": "+821022222222"})
	id := created["id"].(string)
	base := "/api/v1/pickups/" + id
	_, _ = call(t, s, "POST", base+"/pickup", "p", map[string]any{"lat": 37.5, "lon": 127.0, "label": "exit"})
	_, _ = call(t, s, "POST", base+"/confirm", "d", map[string]any{"revision": 1})
	_, _ = call(t, s, "POST", base+"/location", "d", map[string]any{"lat": 37.5, "lon": 127.0, "etaSeconds": 240})
	if err := s.db.Close(); err != nil {
		t.Fatal(err)
	}
	next := newStore(false)
	next.verifier = verifier
	if err := next.openStorage(path); err != nil {
		t.Fatal(err)
	}
	defer next.db.Close()
	sent := make(chan string, 8)
	next.push = fakePush{sent: sent}
	next.processPushOutbox(context.Background(), time.Now())
	// Request notification may be sent, but arrival must wait for fresh ETA.
	for len(sent) > 0 {
		if strings.Contains(<-sent, "곧 도착") {
			t.Fatal("sent arrival with stale ETA")
		}
	}
	_, _ = call(t, next, "POST", base+"/location", "d", map[string]any{"lat": 37.5, "lon": 127.0, "etaSeconds": 240})
	next.processPushOutbox(context.Background(), time.Now())
	found := false
	for len(sent) > 0 {
		if strings.Contains(<-sent, "곧 도착") {
			found = true
		}
	}
	if !found {
		t.Fatal("arrival notification was not retained")
	}
	if next.sessions[id].NotifiedRevision != 1 {
		t.Fatal("notification revision was not saved")
	}
}

func TestMessageAndPushAreRetainedTogether(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pickup.db")
	verifier := fakeVerifier{"d": {UID: "d", Phone: "+821011111111"}, "p": {UID: "p", Phone: "+821022222222"}}
	s := newStore(false)
	s.verifier = verifier
	if err := s.openStorage(path); err != nil {
		t.Fatal(err)
	}
	s.push = fakePush{sent: make(chan string, 8)}
	_, _ = call(t, s, "POST", "/api/v1/device", "p", map[string]any{"token": "device-token"})
	_, created := call(t, s, "POST", "/api/v1/pickups", "d", map[string]any{"contactName": "P", "passengerPhone": "+821022222222"})
	id := created["id"].(string)
	base := "/api/v1/pickups/" + id
	_, _ = call(t, s, "POST", base+"/pickup", "p", map[string]any{"lat": 37.5, "lon": 127.0, "label": "exit"})
	_, _ = call(t, s, "POST", base+"/confirm", "d", map[string]any{"revision": 1})
	code, _ := call(t, s, "POST", base+"/message", "d", map[string]any{"text": "private content"})
	if code != 200 {
		t.Fatal(code)
	}
	if err := s.db.Close(); err != nil {
		t.Fatal(err)
	}
	next := newStore(false)
	next.verifier = verifier
	if err := next.openStorage(path); err != nil {
		t.Fatal(err)
	}
	defer next.db.Close()
	if len(next.sessions[id].Messages) != 1 {
		t.Fatal("message was not retained")
	}
	sent := make(chan string, 8)
	next.push = fakePush{sent: sent}
	next.processPushOutbox(context.Background(), time.Now())
	found := false
	for len(sent) > 0 {
		m := <-sent
		if strings.Contains(m, "private content") {
			t.Fatal("message text leaked in push")
		}
		if strings.Contains(m, "메시지") {
			found = true
		}
	}
	if !found {
		t.Fatal("message notification was not retained")
	}
}

func TestWaitingPlaceChangeInvalidatesOldDeparture(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pickup.db")
	s := newStore(false)
	s.verifier = fakeVerifier{"d": {UID: "d", Phone: "+821011111111"}, "p": {UID: "p", Phone: "+821022222222"}}
	if err := s.openStorage(path); err != nil {
		t.Fatal(err)
	}
	defer s.db.Close()
	sent := make(chan string, 16)
	s.push = fakePush{sent: sent}
	s.walker = walkerFunc(func(_ context.Context, lat, lon, _, _ float64) (int, error) {
		if lat == 37.49 {
			return 180, nil
		}
		return 60, nil
	})
	_, _ = call(t, s, "POST", "/api/v1/device", "p", map[string]any{"token": "device-token"})
	_, created := call(t, s, "POST", "/api/v1/pickups", "d", map[string]any{"contactName": "P", "passengerPhone": "+821022222222"})
	base := "/api/v1/pickups/" + created["id"].(string)
	_, _ = call(t, s, "POST", base+"/pickup", "p", map[string]any{"lat": 37.5, "lon": 127.0, "label": "exit"})
	_, _ = call(t, s, "POST", base+"/confirm", "d", map[string]any{"revision": 1})
	code, _ := call(t, s, "POST", base+"/walking-estimate", "p", map[string]any{"lat": 37.49, "lon": 127.01})
	if code != 200 {
		t.Fatal(code)
	}
	_, _ = call(t, s, "POST", base+"/location", "d", map[string]any{"lat": 37.5, "lon": 127.0, "etaSeconds": 290})
	code, _ = call(t, s, "POST", base+"/walking-estimate", "p", map[string]any{"lat": 37.48, "lon": 127.02})
	if code != 200 {
		t.Fatal(code)
	}
	s.processPushOutbox(context.Background(), time.Now())
	for len(sent) > 0 {
		if strings.Contains(<-sent, "출발할 시간") {
			t.Fatal("sent obsolete departure notification")
		}
	}
	_, _ = call(t, s, "POST", base+"/location", "d", map[string]any{"lat": 37.5, "lon": 127.0, "etaSeconds": 180})
	s.processPushOutbox(context.Background(), time.Now())
	found := false
	for len(sent) > 0 {
		if strings.Contains(<-sent, "출발할 시간") {
			found = true
		}
	}
	if !found {
		t.Fatal("missing revised departure notification")
	}
}
