-- google_nonces: the nonce the Android app asks Google to put in an id_token, so a token posted
-- to POST /v2/auth/google/token is spent once and only in the sign-in it was asked for
-- (docs/IMPLEMENTATION.md §4.9). Kept as a hash for 10 minutes.
CREATE TABLE google_nonces (
    nonce_hash bytea PRIMARY KEY,
    expires_at timestamptz NOT NULL
);

CREATE INDEX idx_google_nonces_expiry ON google_nonces (expires_at);
