package dev.holdmytrack.android.tour

import org.junit.Assert.assertEquals
import org.junit.Test

class TourRulesTest {

    @Test
    fun `a seen card this build has no card for is dropped`() {
        assertEquals(setOf(TourCard.FOG, TourCard.STORIES), TourRules.seenCards(setOf("FOG", "HEATMAP", "STORIES")))
        assertEquals(emptySet<TourCard>(), TourRules.seenCards(setOf("HEATMAP")))
    }
}
