package dev.holdmytrack.android.panel

/** The selection's rules [PanelState] applies, as the web's `selection.ts`; both run `testdata/client-rules`. */
object PanelRules {
    /** The tracks drawn bold, on the map and in its exported image: the checked group and the
     *  selected one. */
    fun boldIds(checked: Set<String>, focused: String?): Set<String> = checked + setOfNotNull(focused)

    /** What the toolbar acts on: the checked group whenever anything is checked, else the
     *  selected row alone, else nothing. Checked wins so an action never reaches past what was ticked. */
    fun targetIds(checked: Set<String>, focused: String?): Set<String> = when {
        checked.isNotEmpty() -> checked
        focused != null -> setOf(focused)
        else -> emptySet()
    }

    /** Show/Hide over [target]: any of it hidden shows all of it, otherwise hides all of it, so
     *  one tap always leaves the group in one state. */
    fun toggledVisibility(hidden: Set<String>, target: Set<String>): Set<String> =
        if (target.any { it in hidden }) hidden - target else hidden + target

    /** Whether an empty list is the filters' doing (a Type, Distance or Dates filter is set), as
     *  the web's `emptyListReason`: else this part of the map holds no activity, and the note says so. */
    fun emptyListFiltered(hasActiveFilters: Boolean, datesSet: Boolean): Boolean = hasActiveFilters || datesSet
}
