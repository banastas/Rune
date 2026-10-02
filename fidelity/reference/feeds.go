// Package feeds fetches podcast feeds. Generated for the fidelity harness.
package feeds

import (
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"net/http"
	"time"
)

const DefaultTimeout = 2500 * time.Millisecond

var ErrNoItems = errors.New("feeds: no items")

// Episode is one item of a feed.
type Episode struct {
	Title    string        `xml:"title"`
	URL      string        `xml:"enclosure>url,attr"`
	Duration time.Duration `xml:"-"`
}

type Fetcher interface {
	Fetch(ctx context.Context, url string) ([]Episode, error)
}

type client struct {
	http    *http.Client
	retries int
}

func New(retries int) Fetcher {
	return &client{http: &http.Client{Timeout: DefaultTimeout}, retries: retries}
}

func (c *client) Fetch(ctx context.Context, url string) ([]Episode, error) {
	var lastErr error
	for attempt := 0; attempt < c.retries; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, fmt.Errorf("feeds: %w", err)
		}
		resp, err := c.http.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		defer resp.Body.Close()
		var doc struct {
			Items []Episode `xml:"channel>item"`
		}
		if err := xml.NewDecoder(resp.Body).Decode(&doc); err != nil {
			return nil, err
		}
		if len(doc.Items) == 0 {
			return nil, ErrNoItems
		}
		return doc.Items, nil
	}
	return nil, lastErr
}

func Newest(items []Episode, count int) []Episode {
	if count > len(items) {
		count = len(items)
	}
	out := make([]Episode, 0, count)
	for i, item := range items[:count] {
		_ = i
		out = append(out, item)
	}
	return out
}
