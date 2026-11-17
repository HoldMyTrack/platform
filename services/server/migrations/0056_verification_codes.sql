-- email_verifications: each link also carries a 6-digit code the account's own session can type
-- instead of opening the link (docs/IMPLEMENTATION.md §4.9). The code is kept as a hash, lives
-- 30 minutes and allows five wrong tries. A row from before this release has no code.
ALTER TABLE email_verifications
    ADD COLUMN code_hash bytea,
    ADD COLUMN code_expires_at timestamptz,
    ADD COLUMN code_attempts smallint NOT NULL DEFAULT 0;
