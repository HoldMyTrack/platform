package mail

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/HoldMyTrack/platform/services/server/internal/metrics"
)

// The failure count exists at zero before any send, so the first failure is an increase.
func TestMailSentStartsAtZero(t *testing.T) {
	if n := testutil.CollectAndCount(metrics.MailSent); n < 2 {
		t.Errorf("%d mail_sent series before any send, want both outcomes", n)
	}
}

func TestZeptoCheckReadsTheTokensAnswer(t *testing.T) {
	for status, wantOK := range map[int]bool{http.StatusBadRequest: true, http.StatusUnauthorized: false, http.StatusOK: false} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(status)
		}))
		s := mustNew(t, Config{ZeptoMailURL: srv.URL, ZeptoMailToken: "t", From: "noreply@holdmytrack.com"}, false, slog.New(slog.DiscardHandler))
		err := s.(checker).Check(context.Background())
		if (err == nil) != wantOK {
			t.Errorf("HTTP %d: Check() = %v", status, err)
		}
		srv.Close()
	}
}

// Unconfigured mail fails the check on a real deployment and passes in dev.
func TestLogSenderCheck(t *testing.T) {
	for logBodies, wantOK := range map[bool]bool{false: false, true: true} {
		s := mustNew(t, Config{}, logBodies, slog.New(slog.DiscardHandler))
		if err := s.(checker).Check(context.Background()); (err == nil) != wantOK {
			t.Errorf("logBodies %v: Check() = %v", logBodies, err)
		}
	}
}

type flakyChecker struct {
	countingSender
	results chan error
}

func (f flakyChecker) Check(ctx context.Context) error {
	select {
	case err := <-f.results:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func TestRunCheckReportsEachResult(t *testing.T) {
	f := flakyChecker{results: make(chan error)}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { RunCheck(ctx, f, time.Millisecond, slog.New(slog.DiscardHandler)); close(done) }()
	gauge := metrics.MailUp.WithLabelValues("none")
	for _, err := range []error{errors.New("refused"), nil, errors.New("refused")} {
		f.results <- err
		want := 1.0
		if err != nil {
			want = 0
		}
		deadline := time.Now().Add(time.Second)
		for testutil.ToFloat64(gauge) != want && time.Now().Before(deadline) {
			time.Sleep(time.Millisecond)
		}
		if got := testutil.ToFloat64(gauge); got != want {
			t.Fatalf("after %v: mail_up %v, want %v", err, got, want)
		}
	}
	cancel()
	<-done
}
