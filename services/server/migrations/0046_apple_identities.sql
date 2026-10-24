-- §3.17 user_identities: Sign in with Apple (docs/SPEC.md FR-1.14). Apple requires its token
-- revoked when the account is deleted, and a token can be revoked only by the client it was
-- issued to (the web's Services ID or the iOS app's bundle ID), so an Apple link keeps both.
ALTER TABLE user_identities DROP CONSTRAINT user_identities_provider_check;
ALTER TABLE user_identities ADD CONSTRAINT user_identities_provider_check CHECK (provider IN ('google', 'facebook', 'apple'));
ALTER TABLE user_identities ADD COLUMN refresh_token text, ADD COLUMN client_id text;
