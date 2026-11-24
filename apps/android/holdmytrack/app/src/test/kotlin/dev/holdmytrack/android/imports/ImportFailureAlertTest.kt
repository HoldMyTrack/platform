package dev.holdmytrack.android.imports

import dev.holdmytrack.android.net.ImportFailure
import org.junit.Assert.assertEquals
import org.junit.Test

class ImportFailureAlertTest {

    @Test
    fun `each failure is a paragraph of its title and reason`() {
        val failures = listOf(
            ImportFailure(2, "morning-ride.gpx", "Something went wrong on our side while processing it."),
            ImportFailure(1, "Health Connect", "Something went wrong on our side while processing it."),
        )
        assertEquals(
            "morning-ride.gpx: Something went wrong on our side while processing it.\n\n" +
                "Health Connect: Something went wrong on our side while processing it.",
            ImportFailureAlert.message(failures),
        )
    }
}
