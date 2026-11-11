package main

import (
	"math"
	"time"
)

// Arrival stages only escalate once per pickup revision.
const (
	stageNone = iota
	stageDeparture
	stageApproaching
	stageArrived
)

const (
	etaFreshFor        = 60 * time.Second
	departureBuffer    = 120 // seconds kept spare after walking to the pickup point
	approachingSeconds = 300
	arrivedMeters      = 100
)

var stageNames = [...]string{"none", "departure", "approaching", "arrived"}

// Push bodies intentionally contain no coordinates, phone numbers or messages.
var alertText = map[int]string{
	stageDeparture:   "지금 출발하면 차량 도착에 맞춰 승차 지점에 도착해요.",
	stageApproaching: "차량이 곧 도착해요. 픽업 위치를 확인해 주세요.",
	stageArrived:     "차량이 승차 지점에 도착했어요.",
}

func distanceMeters(lat1, lon1, lat2, lon2 float64) float64 {
	const r = 6371000.0
	rad := math.Pi / 180
	dLat := (lat2 - lat1) * rad
	dLon := (lon2 - lon1) * rad
	a := math.Sin(dLat/2)*math.Sin(dLat/2) + math.Cos(lat1*rad)*math.Cos(lat2*rad)*math.Sin(dLon/2)*math.Sin(dLon/2)
	return 2 * r * math.Asin(math.Min(1, math.Sqrt(a)))
}

func (p *session) driverFresh() bool {
	return p.DriverLocation != nil && time.Since(p.DriverLocation.UpdatedAt) < etaFreshFor
}

// An ETA is meaningful only while the car keeps reporting its position.
func (p *session) freshETA() *int {
	if p.ETA == nil || !p.driverFresh() {
		return nil
	}
	v := *p.ETA
	return &v
}

func (p *session) walking() *int {
	if p.WalkingSeconds == nil || p.WalkingRevision != p.Revision {
		return nil
	}
	v := *p.WalkingSeconds
	return &v
}

func (p *session) departureIn() *int {
	eta, walk := p.freshETA(), p.walking()
	if eta == nil || walk == nil {
		return nil
	}
	v := *eta - *walk - departureBuffer
	if v < 0 {
		v = 0
	}
	return &v
}

func (p *session) stage() int {
	if p.Status != "active" || p.Pickup == nil || !p.driverFresh() {
		return stageNone
	}
	if distanceMeters(p.DriverLocation.Lat, p.DriverLocation.Lon, p.Pickup.Lat, p.Pickup.Lon) <= arrivedMeters {
		return stageArrived
	}
	if eta := p.freshETA(); eta != nil && *eta <= approachingSeconds {
		return stageApproaching
	}
	if d := p.departureIn(); d != nil && *d <= 0 {
		return stageDeparture
	}
	return stageNone
}

// checkAlerts sends the latest newly reached stage to the passenger's devices.
// Earlier stages that were skipped are recorded as sent, never sent late.
func (s *store) checkAlerts(id string) {
	s.mu.Lock()
	p := s.sessions[id]
	if p == nil || s.push == nil {
		s.mu.Unlock()
		return
	}
	if p.AlertRevision != p.Revision {
		p.AlertRevision = p.Revision
		p.AlertStage = stageNone
	}
	next := p.stage()
	registered := false
	for _, d := range s.devices {
		if d.Phone == p.PassengerPhone && time.Since(d.UpdatedAt) < 30*24*time.Hour {
			registered = true
			break
		}
	}
	if next <= p.AlertStage || !registered {
		s.mu.Unlock()
		return
	}
	old := p.AlertStage
	p.AlertStage = next
	if err := s.persistLocked(); err != nil {
		p.AlertStage = old
		s.mu.Unlock()
		return
	}
	phone := p.PassengerPhone
	s.mu.Unlock()
	s.notify(func(d deviceRecord) bool { return d.Phone == phone }, alertText[next])
}
