/*
 * ArDroid - Rootless Podman for Android
 * Copyright (C) 2024-2026 ArDroid contributors
 */
package com.ardroid.app.util

object ShellQuote {
    fun quote(s: String): String =
        if (s.isEmpty()) "''"
        else if (s.none { it.isWhitespace() || it in "'\"\\$`" }) s
        else "'" + s.replace("'", "'\\''") + "'"
}
