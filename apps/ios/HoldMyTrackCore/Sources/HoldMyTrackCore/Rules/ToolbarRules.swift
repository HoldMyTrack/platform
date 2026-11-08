/// Which of the Activities toolbar's actions apply, and the master checkbox's state (Android's
/// ToolbarRules).
public enum ToolbarRules {
    /// Why an action can or can't be used.
    public enum Use: Equatable, Sendable {
        case ready, noTarget, demo, pending

        public var enabled: Bool { self == .ready }
    }

    public struct Actions: Equatable, Sendable {
        public let visibility: Use
        public let edit: Use
        public let addToStory: Use
        public let delete: Use
        public let focus: Use
    }

    /// The actions over targets activities. The demo account looks but can't change (the
    /// server's `requireNotDemo`), and a Pending row can't be deleted until its reprocess lands,
    /// since the job would race the delete. Showing, hiding and flying change nothing on the server.
    public static func actions(targets: Int, anyPending: Bool, demo: Bool) -> Actions {
        let look: Use = targets == 0 ? .noTarget : .ready
        let change: Use = demo ? .demo : targets == 0 ? .noTarget : .ready
        let delete: Use = change == .ready && anyPending ? .pending : change
        return Actions(visibility: look, edit: change, addToStory: change, delete: delete, focus: look)
    }

    public enum CheckAll: Equatable, Sendable { case none, some, all }

    /// The master checkbox over listed rows, checked of them checked.
    public static func checkAll(listed: Int, checked: Int) -> CheckAll {
        if listed > 0 && checked == listed { return .all }
        return checked > 0 ? .some : .none
    }
}