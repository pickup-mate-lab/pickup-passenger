package main

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"
)

func call(t *testing.T, s *store, method, path, auth string, body any) (int, map[string]any) {
	t.Helper()
	data, _ := json.Marshal(body)
	r := httptest.NewRequest(method, path, bytes.NewReader(data))
	if auth != "" {
		r.Header.Set("Authorization", "Bearer "+auth)
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}
func TestDemoJoinsLatestDriverRequestAndSharingExpires(t *testing.T) {
	s := newStore(true)
	_, created := call(t, s, "POST", "/api/sessions", "", map[string]any{"contactName": "Demo"})
	_, demo := call(t, s, "POST", "/api/demo/request", "", map[string]any{})
	if demo["id"] != created["id"] || demo["passengerToken"] != created["passengerToken"] {
		t.Fatal("demo did not join driver session")
	}
	p := s.sessions[created["id"].(string)]
	p.Sharing = true
	p.PassengerLocation = &point{Lat: 37.5, Lon: 127, UpdatedAt: time.Now().Add(-46 * time.Second)}
	_, view := call(t, s, "GET", "/api/sessions/"+p.ID, created["driverToken"].(string), nil)
	if p.Sharing || view["passengerLocation"] != nil {
		t.Fatal("expired location was retained")
	}
}
func TestPickupLifecycleAndRoleBoundaries(t *testing.T) {
	s := newStore(true)
	code, created := call(t, s, "POST", "/api/sessions", "", map[string]any{"contactName": "테스트"})
	if code != 201 {
		t.Fatal(created)
	}
	id := created["id"].(string)
	driver := created["driverToken"].(string)
	passenger := created["passengerToken"].(string)
	base := "/api/sessions/" + id
	code, _ = call(t, s, "POST", base+"/pickup", driver, map[string]any{"lat": 37.5, "lon": 127.0, "label": "출구"})
	if code != 403 {
		t.Fatal("driver selected pickup", code)
	}
	code, _ = call(t, s, "POST", base+"/location", passenger, map[string]any{"lat": 37.5, "lon": 127.0})
	if code != 409 {
		t.Fatal("sharing without consent", code)
	}
	code, state := call(t, s, "POST", base+"/pickup", passenger, map[string]any{"lat": 37.5, "lon": 127.0, "label": "출구"})
	if code != 200 || state["status"] != "pickup_pending" {
		t.Fatal(state)
	}
	_, _ = call(t, s, "POST", base+"/pickup", passenger, map[string]any{"lat": 37.51, "lon": 127.01, "label": "변경"})
	code, _ = call(t, s, "POST", base+"/confirm", driver, map[string]any{"revision": 1})
	if code != 409 {
		t.Fatal("stale confirmation accepted", code)
	}
	code, _ = call(t, s, "POST", base+"/confirm", driver, map[string]any{"revision": 2})
	if code != 200 {
		t.Fatal("confirmation failed", code)
	}
	_, _ = call(t, s, "POST", base+"/location-consent", passenger, map[string]any{"enabled": true})
	code, _ = call(t, s, "POST", base+"/location", passenger, map[string]any{"lat": 37.5, "lon": 127.0})
	if code != 200 {
		t.Fatal("location failed", code)
	}
	_, _ = call(t, s, "POST", base+"/location-consent", passenger, map[string]any{"enabled": false})
	_, state = call(t, s, "GET", base, driver, nil)
	if state["passengerLocation"] != nil {
		t.Fatal("location retained", state)
	}
	code, _ = call(t, s, "POST", base+"/message", passenger, map[string]any{"text": "기다리고 있어요"})
	if code != 200 {
		t.Fatal("message failed", code)
	}
	_, _ = call(t, s, "POST", base+"/finish", driver, map[string]any{})
	_, state = call(t, s, "GET", base, passenger, nil)
	if state["status"] != "finished" || len(state["messages"].([]any)) != 0 {
		t.Fatal("finish cleanup", state)
	}
}
func TestDemoEndpointMustBeEnabled(t *testing.T) {
	s := newStore(false)
	code, _ := call(t, s, "POST", "/api/demo/request", "", map[string]any{})
	if code != 404 {
		t.Fatal(code)
	}
	s.demo = true
	code, result := call(t, s, "POST", "/api/demo/request", "", map[string]any{})
	if code != 200 || result["passengerToken"] == nil {
		t.Fatal(result)
	}
}
func TestRejectUnauthorizedAndInvalidCoordinates(t *testing.T) {
	s := newStore(true)
	_, created := call(t, s, "POST", "/api/sessions", "", map[string]any{"contactName": "x"})
	base := "/api/sessions/" + created["id"].(string)
	code, _ := call(t, s, "GET", base, "wrong", nil)
	if code != 401 {
		t.Fatal(code)
	}
	code, _ = call(t, s, "POST", base+"/pickup", created["passengerToken"].(string), map[string]any{"lat": 999, "lon": 0, "label": "x"})
	if code != 400 {
		t.Fatal(code)
	}
}

func TestDeclineAndCompletionAreDistinguishable(t *testing.T) {
	s := newStore(true)
	_, a := call(t, s, "POST", "/api/sessions", "", map[string]any{"contactName": "A"})
	base := "/api/sessions/" + a["id"].(string)
	code, declined := call(t, s, "POST", base+"/decline", a["passengerToken"].(string), map[string]any{})
	if code != 200 || declined["endReason"] != "declined" {
		t.Fatalf("decline: %d %#v", code, declined)
	}
	_, view := call(t, s, "GET", base, a["driverToken"].(string), nil)
	if view["endReason"] != "declined" {
		t.Fatalf("driver view: %#v", view)
	}
	_, b := call(t, s, "POST", "/api/sessions", "", map[string]any{"contactName": "B"})
	code, completed := call(t, s, "POST", "/api/sessions/"+b["id"].(string)+"/finish", b["driverToken"].(string), map[string]any{})
	if code != 200 || completed["endReason"] != "completed" {
		t.Fatalf("finish: %d %#v", code, completed)
	}
}
