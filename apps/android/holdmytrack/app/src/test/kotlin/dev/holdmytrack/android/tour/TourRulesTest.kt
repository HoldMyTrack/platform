package dev.holdmytrack.android.tour

import org.junit.Assert.assertEquals
import org.junit.Test

class TourRulesTest {

    @Test
    fun `a seen card this build has no card for is dropped`() {
        assertEquals(setOf(TourCard.FOG, TourCard.TRIPS), TourRules.seenCards(setOf("FOG", "HEATMAP", "TRIPS")))
        assertEquals(emptySet<TourCard>(), TourRules.seenCards(setOf("HEATMAP")))
        assertEquals(setOf(TourCard.TRIPS), TourRules.seenCards(setOf("STORIES")))
    }
}
