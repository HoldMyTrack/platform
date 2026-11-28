package dev.holdmytrack.android

/** [this] without the leading and trailing characters of Unicode's White_Space, as iOS trims them
 *  (`.whitespacesAndNewlines`), so the shared rules' cases hold on both apps: Kotlin's
 *  [Char.isWhitespace] also counts the separators U+001C–U+001F and misses U+0085. */
fun String.trimWhiteSpace(): String = trim { c -> c == '\u0085' || (c.isWhitespace() && c !in '\u001c'..'\u001f') }
