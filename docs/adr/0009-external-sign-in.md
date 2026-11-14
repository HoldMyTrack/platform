# ADR-0009: Google, Facebook and Apple sign-in run server-side with no library, and link by email only when the provider vouches for it

## Status

Accepted. Built for Google, Facebook and Apple (`SPEC.md` FR-1.9, FR-1.10, FR-1.14; `IMPLEMENTATION.md` §4.9).

## Context

Accounts are email and password with server-side sessions, owned end to end so no vendor can revoke sign-in. Email verification (`SPEC.md` FR-1.8) stands between a new sign-up and the map: a form, a password to invent and an inbox round trip. Most visitors already have a Google, Facebook or Apple account, and signing in with one removes those steps.

Three things had to be decided: where the OAuth flow runs and how much code it takes, how a provider identity finds its account here, and how the link is stored. The second is the one with a security edge. Linking by email is the smooth path for someone who signed up with a password and later clicks a provider's button, and it is safe only when the provider has verified the address. Google's `id_token` carries `email_verified`, and Apple vouches for the email it reports. Facebook's profile (`/me?fields=id,name,email`) has no verified flag, and Meta doesn't document that the email it returns was confirmed.

## Decision

**Every flow is the provider's authorization-code flow, run on the server, with no OAuth or JWT library and no provider script or SDK.** The web's button is a link to `GET /v1/auth/{provider}/start`, and the callback sets the same session cookie as every other sign-in. Round-trip state, and Google's PKCE verifier, live in a short-lived cookie, not a table. An `id_token` received straight from the provider's token endpoint over TLS needs no signature check (OpenID Connect Core §3.1.3.7), so what remains is decoding one segment and checking `iss`, `aud`, `exp` and `email_verified`. In an app, the callback redirects with a one-time code the app redeems with its own verifier (RFC 8252), since any app can register `holdmytrack://`. Android's Google sign-in posts a Credential Manager ID token instead, and that one's signature is checked, since a client sent it.

**An identity is matched by the provider's stable id, never by email.** Without a match:

- **Google and Apple link to the account with the same email**, since they vouch for it. If that account's email was never verified, linking removes its password, its Facebook link and its sessions: whoever set them never proved they own the address, and keeping them would let someone pre-register a victim's email and keep a way in after the victim signs in. An account already linked to a different identity of the same provider is refused.
- **Facebook never links by email.** If the email already belongs to an account, the sign-in is refused with a message saying so. Otherwise a new account is made **unverified** and goes through email verification like a password sign-up. A Facebook account with no email is refused.

**Links are rows of `user_identities (user_id, provider, subject)`**, primary key `(provider, subject)`, one identity per provider per account, deleted with the account.

Each provider is optional per deployment, and email and password never depend on one.

## Alternatives considered

- **Google Identity Services' JavaScript button, posting an ID token.** It loads Google's script on the sign-in page of an app whose privacy stance is a selling point, and the token arrives from the browser, so the server must fetch Google's keys and verify signatures.
- **Meta's SDK.** Default event logging and advertising-ID collection.
- **`golang.org/x/oauth2` plus an OIDC library.** Discovery, key rotation and many providers, none of which three fixed providers on the code flow need; what it would replace is two small HTTP calls per provider.
- **Refuse to link and ask for the password first.** Safer only in the case already covered (an unverified account), and it strands the common case behind an error.
- **Link Facebook by email, like Google.** Anyone who can put an unconfirmed address on a Facebook account would get into the account with that address.
- **Link Facebook by email only to a verified account.** The dangerous direction: the verified account is the victim's.
- **Make new Facebook accounts verified.** Someone could claim an address they don't own, and its owner's later sign-up would find it taken.
- **A column per provider on `users`.** Every lookup, the password-reset filter and the unverified-account cleanup would need a branch per provider.

## Consequences

- Google's and Apple's email verification are part of this app's security boundary: whoever controls a Google or Apple account for an address can sign in to the account with that address, the same trust a password-reset email places in whoever controls the mailbox.
- Someone with a password or Google account can't start using Facebook with it; they get "An account with this email already exists". A Facebook sign-up waits for its verification email where Google's and Apple's don't. That refusal tells the caller the address has an account, which the sign-up endpoint's `409` already does.
- A provider-only account has no password until it sets one through Forgot password.
- A failed callback can only redirect back, so failures show one generic message and the cause is only in the server log.
- Apple's refresh token is kept, for nothing but revoking the link when the account is deleted.
- Facebook's Graph API version is pinned in one constant and needs bumping about every two years.