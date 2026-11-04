package mail

import (
	"context"
	"io"
	"log/slog"
	"net"
	"strconv"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/HoldMyTrack/platform/services/server/internal/metrics"
)

// A send the provider can't take counts as failed, which is what the "Email failed to send"
// alert watches (ops/grafana/apply.py); the dev sender, which never sends, counts nothing.
func TestSendsAreCountedByOutcome(t *testing.T) {
	// A port nothing listens on: the dial is refused at once.
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := strconv.Itoa(l.Addr().(*net.TCPAddr).Port)
	l.Close()

	failed := testutil.ToFloat64(metrics.MailSent.WithLabelValues("failed"))
	sent := testutil.ToFloat64(metrics.MailSent.WithLabelValues("sent"))

	s := New("127.0.0.1", port, "u", "p", "noreply@example.test", false, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := s.Send(context.Background(), "a@example.test", "Hi", "Body"); err == nil {
		t.Fatal("a send to a closed port succeeded")
	}
	if got := testutil.ToFloat64(metrics.MailSent.WithLabelValues("failed")) - failed; got != 1 {
		t.Errorf("failed counted %v times, want 1", got)
	}

	dev := New("", "", "", "", "", false, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := dev.Send(context.Background(), "a@example.test", "Hi", "Body"); err != nil {
		t.Fatal(err)
	}
	if got := testutil.ToFloat64(metrics.MailSent.WithLabelValues("sent")) - sent; got != 0 {
		t.Errorf("the dev sender counted %v sends, want none", got)
	}
}
