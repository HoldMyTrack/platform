package dev.holdmytrack.android.net

import java.io.IOException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A suspended request goes with its coroutine (the Sync tab's run, an upload). */
class CallAwaitTest {

    /** A call that answers only when told to, and remembers being cancelled. */
    private class HeldCall(
        private val real: Call = OkHttpClient().newCall(Request.Builder().url("https://holdmytrack.com/v2/sync/tracks").build()),
    ) : Call by real {
        var callback: Callback? = null
        @Volatile var cancelled = false

        override fun enqueue(responseCallback: Callback) { callback = responseCallback }
        override fun cancel() { cancelled = true }
        override fun isCanceled() = cancelled

        fun answer(code: Int) = Response.Builder().request(request()).protocol(Protocol.HTTP_1_1).code(code).message("").build()
    }

    @Test
    fun `the answer is returned`() = runBlocking {
        val call = HeldCall()
        val pending = async(Dispatchers.Default, CoroutineStart.UNDISPATCHED) { call.await() }
        call.callback!!.onResponse(call, call.answer(200))
        assertEquals(200, pending.await().code)
    }

    @Test
    fun `cancelling the coroutine cancels the request`() = runBlocking {
        val call = HeldCall()
        val pending = async(Dispatchers.Default, CoroutineStart.UNDISPATCHED) { call.await() }
        pending.cancel()
        pending.join()
        assertTrue(call.cancelled)
    }

    @Test
    fun `a failure is thrown`() = runBlocking {
        val call = HeldCall()
        val pending = async(Dispatchers.Default, CoroutineStart.UNDISPATCHED) { runCatching { call.await() } }
        call.callback!!.onFailure(call, IOException("offline"))
        assertEquals("offline", pending.await().exceptionOrNull()?.message)
    }
}
