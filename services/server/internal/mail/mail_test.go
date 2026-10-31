package mail

import (
	"bufio"
	"bytes"
	"context"
	"log/slog"
	"net"
	"strings"
	"testing"
)

func TestMessageEncodesSubject(t *testing.T) {
	ascii := string(message("a@x", "b@x", "Reset your HoldMyTrack password", "body"))
	if !strings.Contains(ascii, "\r\nSubject: Reset your HoldMyTrack password\r\n") {
		t.Errorf("ASCII subject changed:\n%s", ascii)
	}
	ru := string(message("a@x", "b@x", "Сброс пароля HoldMyTrack", "Тело"))
	if !strings.Contains(ru, "\r\nSubject: =?utf-8?q?") {
		t.Errorf("non-ASCII subject not RFC 2047-encoded:\n%s", ru)
	}
	head, _, _ := strings.Cut(ru, "\r\n\r\n")
	for _, c := range head {
		if c > 127 {
			t.Fatalf("non-ASCII byte in headers:\n%s", head)
		}
	}
	if !strings.HasSuffix(ru, "\r\n\r\nТело\r\n") {
		t.Errorf("body not sent as is:\n%s", ru)
	}
}

// Without SMTP, a real deployment's log never carries a message body: it holds a live reset or
// verification link.
func TestLogSenderKeepsBodiesOutOfARealDeploymentsLog(t *testing.T) {
	for _, logBodies := range []bool{false, true} {
		var buf bytes.Buffer
		s := New("", "", "", "", "", logBodies, slog.New(slog.NewTextHandler(&buf, nil)))
		if err := s.Send(context.Background(), "a@x", "Reset", "https://app.example/reset?token=secret"); err != nil {
			t.Fatal(err)
		}
		if got := strings.Contains(buf.String(), "secret"); got != logBodies {
			t.Errorf("logBodies %v: body in log = %v\n%s", logBodies, got, buf.String())
		}
	}
}

// A rejected recipient's error keeps the SMTP code but not the server's text, which quotes the
// address and would reach the logs.
func TestSendErrorLeavesOutTheReplyText(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		r := bufio.NewReader(conn)
		conn.Write([]byte("220 test ESMTP\r\n"))
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				return
			}
			switch cmd := strings.ToUpper(strings.TrimSpace(line)); {
			case strings.HasPrefix(cmd, "EHLO"), strings.HasPrefix(cmd, "HELO"), strings.HasPrefix(cmd, "MAIL"):
				conn.Write([]byte("250 ok\r\n"))
			case strings.HasPrefix(cmd, "RCPT"):
				conn.Write([]byte("550 5.1.1 <user@example.com>: Recipient address rejected\r\n"))
			default:
				conn.Write([]byte("221 bye\r\n"))
				return
			}
		}
	}()

	host, port, _ := net.SplitHostPort(ln.Addr().String())
	s := New(host, port, "", "", "from@holdmytrack.app", false, slog.New(slog.DiscardHandler))
	err = s.Send(context.Background(), "user@example.com", "subject", "body")
	if err == nil {
		t.Fatal("rejected recipient: want an error")
	}
	if msg := err.Error(); strings.Contains(msg, "@") || !strings.Contains(msg, "RCPT TO") || !strings.Contains(msg, "550") {
		t.Errorf("error %q: want the step and code without the address", msg)
	}
}
