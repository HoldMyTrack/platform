/// What an uploaded file's state means for the phone that sent it, and how long the watch waits
/// (testdata/client-rules/upload-watch.json, import-retry.json).
public enum ImportWatch {
    /// status: `GET /v2/uploads/{external_id}`'s. landed: the map and Library catch up; done: the
    /// file is no longer watched. Only processing is watched on.
    public static func step(status: String) -> (landed: Bool, done: Bool) {
        (status == "done", status != "processing")
    }

    /// Seconds to wait after failures failed reads in a row, or nil to give up.
    public static func delay(failures: Int) -> Int? { failures >= 8 ? nil : min(2 << failures, 60) }
}
