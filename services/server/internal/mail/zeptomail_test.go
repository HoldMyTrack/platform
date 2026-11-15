package mail

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	netmail "net/mail"
	"strings"
	"testing"
)

func mustNew(t *testing.T, c Config, logBodies bool, log *slog.Logger) Sender {
	t.Helper()
	s, err := New(c, logBodies, log)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// A configuration that would fail every send, or send in the clear, is refused at start.
func TestNewRefusesABrokenConfig(t *testing.T) {
	for name, c := range map[string]Config{
		"no sender, API":           {ZeptoMailURL: "https://api.zeptomail.com/v1.1/email", ZeptoMailToken: "t"},
		"username as sender, SMTP": {SMTPHost: "smtp.example.com", SMTPPort: "587", From: "emailapikey"},
		"http API URL":             {ZeptoMailURL: "http://api.zeptomail.com/v1.1/email", ZeptoMailToken: "t", From: "a@example.test"},
		"unparsable API URL":       {ZeptoMailURL: "https://%zz", ZeptoMailToken: "t", From: "a@example.test"},
	} {
		if _, err := New(c, false, slog.New(slog.DiscardHandler)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, err := New(Config{}, false, slog.New(slog.DiscardHandler)); err != nil {
		t.Errorf("the unconfigured dev default was refused: %v", err)
	}
}

func TestZeptoRequestBodySplitsTheSendersName(t *testing.T) {
	from, err := netmail.ParseAddress("HoldMyTrack <noreply@holdmytrack.com>")
	if err != nil {
		t.Fatal(err)
	}
	got := zeptoRequestBody(from, "a@example.test", "Сброс пароля", "Тело")
	if got.From != (zeptoAddress{Address: "noreply@holdmytrack.com", Name: "HoldMyTrack"}) ||
		len(got.To) != 1 || got.To[0].EmailAddress != (zeptoAddress{Address: "a@example.test"}) ||
		got.Subject != "Сброс пароля" || got.TextBody != "Тело" {
		t.Errorf("got %+v", got)
	}
}

// A refused send's error keeps the status and ZeptoMail's codes but not its messages, which can
// quote the recipient and would reach the logs.
func TestZeptoStatusErrorLeavesOutTheMessages(t *testing.T) {
	body := `{"error":{"code":"TM_3201","details":[{"code":"GE_102","message":"Invalid address a@example.test","target":"to"}],"message":"Mandatory Field 'to' was not set"}}`
	if got, want := zeptoStatusError(422, strings.NewReader(body)).Error(), "mail: zeptomail: HTTP 422 TM_3201 GE_102"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if got, want := zeptoStatusError(502, strings.NewReader("<html>")).Error(), "mail: zeptomail: HTTP 502"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestZeptoSenderPostsWithTheToken(t *testing.T) {
	var auth string
	var req zeptoRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &req)
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	// The token as the console shows it, with its scheme in any case or whitespace an .env edit
	// left, is sent once-prefixed.
	for _, token := range []string{"secret", "Zoho-enczapikey secret", "zoho-enczapikey secret", " secret\r\n"} {
		s := mustNew(t, Config{ZeptoMailURL: srv.URL, ZeptoMailToken: token, SMTPHost: "unused.example", From: "HoldMyTrack <noreply@holdmytrack.com>"}, false, slog.New(slog.DiscardHandler))
		if err := s.Send(context.Background(), "a@example.test", "Hi", "Body"); err != nil {
			t.Fatal(err)
		}
		if auth != "Zoho-enczapikey secret" {
			t.Errorf("token %q: Authorization %q", token, auth)
		}
		if req.From.Address != "noreply@holdmytrack.com" || req.To[0].EmailAddress.Address != "a@example.test" || req.TextBody != "Body" {
			t.Errorf("request %+v", req)
		}
	}
}

// A redirect counts as a failed send: the 2xx at its end isn't ZeptoMail taking the message.
func TestZeptoSenderDoesNotFollowRedirects(t *testing.T) {
	landing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer landing.Close()
	srv := httptest.NewServer(http.RedirectHandler(landing.URL, http.StatusTemporaryRedirect))
	defer srv.Close()
	s := mustNew(t, Config{ZeptoMailURL: srv.URL, ZeptoMailToken: "t", From: "noreply@holdmytrack.com"}, false, slog.New(slog.DiscardHandler))
	if err := s.Send(context.Background(), "a@example.test", "Hi", "Body"); err == nil || !strings.Contains(err.Error(), "HTTP 307") {
		t.Errorf("got %v, want an HTTP 307 failure", err)
	}
}
