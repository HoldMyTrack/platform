/// What a read of the imports still running means for the files this phone uploaded
/// (testdata/client-rules/import-watch.json).
public enum ImportWatch {
    /// expected: running at the last read, with the uploads accepted since; running: now. landed:
    /// one ended since, so the map is read again; next: what the next read is compared with;
    /// again: reading goes on.
    public static func step(expected: Int, running: Int) -> (landed: Bool, next: Int, again: Bool) {
        (running < expected, running, running > 0)
    }
}
