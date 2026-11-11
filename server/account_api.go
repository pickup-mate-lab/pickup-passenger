package main

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/auth"
)

// A verified Firebase identity, never taken from a request body.
type identity struct{ UID, Phone string }
type identityVerifier interface {
	Verify(context.Context, string) (identity, error)
}
type firebaseVerifier struct{ client *auth.Client }

func newFirebaseVerifier(ctx context.Context, projectID string) (identityVerifier, error) {
	if projectID == "" {
		return nil, errors.New("Firebase project ID is required")
	}
	app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: projectID})
	if err != nil {
		return nil, err
	}
	client, err := app.Auth(ctx)
	if err != nil {
		return nil, err
	}
	return firebaseVerifier{client: client}, nil
}
func (v firebaseVerifier) Verify(ctx context.Context, raw string) (identity, error) {
	t, err := v.client.VerifyIDToken(ctx, raw)
	if err != nil {
		return identity{}, err
	}
	phone, _ := t.Claims["phone_number"].(string)
	if t.UID == "" || !e164.MatchString(phone) {
		return identity{}, errors.New("verified phone number required")
	}
	return identity{UID: t.UID, Phone: phone}, nil
}

var e164 = regexp.MustCompile(`^\+[1-9][0-9]{7,14}$`)

func (s *store) serveAccount(w http.ResponseWriter, r *http.Request) {
	if s.verifier == nil {
		fail(w, 503, "Phone authentication is not configured")
		return
	}
	authHeader := r.Header.Get("Authorization")
	if !strings.HasPrefix(authHeader, "Bearer ") {
		fail(w, 401, "Authentication required")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	who, err := s.verifier.Verify(ctx, strings.TrimPrefix(authHeader, "Bearer "))
	if err != nil || who.UID == "" || !e164.MatchString(who.Phone) {
		fail(w, 401, "Verified phone authentication required")
		return
	}
	path := strings.TrimSuffix(r.URL.Path, "/")
	if path == "/api/v1/device" && (r.Method == http.MethodPost || r.Method == http.MethodDelete) {
		var deviceToken string
		if r.Method == http.MethodPost {
			body, err := parse(r)
			if err != nil {
				fail(w, 400, err.Error())
				return
			}
			var ok bool
			deviceToken, ok = text(body["token"], 4096)
			if !ok {
				fail(w, 400, "A device token is required")
				return
			}
		}
		s.mu.Lock()
		previous, existed := s.devices[who.UID]
		if r.Method == http.MethodDelete {
			delete(s.devices, who.UID)
		} else {
			s.devices[who.UID] = deviceRecord{UID: who.UID, Phone: who.Phone, Token: deviceToken, UpdatedAt: time.Now()}
		}
		if err := s.persistLocked(); err != nil {
			if existed {
				s.devices[who.UID] = previous
			} else {
				delete(s.devices, who.UID)
			}
			s.mu.Unlock()
			fail(w, 500, "Storage failure")
			return
		}
		s.mu.Unlock()
		respond(w, 200, map[string]bool{"ok": true})
		return
	}
	if path == "/api/v1/me" && r.Method == http.MethodGet {
		respond(w, 200, map[string]string{"uid": who.UID, "phone": who.Phone})
		return
	}
	if path == "/api/v1/inbox" && r.Method == http.MethodGet {
		s.mu.Lock()
		items := make([]map[string]any, 0)
		for _, p := range s.sessions {
			p.expire()
			if p.PassengerPhone == who.Phone && p.DriverUID != "" && p.Status != "finished" && p.Status != "expired" {
				items = append(items, p.view("passenger"))
			}
		}
		sort.Slice(items, func(i, j int) bool { return items[i]["expiresAt"].(string) > items[j]["expiresAt"].(string) })
		s.mu.Unlock()
		respond(w, 200, map[string]any{"requests": items})
		return
	}
	if path == "/api/v1/pickups" && r.Method == http.MethodPost {
		body, err := parse(r)
		if err != nil {
			fail(w, 400, err.Error())
			return
		}
		name, ok := text(body["contactName"], 80)
		phone, _ := body["passengerPhone"].(string)
		when, _ := body["pickupTime"].(string)
		if !ok || !e164.MatchString(phone) || phone == who.Phone || len(when) > 120 {
			fail(w, 400, "A valid contact name and a different E.164 passenger phone are required")
			return
		}
		s.mu.Lock()
		previousLatest := s.latest
		p := s.create(name, strings.TrimSpace(when))
		p.DriverUID = who.UID
		p.PassengerPhone = phone
		s.latest = previousLatest // Never expose authenticated requests through the demo endpoint.
		if err := s.persistLocked(); err != nil {
			delete(s.sessions, p.ID)
			s.mu.Unlock()
			fail(w, 500, "Storage failure")
			return
		}
		view := p.view("driver")
		s.mu.Unlock()
		respond(w, 201, view)
		s.notify(func(d deviceRecord) bool { return d.Phone == phone }, "새 픽업 요청이 도착했어요. 앱에서 확인해 주세요.")
		return
	}
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) < 4 || len(parts) > 5 || parts[0] != "api" || parts[1] != "v1" || parts[2] != "pickups" {
		fail(w, 404, "Not found")
		return
	}
	s.mu.Lock()
	p := s.sessions[parts[3]]
	if p == nil || p.DriverUID == "" {
		s.mu.Unlock()
		fail(w, 404, "Not found")
		return
	}
	var sessionToken string
	isDriver := false
	if p.DriverUID == who.UID {
		sessionToken = p.DriverToken
		isDriver = true
	} else if p.PassengerPhone == who.Phone {
		sessionToken = p.PassengerToken
	} else {
		s.mu.Unlock()
		fail(w, 404, "Not found")
		return
	}
	s.mu.Unlock()
	if len(parts) == 5 && parts[4] == "walking-estimate" && r.Method == http.MethodPost {
		if isDriver {
			fail(w, 403, "Only the passenger can request a walking estimate")
			return
		}
		body, err := parse(r)
		if err != nil {
			fail(w, 400, err.Error())
			return
		}
		lat, lon, ok := coord(body)
		if !ok {
			fail(w, 400, "Invalid coordinates")
			return
		}
		s.mu.Lock()
		p = s.sessions[parts[3]]
		if p == nil || p.Status != "active" || p.Pickup == nil {
			s.mu.Unlock()
			fail(w, 409, "An active pickup is required")
			return
		}
		if s.walker == nil {
			s.mu.Unlock()
			fail(w, 503, "Walking route service is not configured")
			return
		}
		destination := *p.Pickup
		revision := p.Revision
		walker := s.walker
		s.mu.Unlock()
		seconds, err := walker.Estimate(r.Context(), lat, lon, destination.Lat, destination.Lon)
		if err != nil {
			fail(w, 502, "Walking route is unavailable")
			return
		}
		s.mu.Lock()
		p = s.sessions[parts[3]]
		if p == nil || p.Status != "active" || p.Revision != revision {
			s.mu.Unlock()
			fail(w, 409, "Pickup location changed; try again")
			return
		}
		previousSeconds, previousRevision := p.WalkingSeconds, p.WalkingRevision
		p.WalkingSeconds = &seconds
		p.WalkingRevision = revision
		if err := s.persistLocked(); err != nil {
			p.WalkingSeconds, p.WalkingRevision = previousSeconds, previousRevision
			s.mu.Unlock()
			fail(w, 500, "Storage failure")
			return
		}
		depart := p.departureIn()
		s.mu.Unlock()
		respond(w, 200, map[string]any{"walkingSeconds": seconds, "departureInSeconds": depart, "pickupRevision": revision, "provider": "TMAP"})
		s.checkAlerts(parts[3])
		return
	}
	// The legacy engine enforces driver/passenger permissions and never receives
	// a caller-controlled session token from these authenticated routes.
	forward := r.Clone(r.Context())
	u := *r.URL
	u.Path = "/api/sessions/" + url.PathEscape(parts[3])
	if len(parts) == 5 {
		u.Path += "/" + url.PathEscape(parts[4])
	}
	forward.URL = &u
	forward.Header = r.Header.Clone()
	forward.Header.Set("Authorization", "Bearer "+sessionToken)
	status := &responseStatus{ResponseWriter: w, code: 200}
	s.serveLegacy(status, forward, true)
	if status.code < 200 || status.code >= 300 || r.Method != http.MethodPost || len(parts) != 5 {
		return
	}
	if parts[4] == "message" {
		if isDriver {
			s.notify(func(d deviceRecord) bool { return d.Phone == p.PassengerPhone }, "새 메시지가 도착했어요. 앱에서 확인해 주세요.")
		} else {
			s.notify(func(d deviceRecord) bool { return d.UID == p.DriverUID }, "새 메시지가 도착했어요. 앱에서 확인해 주세요.")
		}
	}
	if parts[4] == "location" && isDriver {
		s.checkAlerts(parts[3])
	}
}

type responseStatus struct {
	http.ResponseWriter
	code int
}

func (w *responseStatus) WriteHeader(code int) { w.code = code; w.ResponseWriter.WriteHeader(code) }
