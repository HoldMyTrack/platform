package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestNormalizeVerificationCode(t *testing.T) {
	for raw, want := range map[string]string{
		"123456":    "123456",
		" 123 456 ": "123456",
		"123-456":   "123456",
		"123 456":   "123456",
		"12345":     "",
		"1234567":   "",
		"12345a":    "",
		"١٢٣٤٥٦":    "",
	} {
		got, ok := normalizeVerificationCode(raw)
		if got != want || ok != (want != "") {
			t.Errorf("%q: (%q, %v), want %q", raw, got, ok, want)
		}
	}
}

func TestCheckVerificationCode(t *testing.T) {
	for name, tc := range map[string]struct {
		live     bool
		attempts int
		matches  bool
		want     codeVerdict
	}{
		"right":                    {true, 0, true, codeAccepted},
		"right on the last try":    {true, verificationCodeTries - 1, true, codeAccepted},
		"wrong":                    {true, 0, false, codeWrong},
		"wrong on the last try":    {true, verificationCodeTries - 1, false, codeUsedUp},
		"right after the last try": {true, verificationCodeTries, true, codeExpired},
		"right but expired":        {false, 0, true, codeExpired},
	} {
		if got := checkVerificationCode(tc.live, tc.attempts, tc.matches); got != tc.want {
			t.Errorf("%s: %v, want %v", name, got, tc.want)
		}
	}
}

func TestVerificationCodeHashIsBoundToItsLink(t *testing.T) {
	if bytes.Equal(verificationCodeHash([]byte("a"), "123456"), verificationCodeHash([]byte("b"), "123456")) {
		t.Error("the same code under two links hashes the same")
	}
}

// mailedCode is the code in the newest verification email mailed to an address.
func (d *dbTest) mailedCode(to string) string {
	d.t.Helper()
	m := d.srv.mailer.(*sentMail)
	m.mu.Lock()
	defer m.mu.Unlock()
	code := regexp.MustCompile(`(?m)^(\d{6})$`)
	for i := len(m.bodies) - 1; i >= 0; i-- {
		if found := code.FindStringSubmatch(m.bodies[i]); found != nil && m.to[i] == to {
			return found[1]
		}
	}
	d.t.Fatalf("no code mailed to %s", to)
	return ""
}

// unverifiedWithCode is a new unverified account that has been mailed a code, and its address.
func (d *dbTest) unverifiedWithCode() (account, string) {
	d.t.Helper()
	d.srv.mailer = &sentMail{}
	a := d.newAccount(false)
	if _, err := d.pool.Exec(context.Background(), `UPDATE users SET email_verified = false WHERE id = $1`, a.id); err != nil {
		d.t.Fatal(err)
	}
	email, _ := d.email(a)
	if err := d.srv.sendVerificationEmail(context.Background(), a.id, email, "en"); err != nil {
		d.t.Fatal(err)
	}
	return a, email
}

// secondSession signs a in somewhere else.
func (d *dbTest) secondSession(a account) account {
	d.t.Helper()
	other := account{id: a.id}
	var hash []byte
	other.session, hash = newToken()
	if _, err := d.pool.Exec(context.Background(),
		`INSERT INTO sessions (token_hash, user_id, expires_at) VALUES ($1, $2, NOW() + INTERVAL '1 hour')`, hash, a.id); err != nil {
		d.t.Fatal(err)
	}
	return other
}

func (d *dbTest) typeCode(as account, code string) (int, string) {
	d.t.Helper()
	rec := d.do(as, http.MethodPost, "/v1/auth/verify-code", map[string]string{"code": code})
	var body struct{ Error string }
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	return rec.Code, body.Error
}

