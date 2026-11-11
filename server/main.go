// Package main implements a local-only prototype of the pickup API.
package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	bolt "go.etcd.io/bbolt"
)

type point struct {
	Lat       float64   `json:"lat"`
	Lon       float64   `json:"lon"`
	UpdatedAt time.Time `json:"updatedAt"`
	Label     string    `json:"label,omitempty"`
	Revision  int       `json:"revision,omitempty"`
	Confirmed bool      `json:"confirmed"`
}
type message struct {
	ID        string    `json:"id"`
	Sender    string    `json:"sender"`
	Text      string    `json:"text"`
	CreatedAt time.Time `json:"createdAt"`
}
type session struct {
	ID, ContactName, PickupTime, DriverToken, PassengerToken, Status string
	DriverUID, PassengerPhone                                        string
	Expires                                                          time.Time
	Pickup, DriverLocation, PassengerLocation                        *point
	Sharing                                                          bool
	ETA                                                              *int
	Revision                                                         int
	Messages                                                         []message
	WalkingSeconds                                                   *int
	WalkingRevision, AlertRevision, AlertStage                       int
}
type store struct {
	mu       sync.Mutex
	sessions map[string]*session
	latest   string
	demo     bool
	verifier identityVerifier
	db       *bolt.DB
	devices  map[string]deviceRecord
	push     pushSender
	walker   walkingEstimator
}

func token(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
func newStore(demo bool) *store {
	return &store{sessions: make(map[string]*session), devices: make(map[string]deviceRecord), demo: demo}
}
func (s *store) create(name, when string) *session {
	p := &session{ID: token(9), ContactName: name, PickupTime: when, DriverToken: token(32), PassengerToken: token(32), Status: "invited", Expires: time.Now().Add(2 * time.Hour), Messages: []message{}}
	s.sessions[p.ID] = p
	s.latest = p.ID
	return p
}
func same(a, b string) bool {
	return a != "" && b != "" && subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}
func (p *session) role(t string) string {
	if same(t, p.DriverToken) {
		return "driver"
	}
	if same(t, p.PassengerToken) {
		return "passenger"
	}
	return ""
}
func (p *session) expire() {
	if p.Sharing && p.PassengerLocation != nil && time.Since(p.PassengerLocation.UpdatedAt) > 45*time.Second {
		p.PassengerLocation = nil
		p.Sharing = false
	}
	if p.Status != "finished" && p.Status != "expired" && time.Now().After(p.Expires) {
		p.Status = "expired"
		p.Pickup = nil
		p.DriverLocation = nil
		p.PassengerLocation = nil
		p.Sharing = false
		p.ETA = nil
		p.Messages = []message{}
	}
}
func (p *session) view(role string) map[string]any {
	visible := p.Status == "active" || p.Status == "pickup_pending"
	var driver, passenger *point
	var eta, walking, departure *int
	stage := stageNone
	messages := []message{}
	if visible {
		if p.DriverLocation != nil {
			copy := *p.DriverLocation
			driver = &copy
		}
		eta = p.freshETA()
		walking = p.walking()
		departure = p.departureIn()
		stage = p.stage()
		messages = append(messages, p.Messages...)
		if role == "driver" {
			if p.PassengerLocation != nil {
				copy := *p.PassengerLocation
				passenger = &copy
			}
		}
	}
	var pickup *point
	if p.Pickup != nil {
		copy := *p.Pickup
		pickup = &copy
	}
	return map[string]any{"id": p.ID, "contactName": p.ContactName, "pickupTime": p.PickupTime, "status": p.Status, "pickup": pickup, "driverLocation": driver, "passengerLocation": passenger, "passengerLocationSharing": visible && p.Sharing, "etaSeconds": eta, "walkingSeconds": walking, "departureInSeconds": departure, "arrivalStage": stageNames[stage], "messages": messages, "expiresAt": p.Expires.UTC().Format(time.RFC3339)}
}
func respond(w http.ResponseWriter, code int, data any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(data)
}
func fail(w http.ResponseWriter, code int, msg string) {
	respond(w, code, map[string]string{"error": msg})
}
func parse(r *http.Request) (map[string]any, error) {
	defer r.Body.Close()
	d := json.NewDecoder(io.LimitReader(r.Body, 8193))
	var v map[string]any
	if err := d.Decode(&v); err != nil || v == nil {
		return nil, errors.New("Invalid JSON body")
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		return nil, errors.New("Invalid JSON body")
	}
	return v, nil
}
func text(v any, max int) (string, bool) {
	s, ok := v.(string)
	s = strings.TrimSpace(s)
	return s, ok && s != "" && utf8.RuneCountInString(s) <= max
}
func coord(m map[string]any) (float64, float64, bool) {
	a, ok := m["lat"].(float64)
	b, ok2 := m["lon"].(float64)
	return a, b, ok && ok2 && !math.IsNaN(a) && !math.IsNaN(b) && a >= -90 && a <= 90 && b >= -180 && b <= 180
}
func (s *store) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/api/v1/") {
		s.serveAccount(w, r)
		return
	}
	s.serveLegacy(w, r, false)
}

