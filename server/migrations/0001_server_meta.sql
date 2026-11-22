-- Facts about the server itself, such as its permanent id.
CREATE TABLE server_meta (
    key   TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
) STRICT;
