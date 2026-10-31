package dev.holdmytrack.android.net

import okhttp3.Response

/**
 * [response]'s body as text, closing it, or the failure reading it. OkHttp calls `onResponse` once
 * the headers are in; a connection that drops in the body then throws there, where OkHttp only
 * logs an `IOException` and never calls `onFailure`, and any other exception takes the app down.
 * A callback that reads through this always answers.
 */
internal fun readBody(response: Response): Result<String> =
    try {
        Result.success(response.use { it.body?.string().orEmpty() })
    } catch (e: Exception) {
        Result.failure(e)
    }

/** Whether a DELETE's [status] means the thing is gone: deleted now, or already (`404`, removed on
 *  the web or another device). The web's `apiError.ts`; both run `testdata/client-rules`. */
internal fun deleteDone(status: Int): Boolean = status in 200..299 || status == 404

/** A DELETE's [result], done when [deleteDone] says so. */
internal fun deleteDone(result: Result<Unit>): Result<Unit> {
    val refusal = result.exceptionOrNull() as? ApiException ?: return result
    return if (deleteDone(refusal.code)) Result.success(Unit) else result
}