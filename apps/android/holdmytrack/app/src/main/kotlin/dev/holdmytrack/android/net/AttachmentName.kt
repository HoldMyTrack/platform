package dev.holdmytrack.android.net

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/** The file name a download is saved under, from its Content-Disposition header
 *  (`testdata/client-rules/attachment-name.json`). */
object AttachmentName {

    private val STAR = Regex("filename\\*=(?:([^';]*)'[^';]*')?([^;]+)", RegexOption.IGNORE_CASE)
    private val PLAIN = Regex("(?:^|;)\\s*filename=\"?([^\";]+)\"?", RegexOption.IGNORE_CASE)

    /** The file name in a Content-Disposition [header]: `filename*` (RFC 5987,
     *  `charset'language'value`) before `filename`. */
    fun of(header: String?): String {
        STAR.find(header.orEmpty())?.let { star ->
            val charset = star.groups[1]?.value
            if (charset == null || charset.equals("utf-8", ignoreCase = true)) {
                percentDecode(star.groupValues[2].trim())?.let { return it }
            }
        }
        return PLAIN.find(header.orEmpty())?.groupValues?.get(1) ?: "tracks.gpx"
    }

    /** [s] with its %XX escapes decoded as UTF-8, or null when an escape or the UTF-8 is broken.
     *  Unlike URLDecoder, a `+` stays a `+`. */
    private fun percentDecode(s: String): String? {
        val bytes = ByteArrayOutputStream()
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '%') {
                if (i + 3 > s.length) return null
                val hex = s.substring(i + 1, i + 3)
                if (hex.any { it.digitToIntOrNull(16) == null }) return null // toInt reads a sign too
                val b = hex.toInt(16)
                bytes.write(b)
                i += 3
            } else {
                bytes.write(c.toString().toByteArray(Charsets.UTF_8))
                i++
            }
        }
        return try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
        } catch (e: CharacterCodingException) {
            null
        }
    }
}
