package main

import (
	"context"
	"testing"
	"time"
)

type alertFixture struct {
	t    *testing.T
	s    *store
	push fakePush
	base string
}

func newAlertFixture(t *testing.T, walkingSeconds int) alertFixture {
	t.Helper()
	s := newStore(false)
	s.verifier = fakeVerifier{"d": {UID: "d", Phone: "+821011111111"}, "p": {UID: "p", Phone: "+821022222222"}}
	s.walker = walkerFunc(func(context.Context, float64, float64, float64, float64) (int, error) { return walkingSeconds, nil })
	push := fakePush{sent: make(chan string, 10)}
	s.push = push
	if code, _ := call(t, s, "POST", "/api/v1/device", "p", map[string]any{"token": "device"}); code != 200 {
		t.Fatal(code)
	}
	_, created := call(t, s, "POST", "/api/v1/pickups", "d", map[string]any{"contactName": "P", "passengerPhone": "+821022222222"})
	<-push.sent // new request push
	f := alertFixture{t: t, s: s, push: push, base: "/api/v1/pickups/" + created["id"].(string)}
	f.post("p", "pickup", map[string]any{"lat": 37.5, "lon": 127.0, "label": "exit"})
	f.post("d", "confirm", map[string]any{"revision": 1})
	return f
}

func (f alertFixture) post(who, action string, body map[string]any) map[string]any {
	f.t.Helper()
	code, out := call(f.t, f.s, "POST", f.base+"/"+action, who, body)
	if code != 200 {
		f.t.Fatalf("%s %s: %d %v", who, action, code, out)
	}
	return out
}

// Roughly 1.1 km north of the pickup point, so the car is not "arrived".
func (f alertFixture) drive(eta int) map[string]any {
	return f.post("d", "location", map[string]any{"lat": 37.51, "lon": 127.0, "etaSeconds": eta})
}

func (f alertFixture) expectPush(want string) {
	f.t.Helper()
	select {
	case got := <-f.push.sent:
		if got != "device|"+want {
			f.t.Fatalf("push = %q, want %q", got, want)
		}
	case <-time.After(time.Second):
		f.t.Fatalf("missing push %q", want)
	}
}

func (f alertFixture) expectNoPush() {
	f.t.Helper()
	select {
	case got := <-f.push.sent:
		f.t.Fatalf("unexpected push %q", got)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestAlertsEscalateOncePerStage(t *testing.T) {
	f := newAlertFixture(t, 180)
	f.post("p", "walking-estimate", map[string]any{"lat": 37.49, "lon": 127.0})
	f.drive(900) // 900-180-120 = 600 s until departure
	f.expectNoPush()
	f.drive(300) // departure due (0) and exactly approaching threshold → approaching only
	f.expectPush(alertText[stageApproaching])
	f.drive(250)
	f.expectNoPush()
	f.post("d", "location", map[string]any{"lat": 37.5, "lon": 127.0, "etaSeconds": 10})
	f.expectPush(alertText[stageArrived])
	f.post("d", "location", map[string]any{"lat": 37.5, "lon": 127.0, "etaSeconds": 0})
	f.expectNoPush()
}

func TestDepartureAlertUsesStoredWalkingTime(t *testing.T) {
	// Departure-only window is ETA in (300, walking+120] = (300, 420].
	f := newAlertFixture(t, 300)
	f.post("p", "walking-estimate", map[string]any{"lat": 37.49, "lon": 127.0})
	view := f.drive(700) // 700-300-120 = 280
	if view["walkingSeconds"] != float64(300) || view["departureInSeconds"] != float64(280) || view["arrivalStage"] != "none" {
		t.Fatal(view)
	}
	f.expectNoPush()
	view = f.drive(500) // 80 s until departure
	if view["departureInSeconds"] != float64(80) {
		t.Fatal(view)
	}
	f.expectNoPush()
	view = f.drive(400) // 20 s late → departure, not yet approaching
	if view["departureInSeconds"] != float64(0) || view["arrivalStage"] != "departure" {
		t.Fatal(view)
	}
	f.expectPush(alertText[stageDeparture])
}

func TestWalkingEstimateCanTriggerDepartureImmediately(t *testing.T) {
	f := newAlertFixture(t, 400)
	f.drive(500) // no walking time yet → no departure stage
	f.expectNoPush()
	out := f.post("p", "walking-estimate", map[string]any{"lat": 37.49, "lon": 127.0})
	if out["departureInSeconds"] != float64(0) {
		t.Fatal(out)
	}
	f.expectPush(alertText[stageDeparture])
}

func TestPickupChangeResetsWalkingAndAlerts(t *testing.T) {
	f := newAlertFixture(t, 180)
	f.post("p", "walking-estimate", map[string]any{"lat": 37.49, "lon": 127.0})
	f.drive(200)
	f.expectPush(alertText[stageApproaching])
	view := f.post("p", "pickup", map[string]any{"lat": 37.52, "lon": 127.0, "label": "new exit"})
	if view["walkingSeconds"] != nil || view["departureInSeconds"] != nil || view["etaSeconds"] != nil {
		t.Fatal(view)
	}
	f.post("d", "confirm", map[string]any{"revision": 2})
	f.drive(200)
	f.expectPush(alertText[stageApproaching])
}

func TestStaleDriverLocationHidesETAAndStage(t *testing.T) {
	f := newAlertFixture(t, 180)
	f.drive(200)
	f.expectPush(alertText[stageApproaching])
	p := f.s.sessions[f.base[len("/api/v1/pickups/"):]]
	p.DriverLocation.UpdatedAt = time.Now().Add(-61 * time.Second)
	_, view := call(t, f.s, "GET", f.base, "p", nil)
	if view["etaSeconds"] != nil || view["arrivalStage"] != "none" || view["departureInSeconds"] != nil {
		t.Fatal(view)
	}
}

func TestDistanceMeters(t *testing.T) {
	// 0.001° latitude ≈ 111 m everywhere.
	if d := distanceMeters(37.5, 127.0, 37.501, 127.0); d < 110 || d > 112 {
		t.Fatal(d)
	}
}
