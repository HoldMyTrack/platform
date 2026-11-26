package dev.holdmytrack.android.map

/** Where a camera fit may put tracks: the map left between the top chrome and what covers the bottom. */
object FrameRules {
    const val PADDING_PX = 64

    /**
     * The fit's padding `[left, top, right, bottom]`. [chromeBottom] is the top row's bottom,
     * [bannerBottom] a capture banner's bottom if one shows, and [coveredBelow] how much of the
     * map an editor or the resting sheet covers. In landscape the two can leave no gap, so the
     * fit keeps a strip of [minSpanPx], taken from the top first.
     */
    fun padding(rootHeight: Int, chromeBottom: Int, bannerBottom: Int?, coveredBelow: Int, minSpanPx: Int): IntArray {
        val top = maxOf(PADDING_PX, chromeBottom, bannerBottom?.let { it + PADDING_PX / 2 } ?: 0)
        val (fitTop, fitBottom) = fit(rootHeight, top, coveredBelow, PADDING_PX, minSpanPx)
        return intArrayOf(PADDING_PX, fitTop, PADDING_PX, fitBottom)
    }

    /** The fit's top and bottom padding under [top] and over [coveredBelow] plus [pad], keeping a
     *  strip of [minSpan] (`testdata/client-rules/frame-padding.json`). */
    fun fit(height: Int, top: Int, coveredBelow: Int, pad: Int, minSpan: Int): Pair<Int, Int> {
        val bottom = pad + coveredBelow
        val fitTop = top.coerceAtMost(maxOf(pad, height - bottom - minSpan))
        val fitBottom = bottom.coerceAtMost(maxOf(pad, height - fitTop - minSpan))
        return fitTop to fitBottom
    }
}
