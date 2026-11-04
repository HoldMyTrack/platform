-- §3.31 imagery_status: whether satellite imagery is offered to everyone (docs/IMPLEMENTATION.md §4.26).
CREATE TABLE imagery_status (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),
    available boolean NOT NULL,
    reason text NOT NULL DEFAULT '',
    used bigint,
    request_limit bigint,
    checked_at timestamptz NOT NULL
);
