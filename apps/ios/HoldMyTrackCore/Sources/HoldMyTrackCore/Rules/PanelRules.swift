/// The selection's rules PanelState applies.
public enum PanelRules {
    /// The tracks drawn bold, on the map and in its exported image: the checked group and the
    /// selected one.
    public static func boldIDs(checked: Set<String>, focused: String?) -> Set<String> {
        focused.map { checked.union([$0]) } ?? checked
    }

    /// What the toolbar acts on: the checked group whenever anything is checked, else the
    /// selected row alone, else nothing. Checked wins so an action never reaches past what was
    /// ticked.
    public static func targetIDs(checked: Set<String>, focused: String?) -> Set<String> {
        if !checked.isEmpty { return checked }
        return focused.map { [$0] } ?? []
    }

    /// Show/Hide over target: any of it hidden shows all of it, otherwise hides all of it, so one
    /// tap always leaves the group in one state.
    public static func toggledVisibility(hidden: Set<String>, target: Set<String>) -> Set<String> {
        target.isDisjoint(with: hidden) ? hidden.union(target) : hidden.subtracting(target)
    }
}
