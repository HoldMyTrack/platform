// Package mail sends the app's email: verification and password-reset links, export-ready
// notices and Story copies (IMPLEMENTATION.md §4.9). Stdlib net/smtp against the SMTP_*
// config, so any provider that speaks SMTP works, or ZeptoMail's HTTPS API where the host
// blocks outgoing SMTP.
package mail

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/smtp"
	"net/textproto"
	"strings"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/metrics"
)

type Sender interface {
	Send(ctx context.Context, to, subject, body string) error
}

// Config is the outgoing mail settings. From is the sender for both transports.
type Config struct {
	ZeptoMailURL, ZeptoMailToken                   string
	SMTPHost, SMTPPort, SMTPUsername, SMTPPassword string
	From                                           string
}

// Configured reports whether c sends real mail.
func (c Config) Configured() bool { return c.ZeptoMailToken != "" || c.SMTPHost != "" }

// New picks ZeptoMail's API when its token is set, else SMTP when a host is, else a sender that
// logs the message instead. An empty config is a valid, intentional default: dev and tests never
// need real delivery to exercise the reset flow end to end, and the log line carries the same
// reset link a real email would.
//
// logBodies says whether that log line carries the body. The caller passes false for a real
// deployment (an https APP_BASE_URL): a body holds a live reset or verification link, and
// written to the logs it would open the account to anyone who can read them.
func New(c Config, logBodies bool, log *slog.Logger) Sender {
	switch {
	case c.ZeptoMailToken != "":
		return countingSender{&zeptoSender{url: c.ZeptoMailURL, token: c.ZeptoMailToken, from: c.From, client: &http.Client{Timeout: sendTimeout}}}
	case c.SMTPHost != "":
		return countingSender{&smtpSender{host: c.SMTPHost, port: c.SMTPPort, username: c.SMTPUsername, password: c.SMTPPassword, from: c.From}}
	}
	return &logSender{log: log, logBodies: logBodies}
}

// countingSender counts each send's outcome (metrics.MailSent): callers only log a failure, so a
// provider refusing every message, its credits used up or expired, is noticed by the count.
type countingSender struct{ next Sender }

func (s countingSender) Send(ctx context.Context, to, subject, body string) error {
	err := s.next.Send(ctx, to, subject, body)
	outcome := "sent"
	if err != nil {
		outcome = "failed"
	}
	metrics.MailSent.WithLabelValues(outcome).Inc()
	return err
}

type logSender struct {
	log       *slog.Logger
	logBodies bool
}

func (s *logSender) Send(_ context.Context, to, subject, body string) error {
	if !s.logBodies {
		s.log.Warn("mail: not configured, message not sent", "to", to, "subject", subject)
		return nil
	}
	s.log.Info("mail: not configured, logging instead of sending", "to", to, "subject", subject, "body", body)
	return nil
}

type smtpSender struct {
	host, port, username, password, from string
}

// sendTimeout bounds one message, from the dial to QUIT. Signup, reset and resend send inside
// their request, and the HTTP server has no write timeout (uploads take minutes), so a server
// that stops answering would otherwise hold those requests open for good: a port expecting TLS
// from the first byte (465) never sends the plaintext greeting net/smtp waits for.
var sendTimeout = 30 * time.Second

// Send does the manual STARTTLS dance net/smtp has no convenience wrapper for — dial plain,
// upgrade if the server offers STARTTLS (every real provider does), authenticate, then the
// usual MAIL/RCPT/DATA sequence. net/smtp takes no context, so the connection's deadline,
// sendTimeout, is what bounds every step. ctx's cancellation is ignored: a sign-up's
// verification mail is owed once the account exists, whether or not the client that asked is
// still there.
func (s *smtpSender) Send(ctx context.Context, to, subject, body string) error {
	ctx = context.WithoutCancel(ctx)
	deadline := time.Now().Add(sendTimeout)
	addr := net.JoinHostPort(s.host, s.port)
	conn, err := (&net.Dialer{Deadline: deadline}).DialContext(ctx, "tcp", addr)
	if err != nil {
		return fmt.Errorf("mail: dial %s: %w", addr, err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(deadline); err != nil {
		return fmt.Errorf("mail: deadline: %w", err)
	}

	client, err := smtp.NewClient(conn, s.host)
	if err != nil {
		return replyError("new client", err)
	}
	defer client.Close()

	if ok, _ := client.Extension("STARTTLS"); ok {
		if err := client.StartTLS(&tls.Config{ServerName: s.host}); err != nil {
			return replyError("starttls", err)
		}
	} else if needsTLS(s.host) {
		// Not sent in the clear: every message carries a sign-in, reset or verification link,
		// and a server, or something in between, that drops STARTTLS would expose them.
		return fmt.Errorf("mail: %s offers no STARTTLS", s.host)
	}

	if s.username != "" {
		if err := client.Auth(smtp.PlainAuth("", s.username, s.password, s.host)); err != nil {
			return replyError("auth", err)
		}
	}

	if err := client.Mail(s.from); err != nil {
		return replyError("MAIL FROM", err)
	}
	if err := client.Rcpt(to); err != nil {
		return replyError("RCPT TO", err)
	}

	w, err := client.Data()
	if err != nil {
		return replyError("DATA", err)
	}
	if _, err := w.Write(message(s.from, to, subject, body)); err != nil {
		return replyError("write body", err)
	}
	if err := w.Close(); err != nil {
		return replyError("close body", err)
	}
	return replyError("QUIT", client.Quit())
}

// needsTLS reports whether mail to host must be encrypted: everywhere it could cross a network
// someone else runs. A relay on this machine, a private address or a one-label name (a compose
// service such as "smtp") is the deployment's own.
func needsTLS(host string) bool {
	if ip := net.ParseIP(host); ip != nil {
		return !ip.IsLoopback() && !ip.IsPrivate()
	}
	return strings.Contains(host, ".")
}

// replyError is err from step for the logs, nil for nil. An SMTP reply keeps only its code: a
// server's reply text often quotes the recipient (`550 5.1.1 <user@example.com>: Recipient
// address rejected`), and the caller logs the error, which ships to Grafana Cloud.
func replyError(step string, err error) error {
	if err == nil {
		return nil
	}
	var reply *textproto.Error
	if errors.As(err, &reply) {
		return fmt.Errorf("mail: %s: SMTP reply %d", step, reply.Code)
	}
	return fmt.Errorf("mail: %s: %w", step, err)
}

// message is the whole email as sent. The subject is RFC 2047-encoded: a header may only
// carry ASCII, and a translated subject (a Russian one) isn't — mime.QEncoding leaves an
// ASCII subject exactly as it was. The body needs no such step; Content-Type declares it UTF-8.
func message(from, to, subject, body string) []byte {
	return fmt.Appendf(nil, "From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s\r\n",
		from, to, mime.QEncoding.Encode("utf-8", subject), body)
}
