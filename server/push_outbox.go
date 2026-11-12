package main

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"firebase.google.com/go/v4/messaging"
	bolt "go.etcd.io/bbolt"
)

var outboxBucket = []byte("push-outbox-v1")

const arrivalPush = "차량이 곧 도착해요. 픽업 위치를 확인해 주세요."
const departurePush = "승차 지점으로 출발할 시간이에요. 앱에서 확인해 주세요."

// An outbox item contains no phone number, coordinates, authentication token,
// or message text. The body is one of the app's fixed generic notifications.
type outboxItem struct {
	ID                string    `json:"id"`
	UID               string    `json:"uid"`
	PickupID          string    `json:"pickupId"`
	Revision          int       `json:"revision"`
	WalkingGeneration int       `json:"walkingGeneration"`
	Body              string    `json:"body"`
	Expires           time.Time `json:"expires"`
	Next              time.Time `json:"next"`
	Attempts          int       `json:"attempts"`
}

func (s *store) makePushJobsLocked(match func(deviceRecord) bool, body, pickupID string, revision int) []outboxItem {
	now := time.Now()
	jobs := []outboxItem{}
	if s.push == nil {
		return jobs
	}
	for _, d := range s.devices {
		if now.Sub(d.UpdatedAt) < 30*24*time.Hour && match(d) {
			job := outboxItem{ID: token(18), UID: d.UID, PickupID: pickupID, Revision: revision, Body: body, Next: now, Expires: now.Add(15 * time.Minute)}
			if body == departurePush && s.sessions[pickupID] != nil {
				job.WalkingGeneration = s.sessions[pickupID].WalkingGeneration
			}
			jobs = append(jobs, job)
		}
	}
	return jobs
}

func (s *store) enqueuePush(match func(deviceRecord) bool, body, pickupID string, revision int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil || s.push == nil {
		return false
	}
	jobs := s.makePushJobsLocked(match, body, pickupID, revision)
	if len(jobs) == 0 {
		return false
	}
	err := s.db.Update(func(tx *bolt.Tx) error {
		b, err := tx.CreateBucketIfNotExists(outboxBucket)
		if err != nil {
			return err
		}
		for _, job := range jobs {
			data, err := json.Marshal(job)
			if err != nil {
				return err
			}
			if err := b.Put([]byte(job.ID), data); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		log.Print("unable to enqueue push notification")
		return false
	}
	return true
}

func (s *store) runPushWorker(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		s.processPushOutbox(ctx, time.Now())
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// One worker owns dispatch. An unacknowledged item is retried after restart;
// FCM delivery is at-least-once rather than exactly-once.
func (s *store) processPushOutbox(ctx context.Context, now time.Time) {
	if s.db == nil {
		return
	}
	jobs := []outboxItem{}
	err := s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(outboxBucket)
		if b == nil {
			return nil
		}
		return b.ForEach(func(_, raw []byte) error {
			var job outboxItem
			if err := json.Unmarshal(raw, &job); err != nil {
				return err
			}
			if !job.Next.After(now) || !job.Expires.After(now) {
				jobs = append(jobs, job)
			}
			return nil
		})
	})
	if err != nil {
		log.Print("unable to read push outbox")
		return
	}
	for _, job := range jobs {
		if ctx.Err() != nil {
			return
		}
		s.mu.Lock()
		device, valid := s.devices[job.UID]
		sender := s.push
		pickup := s.sessions[job.PickupID]
		valid = valid && pickup != nil && pickup.Status != "finished" && pickup.Status != "expired" && time.Now().Before(pickup.Expires) && (job.Revision == 0 || pickup.Revision == job.Revision)
		if valid && job.Body == departurePush && job.WalkingGeneration != pickup.WalkingGeneration {
			valid = false
		}
		waitForFreshETA := false
		if valid && job.Revision > 0 {
			waitForFreshETA = pickup.ETA == nil || pickup.DriverLocation == nil || time.Since(pickup.DriverLocation.UpdatedAt) > time.Minute
			if !waitForFreshETA && job.Body == arrivalPush {
				waitForFreshETA = *pickup.ETA > 300
			}
			if !waitForFreshETA && job.Body == departurePush {
				waitForFreshETA = pickup.WalkingSeconds == nil || pickup.WalkingRevision != job.Revision || *pickup.ETA > *pickup.WalkingSeconds+120
			}
		}
		s.mu.Unlock()
		// After restart or a long outage, wait for fresh data instead of sending a stale ETA alert.
		if valid && waitForFreshETA && job.Expires.After(now) {
			continue
		}
		valid = valid && time.Since(device.UpdatedAt) < 30*24*time.Hour && sender != nil && job.Expires.After(now)
		var sendErr error
		if valid {
			sendCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
			sendErr = sender.Send(sendCtx, device.Token, "픽업메이트", job.Body)
			cancel()
		}
		// Permanent FCM errors are not retried. Transient errors are retried
		// with bounded exponential backoff and a 15 minute relevance limit.
		permanent := sendErr != nil && (messaging.IsUnregistered(sendErr) || messaging.IsInvalidArgument(sendErr) || messaging.IsSenderIDMismatch(sendErr))
		err := s.db.Update(func(tx *bolt.Tx) error {
			b := tx.Bucket(outboxBucket)
			if b == nil {
				return nil
			}
			if !valid || sendErr == nil || permanent {
				return b.Delete([]byte(job.ID))
			}
			job.Attempts++
			seconds := 60 << min(job.Attempts-1, 3)
			job.Next = time.Now().Add(time.Duration(seconds) * time.Second)
			data, err := json.Marshal(job)
			if err != nil {
				return err
			}
			return b.Put([]byte(job.ID), data)
		})
		if err != nil {
			log.Print("unable to update push outbox")
		}
	}
}
