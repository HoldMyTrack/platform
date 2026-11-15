package mail

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/metrics"
)

// checker is a sender that can tell, without sending, whether a message would get through:
// the provider is reachable and takes the credentials.
type checker interface {
	Check(ctx context.Context) error
}

var errNotConfigured = errors.New("mail: neither ZEPTOMAIL_TOKEN nor SMTP_HOST set")

func (s countingSender) Check(ctx context.Context) error {
	if c, ok := s.next.(checker); ok {
		return c.Check(ctx)
	}
	return nil
}

func (s countingSender) transport() string {
	if _, ok := s.next.(*zeptoSender); ok {
		return "zeptomail"
	}
	return "smtp"
}

// Check fails on a real deployment, where a message would be dropped, and passes in dev,
// where logging it is the point.
func (s *logSender) Check(context.Context) error {
	if s.logBodies {
		return nil
	}
	return errNotConfigured
}

// RunCheck checks s every interval until ctx ends, and reports the result as
// metrics.MailUp, which the "Email can't be sent" alert watches (ops/grafana/apply.py): a
// failed send is only counted when someone signs up or resets a password, and an outage with
// neither would go unseen. It logs when the outcome changes, not on every check.
func RunCheck(ctx context.Context, s Sender, interval time.Duration, log *slog.Logger) {
	c, ok := s.(checker)
	if !ok {
		return
	}
	transport := "none"
	if cs, ok := s.(countingSender); ok {
		transport = cs.transport()
	}
	gauge := metrics.MailUp.WithLabelValues(transport)
	var wasUp *bool
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		err := c.Check(ctx)
		up := err == nil
		if up {
			gauge.Set(1)
		} else {
			gauge.Set(0)
		}
		switch {
		case !up && (wasUp == nil || *wasUp):
			log.Error("mail check failed", "transport", transport, "err", err)
		case up && wasUp != nil && !*wasUp:
			log.Info("mail check passed again", "transport", transport)
		}
		wasUp = &up
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
