package mail

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	netmail "net/mail"
	"strings"
)

// zeptoSender sends through ZeptoMail's HTTPS API: a host whose provider blocks outgoing SMTP
// (DigitalOcean does, on 25, 465 and 587) still reaches port 443.
type zeptoSender struct {
	url, token, from string
	client           *http.Client
}

type zeptoAddress struct {
	Address string `json:"address"`
	Name    string `json:"name,omitempty"`
}

type zeptoRequest struct {
	From     zeptoAddress `json:"from"`
	To       []zeptoTo    `json:"to"`
	Subject  string       `json:"subject"`
	TextBody string       `json:"textbody"`
}

type zeptoTo struct {
	EmailAddress zeptoAddress `json:"email_address"`
}

// zeptoError is the part of ZeptoMail's error response kept for the logs: its codes. The
// messages beside them can quote the recipient.
type zeptoError struct {
	Error struct {
		Code    string `json:"code"`
		Details []struct {
			Code string `json:"code"`
		} `json:"details"`
	} `json:"error"`
}

// Send ignores ctx's cancellation for the reason smtpSender.Send gives; the client's timeout,
// sendTimeout, bounds it.
func (s *zeptoSender) Send(ctx context.Context, to, subject, body string) error {
	req, err := zeptoRequestBody(s.from, to, subject, body)
	if err != nil {
		return err
	}
	httpReq, err := http.NewRequestWithContext(context.WithoutCancel(ctx), http.MethodPost, s.url, bytes.NewReader(req))
	if err != nil {
		return fmt.Errorf("mail: zeptomail: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")
	httpReq.Header.Set("Authorization", "Zoho-enczapikey "+strings.TrimPrefix(s.token, "Zoho-enczapikey "))
	resp, err := s.client.Do(httpReq)
	if err != nil {
		return fmt.Errorf("mail: zeptomail: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 == 2 {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		return nil
	}
	return zeptoStatusError(resp.StatusCode, io.LimitReader(resp.Body, 64<<10))
}

// zeptoRequestBody is the API's JSON for one plain-text message. from may carry a display
// name ("HoldMyTrack <noreply@holdmytrack.com>"), which the API takes as a field of its own.
func zeptoRequestBody(from, to, subject, body string) ([]byte, error) {
	sender, err := netmail.ParseAddress(from)
	if err != nil {
		return nil, fmt.Errorf("mail: zeptomail: sender address: %w", err)
	}
	return json.Marshal(zeptoRequest{
		From:     zeptoAddress{Address: sender.Address, Name: sender.Name},
		To:       []zeptoTo{{EmailAddress: zeptoAddress{Address: to}}},
		Subject:  subject,
		TextBody: body,
	})
}

// zeptoStatusError is a failed send's error for the logs: the HTTP status and ZeptoMail's
// error codes, without its messages.
func zeptoStatusError(status int, body io.Reader) error {
	var e zeptoError
	codes := []string{}
	if json.NewDecoder(body).Decode(&e) == nil {
		if e.Error.Code != "" {
			codes = append(codes, e.Error.Code)
		}
		for _, d := range e.Error.Details {
			if d.Code != "" {
				codes = append(codes, d.Code)
			}
		}
	}
	if len(codes) == 0 {
		return fmt.Errorf("mail: zeptomail: HTTP %d", status)
	}
	return fmt.Errorf("mail: zeptomail: HTTP %d %s", status, strings.Join(codes, " "))
}
