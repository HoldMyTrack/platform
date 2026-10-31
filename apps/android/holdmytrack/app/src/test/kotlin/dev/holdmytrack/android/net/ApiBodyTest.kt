package dev.holdmytrack.android.net

import java.io.IOException
import okhttp3.MediaType
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.Source
import okio.Timeout
import okio.buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A callback's body read answers, even when the connection drops mid-body. */
class ApiBodyTest {

    private fun response(body: ResponseBody) = Response.Builder()
        .request(Request.Builder().url("https://holdmytrack.app/v1/auth/me").build())
        .protocol(Protocol.HTTP_1_1)
        .code(200)
        .message("OK")
        .body(body)
        .build()

    @Test
    fun `a whole body is read as text`() {
        assertEquals("{}", readBody(response("{}".toResponseBody())).getOrThrow())
    }

    /** A body's first bytes, then the connection dropping. */
    private class CutSource(private val head: Buffer) : Source {
        override fun read(sink: Buffer, byteCount: Long): Long =
            if (head.size > 0) head.read(sink, byteCount) else throw IOException("unexpected end of stream")

        override fun timeout(): Timeout = Timeout.NONE

        override fun close() {}
    }

    @Test
    fun `a body cut off mid-stream is a failure, not a throw`() {
        val cut = object : ResponseBody() {
            override fun contentType(): MediaType? = null
            override fun contentLength() = 100L
            override fun source(): BufferedSource = CutSource(Buffer().writeUtf8("{ partial")).buffer()
        }
        assertTrue(readBody(response(cut)).exceptionOrNull() is IOException)
    }
}