package dev.holdmytrack.android.export

/**
 * The image's stats card (`docs/SPEC.md` FR-4.7, `docs/IMPLEMENTATION.md` §4.3.3) as values:
 * when Show stats can be ticked, what the server is asked to draw, and where the drawn card goes.
 * The web's `exportStats.ts`; the cases are `testdata/client-rules/stats-offered.json` and
 * `stats-card-placement.json`.
 */
object ExportStatsRules {

    /** What the server is asked to draw: the Checked ids, sorted, and the image's size and theme. */
    data class Request(val activityIds: List<String>, val width: Int, val height: Int, val dark: Boolean) {
        /** Equal for equal requests: what the held card is checked against. */
        val key: String get() = "${width}x$height:${if (dark) "dark" else "light"}:${activityIds.joinToString(",")}"
    }

    /** Whether Show stats can be ticked: something Checked, and no Story open, since the Stories
     *  tab has no checkboxes. */
    fun offered(checked: Set<String>, storyId: String?): Boolean = storyId == null && checked.isNotEmpty()

    /** The card asked for an image [width] × [height], or null when none is shown. */
    fun request(show: Boolean, checked: Set<String>, storyId: String?, width: Int, height: Int, dark: Boolean): Request? =
        if (show && offered(checked, storyId)) Request(checked.sorted(), width, height, dark) else null

    /**
     * Where a card [cardWidth] × [cardHeight] goes on an image [width] × [height]: at the strip's
     * left margin, a margin above the watermark's top. The watermark's bottom is the credit plate's
     * at its nominal descent, so the preview and the image agree without measuring text. Never
     * above the top margin.
     */
    fun placement(width: Int, height: Int, cardWidth: Int, cardHeight: Int): Pair<Float, Float> {
        val (fontPx, margin) = ImageMarks.stripMetrics(width, height)
        val stripBottom = height - margin + fontPx * 0.2f + fontPx * 0.3f
        val watermarkFont = fontPx * ImageMarks.WATERMARK_FONT_SCALE
        val watermarkTop = stripBottom - maxOf(watermarkFont * ImageMarks.WATERMARK_LOGO_SCALE, watermarkFont)
        return margin to maxOf(margin, watermarkTop - margin - cardHeight)
    }
}