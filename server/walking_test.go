package main

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type walkerFunc func(context.Context, float64, float64, float64, float64) (int, error)

func (f walkerFunc) Estimate(ctx context.Context, a, b, c, d float64) (int, error) {
	return f(ctx, a, b, c, d)
}

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestTMAPWalkingResponse(t *testing.T) {
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("appKey") != "test-key" || r.URL.Host != "apis.openapi.sk.com" {
			t.Fatal("incorrect TMAP request")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"features":[{"properties":{"pointType":"SP","totalTime":300}}]}`)), Header: make(http.Header)}, nil
	})}
	seconds, err := (tmapWalker{key: "test-key", client: client}).Estimate(context.Background(), 37.5, 127, 37.51, 127.01)
	if err != nil || seconds != 300 {
		t.Fatal(seconds, err)
	}
}
func TestWalkingRequiresPassengerAndFreshETA(t *testing.T) {
	s := newStore(false)
	s.verifier = fakeVerifier{"d": {UID: "d", Phone: "+821011111111"}, "p": {UID: "p", Phone: "+821022222222"}}
	s.walker = walkerFunc(func(_ context.Context, a, b, c, d float64) (int, error) {
		if a != 37.49 || b != 127.01 || c != 37.5 || d != 127 {
			t.Fatal("wrong coordinates")
		}
		return 180, nil
	})
	_, created := call(t, s, "POST", "/api/v1/pickups", "d", map[string]any{"contactName": "P", "passengerPhone": "+821022222222"})
	base := "/api/v1/pickups/" + created["id"].(string)
	_, _ = call(t, s, "POST", base+"/pickup", "p", map[string]any{"lat": 37.5, "lon": 127.0, "label": "exit"})
	_, _ = call(t, s, "POST", base+"/confirm", "d", map[string]any{"revision": 1})
	code, _ := call(t, s, "POST", base+"/walking-estimate", "d", map[string]any{"lat": 37.49, "lon": 127.01})
	if code != 403 {
		t.Fatal(code)
	}
	code, body := call(t, s, "POST", base+"/walking-estimate", "p", map[string]any{"lat": 37.49, "lon": 127.01})
	if code != 200 || body["departureInSeconds"] != nil {
		t.Fatal(body)
	}
	_, _ = call(t, s, "POST", base+"/location", "d", map[string]any{"lat": 37.5, "lon": 127.0, "etaSeconds": 600})
	code, body = call(t, s, "POST", base+"/walking-estimate", "p", map[string]any{"lat": 37.49, "lon": 127.01})
	if code != 200 || body["departureInSeconds"] != float64(300) {
		t.Fatal(body)
	}
}

func TestWalkingDepartureNotification(t *testing.T) {
	s := newStore(false)
	s.verifier = fakeVerifier{"d": {UID: "d", Phone: "+821011111111"}, "p": {UID: "p", Phone: "+821022222222"}}
	s.walker = walkerFunc(func(context.Context, float64, float64, float64, float64) (int, error) { return 300, nil })
	push := fakePush{sent: make(chan string, 10)}
	s.push = push
	_, _ = call(t, s, "POST", "/api/v1/device", "p", map[string]any{"token": "device-token"})
	_, created := call(t, s, "POST", "/api/v1/pickups", "d", map[string]any{"contactName": "P", "passengerPhone": "+821022222222"})
	<-push.sent
	base := "/api/v1/pickups/" + created["id"].(string)
	_, _ = call(t, s, "POST", base+"/pickup", "p", map[string]any{"lat": 37.5, "lon": 127.0, "label": "exit"})
	_, _ = call(t, s, "POST", base+"/confirm", "d", map[string]any{"revision": 1})
	code, _ := call(t, s, "POST", base+"/walking-estimate", "p", map[string]any{"lat": 37.49, "lon": 127.01})
	if code != 200 {
		t.Fatal(code)
	}
	_, _ = call(t, s, "POST", base+"/location", "d", map[string]any{"lat": 37.51, "lon": 127.0, "etaSeconds": 430})
	select {
	case m := <-push.sent:
		t.Fatalf("too early: %s", m)
	case <-time.After(30 * time.Millisecond):
	}
	_, _ = call(t, s, "POST", base+"/location", "d", map[string]any{"lat": 37.51, "lon": 127.0, "etaSeconds": 420})
	got := []string{}
	for i := 0; i < 1; i++ {
		select {
		case m := <-push.sent:
			got = append(got, m)
		case <-time.After(time.Second):
			t.Fatal("missing notification")
		}
	}
	if !strings.Contains(strings.Join(got, "|"), "출발할 시간") {
		t.Fatal(got)
	}
	_, _ = call(t, s, "POST", base+"/location", "d", map[string]any{"lat": 37.51, "lon": 127.0, "etaSeconds": 400})
	select {
	case m := <-push.sent:
		t.Fatalf("duplicate: %s", m)
	case <-time.After(30 * time.Millisecond):
	}
}
