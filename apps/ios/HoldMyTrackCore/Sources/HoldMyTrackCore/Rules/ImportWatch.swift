/// What a read of the imports still running means for the files this phone uploaded
/// (testdata/client-rules/import-watch.json, import-retry.json).
public enum ImportWatch {
    /// expected: running at the last read, with the uploads accepted since; running: now;
    /// acceptedSince: accepted while this read was out, which it can't have seen. landed: one ended
    /// since, so the map is read again; next: what the next read is compared with; again: reading
    /// goes on.
    public static func step(expected: Int, running: Int, acceptedSince: Int) -> (landed: Bool, next: Int, again: Bool) {
        let next = running + acceptedSince
        return (running < expected - acceptedSince, next, next > 0)
    }

    /// Seconds to wait after failures failed reads in a row, or nil to give up.
    public static func delay(failures: Int) -> Int? { failures >= 8 ? nil : min(2 << failures, 60) }
}
