package dev.holdmytrack.android.net

import java.io.IOException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Response

/**
 * Sends the call on OkHttp's dispatcher and suspends until it answers. Cancelling the coroutine
 * cancels the call, so leaving the Sync tab stops a request still being sent, and a loop of
 * requests stops between them; a request the server has already taken in whole is still
 * processed there. An answer that arrives after the cancellation is closed. Uploads run in
 * `FileImports`' own scope, so they carry on when the Upload screen is left.
 */
suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) {
            continuation.resume(response) { _, value, _ -> value.close() }
        }

        override fun onFailure(call: Call, e: IOException) {
            if (!continuation.isCancelled) continuation.resumeWith(Result.failure(e))
        }
    })
}
