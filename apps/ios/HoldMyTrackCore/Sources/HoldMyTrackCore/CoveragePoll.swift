/// How long to wait before asking again whether coverage is still rendering, the web's
/// `coveragePoll.ts`: every 2 seconds for the first 90 reads, then every 10.
public enum CoveragePoll {
    public static func delay(polls: Int) -> Duration { .seconds(polls < 90 ? 2 : 10) }
}
