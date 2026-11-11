package main

import (
	"context"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
)

type deviceRecord struct {
	UID, Phone, Token string
	UpdatedAt         time.Time
}
type pushSender interface {
	Send(context.Context, string, string, string) error
}
type firebasePush struct{ client *messaging.Client }

func newFirebasePush(ctx context.Context, projectID string) (pushSender, error) {
	app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: projectID})
	if err != nil {
		return nil, err
	}
	client, err := app.Messaging(ctx)
	if err != nil {
		return nil, err
	}
	return firebasePush{client: client}, nil
}
func (f firebasePush) Send(ctx context.Context, token, title, body string) error {
	_, err := f.client.Send(ctx, &messaging.Message{Fid: token, Notification: &messaging.Notification{Title: title, Body: body}})
	return err
}

// Messages intentionally contain no phone numbers, coordinates or message text.
func (s *store) notify(match func(deviceRecord) bool, body string) bool {
	s.mu.Lock()
	if s.push == nil {
		s.mu.Unlock()
		return false
	}
	var tokens []string
	for _, device := range s.devices {
		if time.Since(device.UpdatedAt) < 30*24*time.Hour && match(device) {
			tokens = append(tokens, device.Token)
		}
	}
	sender := s.push
	s.mu.Unlock()
	for _, token := range tokens {
		go func(token string) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_ = sender.Send(ctx, token, "픽업메이트", body)
		}(token)
	}
	return len(tokens) > 0
}
