package imagery

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// UsageURL is MapTiler's Analytics API for the current billing period's requests per service
// (docs.maptiler.com/cloud/admin-api/analytics). Imagery tiles count as requests, under one
// service; the billing period is the subscription's, so nothing here needs its dates.
const UsageURL = "https://service.maptiler.com/v1/analytics/api_usage/timeline?period=current_billing_period&classifier=services&group=request"

type usageResponse struct {
	Datasets []struct {
		Data []struct {
			Value int64 `json:"value"`
		} `json:"data"`
	} `json:"datasets"`
}

// Usage is the current billing period's requests so far, every service's, read from url with the
// account's service token. A day without traffic is absent from the answer, not zero.
func Usage(ctx context.Context, client *http.Client, url, token string) (int64, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Token "+token)
	res, err := client.Do(req)
	if err != nil {
		return 0, fmt.Errorf("imagery usage: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("imagery usage: HTTP %d", res.StatusCode)
	}
	var body usageResponse
	if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&body); err != nil {
		return 0, fmt.Errorf("imagery usage: %w", err)
	}
	var total int64
	for _, d := range body.Datasets {
		for _, p := range d.Data {
			total += p.Value
		}
	}
	return total, nil
}

// Probe fetches the world tile (0/0/0) of the XYZ template tiles as the site does: the
// deployment's key is restricted to its own site, so a request without referer is refused
// whatever the plan's state. Any answer but 200 is a failure.
func Probe(ctx context.Context, client *http.Client, tiles, referer string) error {
	url := strings.NewReplacer("{z}", "0", "{x}", "0", "{y}", "0").Replace(tiles)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Referer", referer)
	res, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("imagery probe: %w", err)
	}
	defer res.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(res.Body, 1<<20))
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("imagery probe: HTTP %d", res.StatusCode)
	}
	return nil
}
