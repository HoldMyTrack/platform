package mail

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	netmail "net/mail"
	"net/url"
	"strings"
)

// zeptoSender sends through ZeptoMail's HTTPS API: a host whose provider blocks outgoing SMTP
// (DigitalOcean does, on 25, 465 and 587) still reaches port 443.
type zeptoSender struct {
	url, token string
	from       *netmail.Address
	client     *http.Client
}

// zeptoResponseLimit caps how much of a response is read: an answer that isn't ZeptoMail's
// small JSON is cut off rather than buffered whole.
const zeptoResponseLimit = 64 << 10

// newZeptoSender takes the token as ZeptoMail's console shows it, with or without its
// "Zoho-enczapikey" scheme and with the surrounding whitespace an .env edit can leave.
func newZeptoSender(rawURL, token string, from *netmail.Address) (*zeptoSender, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, fmt.Errorf("mail: ZEPTOMAIL_API_URL: %w", err)
	}
	if u.Scheme != "https" && (u.Scheme != "http" || needsTLS(u.Hostname())) {
		return nil, fmt.Errorf("mail: ZEPTOMAIL_API_URL must be https, got %q", rawURL)
	}
	token = strings.TrimSpace(token)
	if scheme, rest, ok := strings.Cut(token, " "); ok && strings.EqualFold(scheme, "Zoho-enczapikey") {
		token = strings.TrimSpace(rest)
	}
	return &zeptoSender{
		url:   rawURL,
		token: token,
		from:  from,
		// A redirect isn't followed: the API answers a send itself, and a 2xx from wherever a
		// redirect led would count a message as sent that wasn't.
		client: &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
	}, nil
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

// Send ignores ctx's cancellation for the reason smtpSender.Send gives; sendTimeout bounds it.
func (s *zeptoSender) Send(ctx context.Context, to, subject, body string) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), sendTimeout)
	defer cancel()
	payload, err := json.Marshal(zeptoRequestBody(s.from, to, subject, body))
	if err != nil {
		return fmt.Errorf("mail: zeptomail: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.url, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("mail: zeptomail: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Authorization", "Zoho-enczapikey "+s.token)
	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("mail: zeptomail: %w", err)
	}
	defer resp.Body.Close()
	respBody := io.LimitReader(resp.Body, zeptoResponseLimit)
	if resp.StatusCode/100 != 2 {
		return zeptoStatusError(resp.StatusCode, respBody)
	}
	_, _ = io.Copy(io.Discard, respBody)
	return nil
}

// zeptoRequestBody is the API's request for one plain-text message, the sender's display name
// a field of its own.
func zeptoRequestBody(from *netmail.Address, to, subject, body string) zeptoRequest {
	return zeptoRequest{
		From:     zeptoAddress{Address: from.Address, Name: from.Name},
		To:       []zeptoTo{{EmailAddress: zeptoAddress{Address: to}}},
		Subject:  subject,
		TextBody: body,
	}
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
