# ADR-0036: A Trip can be sent as a copy to another account, which accepts it into a Trip and tracks of its own; nothing syncs afterwards

## Status

Accepted. Built on the server, the web and in the Android app (`SPEC.md` FR-13.7, FR-13.8; `IMPLEMENTATION.md` §3.25, §4.23). A Trip stays private to its account (`VISION.md` §4.2), and what is sent is a copy, not a view of it.

## Context

A family trip is one trip for everyone who went, but usually only one device records it: two people in the same car, or a child walking beside a parent's watch. The others have nothing on their Fog of War, totals or countries for a trip they were on. Trips are private (`VISION.md` §4.2), and sharing one meant an exported image (`IMPLEMENTATION.md` §4.3.3), which shows the trip but doesn't put it in anyone's history.

The request was to give the trip to the people who were on it, as theirs, and to keep it theirs: nothing the sender does later — an edit, a deletion, a deleted account — should take it away from them. Several shapes were weighed against that, from one Trip every member sees to Trips that stay linked and keep syncing; each kept the recipient's history dependent on someone else's account in some way. A copy that becomes the recipient's own data doesn't.

## Decision

**A Trip's owner sends a copy of it to an email address.** Any Trip the account owns can be sent, a received copy included. The answer is the same whether or not the address belongs to an account, so sending can't be used to find out who has one; an address with no account, a demo account or an unverified one receives nothing, and no email goes to a stranger.

**The recipient accepts or declines each copy.** They get a notification email and an item in the Trips tab. Nothing enters an account until its owner accepts. Repeat sends of the same Trip to the same person wait as one item, and deleting the Trip withdraws it.

**Accepting copies the Trip as it is at that moment.** The first copy is a new Trip with the sender's name and description. Each track is made from the sender's displayed points — the sender's Private locations and route edit already applied (`ingest.DisplayedPoints`) — written as a GPX file and run through the ordinary ingest as the recipient's track, so the recipient's own Private locations and duplicate check apply on top. Its name, type and description come with it, and its photos as rows of the recipient's own that point at the same image files. A track with no visible route, hidden entirely by the sender's Private locations, isn't copied.

**Sending again delivers only what's new.** A later copy of the same Trip adds the tracks the recipient hasn't received to the Trip the earlier copy made, or to a new one if they deleted it. Every copy remembers the original track it descends from, and an account receives each original once, ever: a copy the recipient deleted doesn't come back, and a copy sent back to the person who recorded it adds nothing.

**The copy is the recipient's, and nothing syncs.** They can edit it, delete it, add to it and send it on like any Trip of theirs. The sender's later edits, renames and deletions never reach it, and nothing the recipient does reaches the sender.

**Photo files are shared, and removed with their last row.** A copied photo is a new row with the original's image key. Deleting a photo, a track or an account removes an image file only when no row refers to it any more.

## Alternatives considered

- **One Trip every member sees, its tracks held by each member.** No copies, but every read in the application would have to work across accounts, the sender's account deletion would have to keep data for others, and someone had to be stopped from ruining what the others hold — by locking the Trip or by forking every edit.
- **Locking a Trip's tracks once someone joins.** Durable, but it takes away the sender's freedom to fix their own route, and still needs every read to work across accounts.
- **Copy-on-write forks.** Saves the storage of tracks nobody edits, at the price of everything the shared Trip needs plus reference counting on every delete. The storage it saves is small next to photos, which this decision shares anyway.
- **Copies that stay linked, with later additions synced to every member.** Raises questions with no good answers: whose additions travel, whether a member may pass the sender's later tracks on to someone the sender never chose, what sharing back does. Sending again covers the same need with none of them.
- **Copies that arrive without accepting.** Anyone who knew an address could put Trips into an account.
- **Sharing photos by copying their files.** Simpler deletes, but photos are the largest thing a copy carries.

## Consequences

- One new worker job, the copy, built from pieces that exist: `ingest.DisplayedPoints`, `export.WriteGPX` and the ingest pipeline. It is the only place that reads another account's data, and only while copying.
- A copy costs the recipient's storage for its tracks and masks, as if they had uploaded the file themselves; photo files aren't duplicated.
- Photo deletion and the account and demo purges have to count references to an image file instead of removing a whole `photos/{id}/` prefix.
- Account deletion stays total: everything an account owns goes, and a recipient's copies are theirs, not the sender's.
- A copy reflects the sender's Private locations as they were when it was made. A Private location the sender adds later doesn't reach copies already made.
- Nothing is shared live and no one can see another account: this is not the social graph of Milestone 3 (`VISION.md` §5.1, §5.2).