# ADR-0050: HoldMyTrack covers its own costs, whether it ever asks for money is left open, and nothing public speaks of money

## Status

Accepted. Applied to `VISION.md` §1, §3.3, §5, §6, §8, `ROADMAP.md`, `SPEC.md` FR-11.1, `README.md`, `AGENTS.md`, `ARCHITECTURE.md`, `IMPLEMENTATION.md` §5.7, and the About and Privacy pages and the site's descriptions. Supersedes ADR-0031's funding model: community donations with a public ledger, a funding page before launch, and Milestone 2's exit gate measured against donations. ADR-0031's three milestones, its "no data sales" promise and its every-feature-for-everyone stand.

## Context

ADR-0031 made HoldMyTrack free and paid for by recurring community donations, with an Open Collective page standing before launch and Milestone 2 ending on a measured answer to what donations could carry. The site said so: "free, community-funded", "funded by the people who use it", and a section on the donation plan.

None of it was true yet. No donations are taken, the running costs are covered without them, and whether HoldMyTrack will ever ask users for money is not known. A public plan for money that may never come reads as a promise to keep or break, and "the developer pays" reads as a side project.

## Decision

- **HoldMyTrack covers its running costs.** How is not public.
- **Whether it ever asks for money, and how, is left open**, and decided when there is a reason to: usage, cost, or what users ask for.
- **Nothing public speaks of money.** The site, the apps and the repository's front page say that HoldMyTrack is free, with no subscriptions or paid features, that it is open source, and that data is never sold. They make no claim about funding, donations or who pays.
- **Milestone 2 has no exit gate.** Milestone 3 is decided when it makes sense, from whatever Milestone 2 shows.
- **The built Donate feature stays, switched off** (`SPEC.md` FR-11.1): it appears only once an Open Collective is configured, and none is. The launch no longer waits on a funding page.

## Alternatives considered

- **Keep ADR-0031's plan and say it publicly**, with "donations are not open yet" in the meantime. Rejected: it promises a model nobody has committed to, and says the project can't pay for itself.
- **Promise never to ask for money.** Rejected: firmer than anyone can stand behind, and hard to take back without breaking it.
- **Remove the Donate feature.** Rejected: switched off it costs nothing, and bringing it back would mean rebuilding it.

## Consequences

- **The pitch loses "funded by its users"** and keeps "free, open source, data never sold". Asking for money later is a new decision, announced then, with no earlier promise to square it with.
- **Milestone 2 produces no number that decides Milestone 3.** Cost per active user is still measured (`IMPLEMENTATION.md` §5.7), but nothing waits on it.
- **Turning Donate on is a public change of position**: it needs a new ADR, and the site's copy changed with it.