func (s *store) serveLegacy(w http.ResponseWriter, r *http.Request, internal bool) {
	if r.URL.Path == "/health" && r.Method == "GET" {
		respond(w, 200, map[string]string{"status": "ok"})
		return
	}
	if !s.demo && !internal {
		fail(w, 404, "Not found")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if r.URL.Path == "/api/demo/request" && r.Method == "POST" {
		if !s.demo {
			fail(w, 404, "Not found")
			return
		}
		p := s.sessions[s.latest]
		if p != nil {
			p.expire()
		}
		if p == nil || p.Status != "invited" {
			p = s.create("데모 탑승자", "")
		}
		respond(w, 200, map[string]any{"id": p.ID, "passengerToken": p.PassengerToken, "demo": true})
		return
	}
	if r.URL.Path == "/api/sessions" && r.Method == "POST" {
		body, err := parse(r)
		if err != nil {
			fail(w, 400, err.Error())
			return
		}
		name, ok := text(body["contactName"], 80)
		if !ok {
			fail(w, 400, "contactName is required")
			return
		}
		when, _ := body["pickupTime"].(string)
		if utf8.RuneCountInString(when) > 80 {
			fail(w, 400, "pickupTime is too long")
			return
		}
		p := s.create(name, strings.TrimSpace(when))
		respond(w, 201, map[string]any{"id": p.ID, "driverToken": p.DriverToken, "passengerToken": p.PassengerToken, "expiresAt": p.Expires.UTC().Format(time.RFC3339)})
		return
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 3 || len(parts) > 4 || parts[0] != "api" || parts[1] != "sessions" {
		fail(w, 404, "Not found")
		return
	}
	p := s.sessions[parts[2]]
	if p == nil {
		fail(w, 401, "Session or token was not found")
		return
	}
	if p.DriverUID != "" && !internal {
		fail(w, 404, "Not found")
		return
	}
	p.expire()
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		fail(w, 401, "Session or token was not found")
		return
	}
	role := p.role(strings.TrimPrefix(auth, "Bearer "))
	if role == "" {
		fail(w, 401, "Session or token was not found")
		return
	}
	if len(parts) == 3 && r.Method == "GET" {
		respond(w, 200, p.view(role))
		return
	}
	if len(parts) != 4 || r.Method != "POST" {
		fail(w, 404, "Not found")
		return
	}
	if p.Status == "expired" || p.Status == "finished" {
		fail(w, 409, "This pickup session has ended")
		return
	}
	body, err := parse(r)
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	var previous []byte
	if p.DriverUID != "" && s.db != nil {
		previous, err = json.Marshal(p)
		if err != nil {
			fail(w, 500, "Storage failure")
			return
		}
	}
	switch parts[3] {
	case "pickup":
		if role != "passenger" {
			fail(w, 403, "Only the passenger can set the pickup point")
			return
		}
		lat, lon, ok := coord(body)
		label, ok2 := text(body["label"], 120)
		if !ok || !ok2 {
			fail(w, 400, "Invalid pickup point")
			return
		}
		p.Revision++
		p.Pickup = &point{Lat: lat, Lon: lon, Label: label, Revision: p.Revision, UpdatedAt: time.Now().UTC()}
		p.Status = "pickup_pending"
		p.ETA = nil
		p.WalkingSeconds = nil
	case "confirm":
		if role != "driver" {
			fail(w, 403, "Only the driver can confirm")
			return
		}
		rev, ok := body["revision"].(float64)
		if !ok || p.Pickup == nil || rev != float64(p.Pickup.Revision) {
			fail(w, 409, "The pickup point changed")
			return
		}
		p.Pickup.Confirmed = true
		p.Status = "active"
	case "location-consent":
		if role != "passenger" {
			fail(w, 403, "Only the passenger can change sharing")
			return
		}
		enabled, ok := body["enabled"].(bool)
		if !ok {
			fail(w, 400, "enabled must be boolean")
			return
		}
		if enabled && p.Pickup == nil {
			fail(w, 409, "Choose a pickup point first")
			return
		}
		p.Sharing = enabled
		if !enabled {
			p.PassengerLocation = nil
		}
	case "location":
		if role == "passenger" && (!p.Sharing || p.Pickup == nil) {
			fail(w, 409, "Location sharing is off")
			return
		}
		lat, lon, ok := coord(body)
		if !ok {
			fail(w, 400, "Invalid coordinates")
			return
		}
		pos := &point{Lat: lat, Lon: lon, UpdatedAt: time.Now().UTC()}
		if role == "driver" {
			if v, exists := body["etaSeconds"]; exists && v != nil {
				n, ok := v.(float64)
				if !ok || n < 0 || n > 86400 || math.Trunc(n) != n {
					fail(w, 400, "Invalid etaSeconds")
					return
				}
				i := int(n)
				p.ETA = &i
			} else if exists {
				p.ETA = nil
			}
			p.DriverLocation = pos
		} else {
			p.PassengerLocation = pos
		}
	case "message":
		if p.Status != "active" && p.Status != "pickup_pending" {
			fail(w, 409, "Accept the pickup first")
			return
		}
		t, ok := text(body["text"], 160)
		if !ok {
			fail(w, 400, "Message is required")
			return
		}
		p.Messages = append(p.Messages, message{ID: token(9), Sender: role, Text: t, CreatedAt: time.Now().UTC()})
		if len(p.Messages) > 50 {
			p.Messages = p.Messages[len(p.Messages)-50:]
		}
	case "decline":
		if role != "passenger" || p.Status != "invited" {
			fail(w, 403, "Only an invited passenger can decline")
			return
		}
		p.Status = "finished"
		p.Pickup = nil
		p.DriverLocation = nil
		p.PassengerLocation = nil
		p.Sharing = false
		p.ETA = nil
		p.Messages = []message{}
	case "finish":
		if role != "driver" {
			fail(w, 403, "Only the driver can finish")
			return
		}
		p.Status = "finished"
		p.Pickup = nil
		p.DriverLocation = nil
		p.PassengerLocation = nil
		p.Sharing = false
		p.ETA = nil
		p.Messages = []message{}
	default:
		fail(w, 404, "Not found")
		return
	}
	if p.DriverUID != "" {
		if err := s.persistLocked(); err != nil {
			if previous != nil {
				_ = json.Unmarshal(previous, p)
			}
			fail(w, 500, "Storage failure")
			return
		}
	}
	respond(w, 200, p.view(role))
}
func main() {
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8787"
	}
	demo := os.Getenv("PICKUP_DEMO") == "1"
	emulator := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")
	if emulator != "" && (!demo || emulator != "127.0.0.1:9099") {
		log.Fatal("Firebase Auth emulator is restricted to the local demo environment")
	}
	if !strings.HasPrefix(addr, "127.0.0.1:") {
		log.Fatal("this development server only supports a loopback bind")
	}
	store := newStore(demo)
	if key := os.Getenv("TMAP_APP_KEY"); key != "" {
		store.walker = newTMAPWalker(key)
	}
	if projectID := os.Getenv("FIREBASE_PROJECT_ID"); projectID != "" {
		verifier, err := newFirebaseVerifier(context.Background(), projectID)
		if err != nil {
			log.Fatalf("Firebase initialization failed: %v", err)
		}
		store.verifier = verifier
		if emulator == "" {
			push, err := newFirebasePush(context.Background(), projectID)
			if err != nil {
				log.Fatalf("Firebase messaging initialization failed: %v", err)
			}
			store.push = push
		}
		storagePath := os.Getenv("PICKUP_DATA_FILE")
		if storagePath == "" {
			storagePath = ".data/pickup.db"
		}
		if err := store.openStorage(storagePath); err != nil {
			log.Fatalf("Storage initialization failed: %v", err)
		}
		defer store.db.Close()
	}
	server := &http.Server{Addr: addr, Handler: store, ReadHeaderTimeout: 5 * time.Second}
	fmt.Printf("Local prototype listening on %s (demo=%t)\n", addr, demo)
	log.Fatal(server.ListenAndServe())
}
