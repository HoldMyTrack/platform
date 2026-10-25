-- Deploy: maintenance — drops the id columns the previous release reads every session by.
-- sessions, password_resets, email_verifications, auth_handoffs: each row keeps its token's
-- SHA-256, not the token (docs/IMPLEMENTATION.md §3.9). A row's id was its token, so hashing the
-- id's text keeps every live session, link and handoff working.
ALTER TABLE sessions ADD COLUMN token_hash bytea;
UPDATE sessions SET token_hash = sha256(convert_to(id::text, 'UTF8'));
ALTER TABLE sessions DROP COLUMN id, ALTER COLUMN token_hash SET NOT NULL, ADD PRIMARY KEY (token_hash);

ALTER TABLE password_resets ADD COLUMN token_hash bytea;
UPDATE password_resets SET token_hash = sha256(convert_to(id::text, 'UTF8'));
ALTER TABLE password_resets DROP COLUMN id, ALTER COLUMN token_hash SET NOT NULL, ADD PRIMARY KEY (token_hash);

ALTER TABLE email_verifications ADD COLUMN token_hash bytea;
UPDATE email_verifications SET token_hash = sha256(convert_to(id::text, 'UTF8'));
ALTER TABLE email_verifications DROP COLUMN id, ALTER COLUMN token_hash SET NOT NULL, ADD PRIMARY KEY (token_hash);

ALTER TABLE auth_handoffs ADD COLUMN token_hash bytea;
UPDATE auth_handoffs SET token_hash = sha256(convert_to(id::text, 'UTF8'));
ALTER TABLE auth_handoffs DROP COLUMN id, ALTER COLUMN token_hash SET NOT NULL, ADD PRIMARY KEY (token_hash);