// The code verifies the account in the session that types it, which stays signed in while every
// other session of the account ends (SPEC FR-1.8).
func TestVerificationCodeKeepsTheSessionThatTypesIt(t *testing.T) {
	d := newDBTest(t)
	a, email := d.unverifiedWithCode()
	elsewhere := d.secondSession(a)
	code := d.mailedCode(email)

	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	if status, errCode := d.typeCode(a, wrong); status != http.StatusBadRequest || errCode != "code_wrong" {
		t.Fatalf("wrong code: %d %q, want 400 code_wrong", status, errCode)
	}
	if status, errCode := d.typeCode(a, "12"); status != http.StatusBadRequest || errCode != "code_invalid" {
		t.Fatalf("short code: %d %q, want 400 code_invalid", status, errCode)
	}
	var me struct {
		EmailVerified bool `json:"email_verified"`
	}
	d.decode(d.do(a, http.MethodPost, "/v1/auth/verify-code", map[string]string{"code": code[:3] + " " + code[3:]}), http.StatusOK, &me)
	if !me.EmailVerified {
		t.Fatal("the answer isn't the verified account")
	}
	if rec := d.do(a, http.MethodGet, "/v1/auth/me", nil); rec.Code != http.StatusOK {
		t.Errorf("the session that typed the code: %d, want still signed in", rec.Code)
	}
	if rec := d.do(elsewhere, http.MethodGet, "/v1/auth/me", nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("another session of the account: %d, want 401", rec.Code)
	}
	if status, errCode := d.typeCode(a, code); status != http.StatusBadRequest || errCode != "code_expired" {
		t.Errorf("the code again: %d %q, want 400 code_expired", status, errCode)
	}
}

// Five wrong tries use a code up; a code past its time, or from an older email, doesn't work.
func TestVerificationCodeLimits(t *testing.T) {
	d := newDBTest(t)
	a, email := d.unverifiedWithCode()
	code := d.mailedCode(email)
	n, err := strconv.Atoi(code)
	if err != nil {
		t.Fatal(err)
	}
	wrong := fmt.Sprintf("%06d", (n+1)%1_000_000)
	for i := 1; i <= verificationCodeTries; i++ {
		want := "code_wrong"
		if i == verificationCodeTries {
			want = "code_used_up"
		}
		if _, errCode := d.typeCode(a, wrong); errCode != want {
			t.Fatalf("wrong try %d: %q, want %q", i, errCode, want)
		}
	}
	if _, errCode := d.typeCode(a, code); errCode != "code_expired" {
		t.Fatalf("the right code after five wrong tries: %q, want code_expired", errCode)
	}

	b, emailB := d.unverifiedWithCode()
	if _, err := d.pool.Exec(context.Background(), `UPDATE email_verifications SET code_expires_at = NOW() - INTERVAL '1 second' WHERE user_id = $1`, b.id); err != nil {
		t.Fatal(err)
	}
	if _, errCode := d.typeCode(b, d.mailedCode(emailB)); errCode != "code_expired" {
		t.Errorf("a code past its time: %q, want code_expired", errCode)
	}

	c, emailC := d.unverifiedWithCode()
	older := d.mailedCode(emailC)
	time.Sleep(time.Millisecond)
	if err := d.srv.sendVerificationEmail(context.Background(), c.id, emailC, "en"); err != nil {
		t.Fatal(err)
	}
	if newer := d.mailedCode(emailC); newer != older {
		if _, errCode := d.typeCode(c, older); errCode != "code_wrong" {
			t.Errorf("the older email's code: %q, want code_wrong", errCode)
		}
	}
	if _, verified := d.email(c); verified {
		t.Error("the older email's code verified the account")
	}
}

// A changed address another account took meanwhile is refused, as the link refuses it.
func TestVerificationCodeForAnAddressTakenMeanwhile(t *testing.T) {
	d := newDBTest(t)
	a, email := d.unverifiedWithCode()
	target := "taken-" + email
	d.decode(d.do(a, http.MethodPatch, "/v1/auth/email", map[string]string{"email": target}), http.StatusOK, nil)
	code := d.mailedCode(target)
	other := d.newAccount(false)
	if _, err := d.pool.Exec(context.Background(), `UPDATE users SET email = $2 WHERE id = $1`, other.id, target); err != nil {
		t.Fatal(err)
	}
	if status, errCode := d.typeCode(a, code); status != http.StatusConflict || errCode != "email_taken" {
		t.Errorf("%d %q, want 409 email_taken", status, errCode)
	}
}

