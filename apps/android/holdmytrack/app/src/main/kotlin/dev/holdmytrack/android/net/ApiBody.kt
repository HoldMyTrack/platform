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