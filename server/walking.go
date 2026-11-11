package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

type walkingEstimator interface {
	Estimate(context.Context, float64, float64, float64, float64) (int, error)
}
type tmapWalker struct {
	key    string
	client *http.Client
}

func newTMAPWalker(key string) walkingEstimator {
	return tmapWalker{key: key, client: &http.Client{Timeout: 8 * time.Second}}
}
func (t tmapWalker) Estimate(ctx context.Context, startLat, startLon, endLat, endLon float64) (int, error) {
	payload := map[string]any{"startX": startLon, "startY": startLat, "endX": endLon, "endY": endLat, "startName": "start", "endName": "pickup", "reqCoordType": "WGS84GEO", "resCoordType": "WGS84GEO", "searchOption": "0"}
	data, err := json.Marshal(payload)
	if err != nil {
		return 0, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://apis.openapi.sk.com/tmap/routes/pedestrian?version=1", bytes.NewReader(data))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("appKey", t.key)
	resp, err := t.client.Do(req)
	if err != nil {
		return 0, errors.New("walking route unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return 0, fmt.Errorf("walking route unavailable (HTTP %d)", resp.StatusCode)
	}
	var dataOut struct {
		Features []struct {
			Properties struct {
				PointType string `json:"pointType"`
				TotalTime *int   `json:"totalTime"`
			} `json:"properties"`
		} `json:"features"`
	}
	if err = json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&dataOut); err != nil {
		return 0, errors.New("invalid walking route response")
	}
	for _, f := range dataOut.Features {
		if f.Properties.PointType == "SP" && f.Properties.TotalTime != nil && *f.Properties.TotalTime >= 0 && *f.Properties.TotalTime <= 86400 {
			return *f.Properties.TotalTime, nil
		}
	}
	return 0, errors.New("walking duration missing")
}
