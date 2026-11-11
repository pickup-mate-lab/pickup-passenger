package main

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

type fakeVerifier map[string]identity

func (f fakeVerifier) Verify(_ context.Context, token string) (identity, error) {
	v, ok := f[token]
	if !ok {
		return identity{}, errors.New("invalid token")
	}
	return v, nil
}

func TestVerifiedPhoneBasedPickupIsolation(t *testing.T) {
	s := newStore(false)
	s.verifier = fakeVerifier{"driver": {UID: "driver-1", Phone: "+821011111111"}, "passenger": {UID: "passenger-1", Phone: "+821022222222"}, "other": {UID: "other", Phone: "+821033333333"}, "samePhoneNewUID": {UID: "passenger-2", Phone: "+821022222222"}}
	code, _ := call(t, s, "POST", "/api/sessions", "", map[string]any{"contactName": "x"})
	if code != 404 {
		t.Fatalf("legacy route exposed: %d", code)
	}
	code, _ = call(t, s, "POST", "/api/v1/pickups", "bad", map[string]any{"contactName": "x", "passengerPhone": "+821022222222"})
	if code != 401 {
		t.Fatal(code)
	}
	code, _ = call(t, s, "POST", "/api/v1/pickups", "driver", map[string]any{"contactName": "x", "passengerPhone": "01022222222"})
	if code != 400 {
		t.Fatal("un-normalized phone accepted", code)
	}
	code, created := call(t, s, "POST", "/api/v1/pickups", "driver", map[string]any{"contactName": "테스트", "passengerPhone": "+821022222222"})
	if code != 201 {
		t.Fatal(created)
	}
	id := created["id"].(string)
	if created["driverToken"] != nil || created["passengerToken"] != nil {
		t.Fatal("role token leaked")
	}
	code, inbox := call(t, s, "GET", "/api/v1/inbox", "passenger", nil)
	if code != 200 || len(inbox["requests"].([]any)) != 1 {
		t.Fatal(inbox)
	}
	code, inbox = call(t, s, "GET", "/api/v1/inbox", "other", nil)
	if code != 200 || len(inbox["requests"].([]any)) != 0 {
		t.Fatal(inbox)
	}
	path := "/api/v1/pickups/" + id
	code, _ = call(t, s, "GET", path, "other", nil)
	if code != 404 {
		t.Fatal("unrelated user accessed pickup", code)
	}
	code, _ = call(t, s, "POST", path+"/pickup", "driver", map[string]any{"lat": 37.5, "lon": 127.0, "label": "출구"})
	if code != 403 {
		t.Fatal("driver set pickup", code)
	}
	code, _ = call(t, s, "POST", path+"/pickup", "samePhoneNewUID", map[string]any{"lat": 37.5, "lon": 127.0, "label": "출구"})
	if code != 200 {
		t.Fatal("verified phone owner cannot accept", code)
	}
	code, _ = call(t, s, "POST", path+"/confirm", "driver", map[string]any{"revision": 1})
	if code != 200 {
		t.Fatal(code)
	}
	code, _ = call(t, s, "POST", path+"/finish", "passenger", map[string]any{})
	if code != 403 {
		t.Fatal("passenger finished as driver", code)
	}
}

func TestAccountEndpointsFailClosedWithoutVerifier(t *testing.T) {
	s := newStore(false)
	code, _ := call(t, s, "GET", "/api/v1/inbox", "token", nil)
	if code != 503 {
		t.Fatal(code)
	}
}

func TestAccountPickupSurvivesRestartButLocationSharingDoesNot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pickup.db")
	verifier := fakeVerifier{"driver": {UID: "d", Phone: "+821011111111"}, "passenger": {UID: "p", Phone: "+821022222222"}}
	s := newStore(false)
	s.verifier = verifier
	if err := s.openStorage(path); err != nil {
		t.Fatal(err)
	}
	code, created := call(t, s, "POST", "/api/v1/pickups", "driver", map[string]any{"contactName": "P", "passengerPhone": "+821022222222"})
	if code != 201 {
		t.Fatal(created)
	}
	id := created["id"].(string)
	base := "/api/v1/pickups/" + id
	code, _ = call(t, s, "POST", base+"/pickup", "passenger", map[string]any{"lat": 37.5, "lon": 127.0, "label": "출구"})
	if code != 200 {
		t.Fatal(code)
	}
	_, _ = call(t, s, "POST", base+"/location-consent", "passenger", map[string]any{"enabled": true})
	_, _ = call(t, s, "POST", base+"/location", "passenger", map[string]any{"lat": 37.5, "lon": 127.0})
	if err := s.db.Close(); err != nil {
		t.Fatal(err)
	}
	restarted := newStore(false)
	restarted.verifier = verifier
	if err := restarted.openStorage(path); err != nil {
		t.Fatal(err)
	}
	defer restarted.db.Close()
	code, view := call(t, restarted, "GET", base, "driver", nil)
	if code != 200 || view["pickup"] == nil || view["passengerLocation"] != nil || view["passengerLocationSharing"] != false {
		t.Fatal(view)
	}
	_, _ = call(t, restarted, "POST", base+"/finish", "driver", map[string]any{})
	if err := restarted.db.Close(); err != nil {
		t.Fatal(err)
	}
	final := newStore(false)
	final.verifier = verifier
	if err := final.openStorage(path); err != nil {
		t.Fatal(err)
	}
	defer final.db.Close()
	code, _ = call(t, final, "GET", base, "driver", nil)
	if code != 404 {
		t.Fatal("finished pickup retained", code)
	}
}

type fakePush struct{ sent chan string }

func (p fakePush) Send(_ context.Context, token, title, body string) error {
	p.sent <- token + "|" + body
	return nil
}
func TestNotificationsAreAuthorizedAndArrivalIsSentOnce(t *testing.T) {
	s := newStore(false)
	s.verifier = fakeVerifier{"driver": {UID: "d", Phone: "+821011111111"}, "passenger": {UID: "p", Phone: "+821022222222"}}
	push := fakePush{sent: make(chan string, 10)}
	s.push = push
	code, _ := call(t, s, "POST", "/api/v1/device", "passenger", map[string]any{"token": "device-token"})
	if code != 200 {
		t.Fatal(code)
	}
	code, p := call(t, s, "POST", "/api/v1/pickups", "driver", map[string]any{"contactName": "P", "passengerPhone": "+821022222222"})
	if code != 201 {
		t.Fatal(p)
	}
	select {
	case <-push.sent:
	case <-time.After(time.Second):
		t.Fatal("missing request push")
	}
	path := "/api/v1/pickups/" + p["id"].(string)
	_, _ = call(t, s, "POST", path+"/pickup", "passenger", map[string]any{"lat": 37.5, "lon": 127.0, "label": "출구"})
	_, _ = call(t, s, "POST", path+"/confirm", "driver", map[string]any{"revision": 1})
	_, _ = call(t, s, "POST", path+"/location", "driver", map[string]any{"lat": 37.5, "lon": 127.0, "etaSeconds": 240})
	select {
	case <-push.sent:
	case <-time.After(time.Second):
		t.Fatal("missing arrival push")
	}
	_, _ = call(t, s, "POST", path+"/location", "driver", map[string]any{"lat": 37.5, "lon": 127.0, "etaSeconds": 200})
	select {
	case <-push.sent:
		t.Fatal("duplicate arrival push")
	case <-time.After(50 * time.Millisecond):
	}
	code, _ = call(t, s, "DELETE", "/api/v1/device", "passenger", nil)
	if code != 200 {
		t.Fatal(code)
	}
}
