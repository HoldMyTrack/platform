-- The connections table that held Path 1's OAuth state: nothing wrote it, and its token columns
-- were a liability. A connector creates what it needs when one is built (docs/BRAINSTORM.md).
DROP TABLE connections;