// The web's check-your-email page takes the code and goes on to the map.
func TestVerifyPendingCodeForm(t *testing.T) {
	d := newDBTest(t)
	a, email := d.unverifiedWithCode()
	post := func(code string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/verify-pending/code", strings.NewReader(url.Values{"code": {code}}.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("Origin", "https://app.example")
		req.AddCookie(&http.Cookie{Name: sessionCookieName, Value: a.session})
		rec := httptest.NewRecorder()
		d.srv.ServeHTTP(rec, req)
		return rec
	}
	if rec := post("12"); rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "Enter the 6-digit code from the email.") || !strings.Contains(rec.Body.String(), `action="/verify-pending/code"`) {
		t.Fatalf("short code: %d, not the page again with its message", rec.Code)
	}
	if rec := post(d.mailedCode(email)); rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/" {
		t.Fatalf("right code: %d to %q, want a redirect to /", rec.Code, rec.Header().Get("Location"))
	}
	if _, verified := d.email(a); !verified {
		t.Error("not verified")
	}
}

// Wrong codes are limited per address across codes and accounts: past ten in an hour even the
// right code is refused.
func TestVerificationCodeTriesPerAddress(t *testing.T) {
	d := newDBTest(t)
	a, email := d.unverifiedWithCode()
	wrongFor := func(code string) string {
		n, err := strconv.Atoi(code)
		if err != nil {
			t.Fatal(err)
		}
		return fmt.Sprintf("%06d", (n+1)%1_000_000)
	}
	for round := 0; round < 2; round++ {
		code := d.mailedCode(email)
		for i := 0; i < verificationCodeTries; i++ {
			d.typeCode(a, wrongFor(code))
		}
		time.Sleep(time.Millisecond)
		if err := d.srv.sendVerificationEmail(context.Background(), a.id, email, "en"); err != nil {
			t.Fatal(err)
		}
	}
	if status, errCode := d.typeCode(a, d.mailedCode(email)); status != http.StatusTooManyRequests || errCode != "code_rate_limited" {
		t.Errorf("the right code after ten wrong ones for the address: %d %q, want 429 code_rate_limited", status, errCode)
	}
}

// Another account can't start confirming an address one account is already confirming.
func TestAddressChangeToAnAddressPendingElsewhere(t *testing.T) {
	d := newDBTest(t)
	a, email := d.unverifiedWithCode()
	target := "pending-" + email
	d.decode(d.do(a, http.MethodPatch, "/v1/auth/email", map[string]string{"email": target}), http.StatusOK, nil)
	b, _ := d.unverifiedWithCode()
	var body struct{ Error string }
	d.decode(d.do(b, http.MethodPatch, "/v1/auth/email", map[string]string{"email": target}), http.StatusConflict, &body)
	if body.Error != "email_pending" {
		t.Errorf("error %q, want email_pending", body.Error)
	}
}

// The code leads the subject and the body, so a notification or the inbox list shows it, and
// a phone's keyboard can offer it.
func TestVerificationEmailLeadsWithTheCode(t *testing.T) {
	d := newDBTest(t)
	_, email := d.unverifiedWithCode()
	code := d.mailedCode(email)
	m := d.srv.mailer.(*sentMail)
	m.mu.Lock()
	defer m.mu.Unlock()
	last := len(m.bodies) - 1
	if !strings.HasPrefix(m.subjects[last], code+" ") || !strings.HasPrefix(m.bodies[last], code+"\n") {
		t.Errorf("subject %q, body %q: want both to start with the code %s", m.subjects[last], m.bodies[last], code)
	}
}
