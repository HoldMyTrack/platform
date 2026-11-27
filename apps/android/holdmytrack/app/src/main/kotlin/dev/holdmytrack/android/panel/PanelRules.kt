package dev.holdmytrack.android.panel

/** The selection's rules [PanelState] applies, as the web's `selection.ts`; both run `testdata/client-rules`. */
object PanelRules {
    /** The tracks drawn bold, on the map and in its exported image: the checked group and the
     *  selected one. */
    fun boldIds(checked: Set<String>, focused: String?): Set<String> = checked + setOfNotNull(focused)

    /** Whether Info shows the pace bands' legend: the map draws [focused]'s bands ([bandsDrawn]),
     *  and the toolbar's target is that track alone, checked or only focused. */
    fun infoShowsBands(checked: Set<String>, focused: String?, bandsDrawn: Boolean): Boolean =
        bandsDrawn && focused != null && targetIds(checked, focused) == setOf(focused)

    enum class SummaryKind { CHECKED, FOCUSED }

    /** How the foot line names the toolbar's target (`docs/SPEC.md` FR-5.8's words): the Checked
     *  group, or the Focused track when nothing is checked, so a track that's only focused never
     *  reads as checked. */
    fun targetSummaryKind(checked: Int, targets: Int): SummaryKind =
        if (checked == 0 && targets > 0) SummaryKind.FOCUSED else SummaryKind.CHECKED

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
     *  the web's `emptyListReason`: else this part of the map holds no track, and the note says so. */
    fun emptyListFiltered(hasActiveFilters: Boolean, datesSet: Boolean): Boolean = hasActiveFilters || datesSet
}
