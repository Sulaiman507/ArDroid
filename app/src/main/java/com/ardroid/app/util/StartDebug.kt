package com.ardroid.app.util

import android.content.Context
import java.io.File

/**
 * TEMPORARY diagnostic (rebrand Start-VM investigation): appends stage
 * markers to filesDir/start-debug.txt so the exact point where the VM
 * start chain stops is visible in the exported diagnostic log, even if
 * the process dies between stages. Remove after the investigation.
 */
object StartDebug {
    fun mark(context: Context, stage: String) {
        try {
            val f = File(context.filesDir, "start-debug.txt")
            f.appendText("${System.currentTimeMillis()} $stage\n")
        } catch (_: Exception) {
        }
    }

    fun read(context: Context): String = try {
        File(context.filesDir, "start-debug.txt").readText()
    } catch (_: Exception) {
        "(no start-debug.txt)"
    }
}
