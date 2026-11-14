# Known Issues

Open defects in shipped functionality. A fixed entry is deleted, with any lasting note moved into `docs/IMPLEMENTATION.md` beside the code it concerns.

---

### Photo prep in Chromium decodes a large PNG at full size

`preparePhoto` (`apps/web/src/ui/photoPrep.ts`, `IMPLEMENTATION.md` §4.27) avoids a full-size decode of a large photo in Chromium only for a JPEG, which Chromium decodes at a reduced scale when the `<img>` is drawn onto the 2048 px canvas. A PNG gets no scaled decode there: `ImageDecoder` hands back the whole frame, and the `<img>` is decoded whole too. A 192 MP PNG peaked at about 1 GB in desktop Chromium and 813 MB in Chrome on a Pixel 10a. Camera, panorama and drone images are JPEGs, so this needs a very large PNG, such as an exported or stitched picture. WebP and AVIF were not measured.

- [ ] Find a decode path for a large PNG in Chromium that doesn't hold it at full size, or refuse one above a pixel count with a reason, and measure WebP and AVIF while at it.

### Turnstile doesn't guard the JSON signup endpoint

Turnstile checks only the web `/signup` page (`IMPLEMENTATION.md` §4.19). `POST /v1/auth/signup`, which the Android and iOS sign-up forms call, takes no token, so a script can make unconfirmed accounts there, up to the per-address limit (`SPEC.md` FR-1.1).

- [ ] Give the native sign-up forms a Turnstile token, then require one on `POST /v1/auth/signup`.

### Deleting an account on Android leaves two pieces of its state on the phone

Account deletion clears what the device keeps for the account (`AccountDeletion.forget`): unsynced recordings, hidden Sync rows, the Health Connect switch and what Load last read. It does not clear the last-used recording type (`RecordingTypes`) or an unfinished recording's journal (`LiveRecordingJournal`), so a new account signing in with the same email inherits them.

- [ ] Clear both in `AccountDeletion.forget`.