package mail

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestZeptoRequestBodySplitsTheSendersName(t *testing.T) {
	b, err := zeptoRequestBody("HoldMyTrack <noreply@holdmytrack.com>", "a@example.test", "Сброс пароля", "Тело")
	if err != nil {
		t.Fatal(err)
	}
	var got zeptoRequest
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	want := zeptoRequest{
		From:     zeptoAddress{Address: "noreply@holdmytrack.com", Name: "HoldMyTrack"},
		To:       []zeptoTo{{EmailAddress: zeptoAddress{Address: "a@example.test"}}},
		Subject:  "Сброс пароля",
		TextBody: "Тело",
	}
	if got.From != want.From || len(got.To) != 1 || got.To[0] != want.To[0] || got.Subject != want.Subject || got.TextBody != want.TextBody {
		t.Errorf("got %+v, want %+v", got, want)
	}
	if _, err := zeptoRequestBody("not an address", "a@example.test", "s", "b"); err == nil {
		t.Error("an unparsable sender was accepted")
	}
}

// A refused send's error keeps the status and ZeptoMail's codes but not its messages, which can
// quote the recipient and would reach the logs.
func TestZeptoStatusErrorLeavesOutTheMessages(t *testing.T) {
	body := `{"error":{"code":"TM_3201","details":[{"code":"GE_102","message":"Invalid address a@example.test","target":"to"}],"message":"Mandatory Field 'to' was not set"}}`
	err := zeptoStatusError(422, strings.NewReader(body))
	if got, want := err.Error(), "mail: zeptomail: HTTP 422 TM_3201 GE_102"; got != want {
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

	// The token pasted with its scheme, as ZeptoMail's console shows it, is sent once-prefixed.
	for _, token := range []string{"secret", "Zoho-enczapikey secret"} {
		s := New(Config{ZeptoMailURL: srv.URL, ZeptoMailToken: token, SMTPHost: "unused.example", From: "noreply@holdmytrack.com"}, false, slog.New(slog.DiscardHandler))
		if err := s.Send(context.Background(), "a@example.test", "Hi", "Body"); err != nil {
			t.Fatal(err)
		}
		if auth != "Zoho-enczapikey secret" {
			t.Errorf("token %q: Authorization %q", token, auth)
		}
		if req.To[0].EmailAddress.Address != "a@example.test" || req.TextBody != "Body" {
			t.Errorf("request %+v", req)
		}
	}
}
