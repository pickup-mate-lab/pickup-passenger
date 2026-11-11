package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	bolt "go.etcd.io/bbolt"
)

var sessionBucket = []byte("account-pickups")
var deviceBucket = []byte("notification-devices")

// openStorage is for local development. Deployments still need managed backups,
// access controls and storage encryption before real users are onboarded.
func (s *store) openStorage(path string) error {
	if path == "" {
		return errors.New("storage path required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	db, err := bolt.Open(path, 0600, &bolt.Options{Timeout: 3 * time.Second})
	if err != nil {
		return err
	}
	err = db.Update(func(tx *bolt.Tx) error {
		bucket, err := tx.CreateBucketIfNotExists(sessionBucket)
		if err != nil {
			return err
		}
		if err := bucket.ForEach(func(_, value []byte) error {
			var p session
			if err := json.Unmarshal(value, &p); err != nil {
				return err
			}
			if p.ID == "" || p.DriverUID == "" || !e164.MatchString(p.PassengerPhone) {
				return errors.New("invalid stored pickup")
			}
			p.expire()
			// Never silently resume location sharing following a process restart.
			p.DriverLocation = nil
			p.PassengerLocation = nil
			p.Sharing = false
			p.ETA = nil
			s.sessions[p.ID] = &p
			return nil
		}); err != nil {
			return err
		}
		devices, err := tx.CreateBucketIfNotExists(deviceBucket)
		if err != nil {
			return err
		}
		return devices.ForEach(func(_, value []byte) error {
			var d deviceRecord
			if err := json.Unmarshal(value, &d); err != nil {
				return err
			}
			if d.UID == "" || !e164.MatchString(d.Phone) || d.Token == "" {
				return errors.New("invalid stored device")
			}
			if time.Since(d.UpdatedAt) < 30*24*time.Hour {
				s.devices[d.UID] = d
			}
			return nil
		})
	})
	if err != nil {
		_ = db.Close()
		return err
	}
	s.db = db
	if err = s.persistLocked(); err != nil {
		_ = db.Close()
		s.db = nil
		return err
	}
	return nil
}

// Caller holds s.mu. Replace only authenticated sessions; demo sessions are ephemeral.
func (s *store) persistLocked() error {
	if s.db == nil {
		return nil
	}
	return s.db.Update(func(tx *bolt.Tx) error {
		if err := tx.DeleteBucket(sessionBucket); err != nil && err != bolt.ErrBucketNotFound {
			return err
		}
		bucket, err := tx.CreateBucket(sessionBucket)
		if err != nil {
			return err
		}
		for id, p := range s.sessions {
			if p.DriverUID == "" {
				continue
			}
			if p.Status == "finished" || p.Status == "expired" {
				continue
			}
			data, err := json.Marshal(p)
			if err != nil {
				return err
			}
			if err = bucket.Put([]byte(id), data); err != nil {
				return err
			}
		}
		if err := tx.DeleteBucket(deviceBucket); err != nil && err != bolt.ErrBucketNotFound {
			return err
		}
		devices, err := tx.CreateBucket(deviceBucket)
		if err != nil {
			return err
		}
		for id, d := range s.devices {
			if time.Since(d.UpdatedAt) >= 30*24*time.Hour {
				continue
			}
			data, err := json.Marshal(d)
			if err != nil {
				return err
			}
			if err = devices.Put([]byte(id), data); err != nil {
				return err
			}
		}
		return nil
	})
}
