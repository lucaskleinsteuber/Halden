-- File moves and removals the database must not lose track of when the server stops halfway.
--
-- 'place': written and committed before a file is moved into the library, deleted in the
-- transaction that records it. A row left over means the move may have happened without the
-- record: the next start moves an upload back to its partial file (so it can be finished) or
-- removes the unrecorded file.
-- 'remove': written in the transaction that deletes a file's record, deleted once the file is
-- gone. A row left over means the file may still be on the disk: the next start removes it. So
-- a photo deleted for good never stays behind on the library disk, the thumbnails or the mirror.
CREATE TABLE file_journal (
    id         INTEGER PRIMARY KEY,
    action     TEXT NOT NULL CHECK (action IN ('place', 'remove')),
    storage    TEXT NOT NULL CHECK (storage IN ('library', 'derived', 'mirror')),
    path       TEXT NOT NULL,
    upload_id  TEXT,
    created_at INTEGER NOT NULL
) STRICT;
