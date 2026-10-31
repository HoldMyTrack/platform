-- §3.30 visitor_salts, visitor_days: unique web visitors per UTC day (docs/IMPLEMENTATION.md §4.32).
CREATE TABLE visitor_salts (
    day date PRIMARY KEY,
    salt bytea NOT NULL
);

CREATE TABLE visitor_days (
    day date NOT NULL,
    hash bytea NOT NULL,
    PRIMARY KEY (day, hash)
);
