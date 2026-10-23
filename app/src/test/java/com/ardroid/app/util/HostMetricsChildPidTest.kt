package com.ardroid.app.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class HostMetricsChildPidTest {

    @get:Rule val tmp = TemporaryFolder()

    private val names = setOf("libpodroid-launcher.so", "libqemu-system-aarch64.so")

    private fun proc(pid: Int, ppid: Int, comm: String, argv0: String) {
        val dir = File(tmp.root, pid.toString()).apply { mkdirs() }
        File(dir, "stat").writeText("$pid ($comm) S $ppid $pid $pid 0 -1 4194560 0 0 0 0\n")
        File(dir, "cmdline").writeText("$argv0\u0000-m\u00002048\u0000")
    }

    @Test
    fun `finds the qemu child after exec`() {
        proc(100, 1, "app_process", "com.ardroid.app")
        proc(4321, 100, "libqemu-system-", "/data/app/x/lib/arm64/libqemu-system-aarch64.so")
        assertEquals(4321, HostMetrics.childPidByExecutable(100, names, tmp.root))
    }

    @Test
    fun `finds the launcher before it has exec'd qemu`() {
        proc(4321, 100, "libpodroid-laun", "/data/app/x/lib/arm64/libpodroid-launcher.so")
        assertEquals(4321, HostMetrics.childPidByExecutable(100, names, tmp.root))
    }

    @Test
    fun `ignores other children and other parents`() {
        // The terminal bridge is also a child of the app; a QEMU under another
        // parent is not ours.
        proc(200, 100, "libpodroid-brid", "/data/app/x/lib/arm64/libpodroid-bridge.so")
        proc(300, 999, "libqemu-system-", "/data/app/x/lib/arm64/libqemu-system-aarch64.so")
        assertNull(HostMetrics.childPidByExecutable(100, names, tmp.root))
    }

    @Test
    fun `comm containing spaces and parens does not break ppid parsing`() {
        proc(4321, 100, "odd ) name", "/data/app/x/lib/arm64/libqemu-system-aarch64.so")
        assertEquals(4321, HostMetrics.childPidByExecutable(100, names, tmp.root))
    }

    @Test
    fun `unreadable or vanished entries are skipped`() {
        File(tmp.root, "555").mkdirs() // no stat/cmdline: process exited mid-scan
        File(tmp.root, "self").mkdirs()
        proc(4321, 100, "libqemu-system-", "/data/app/x/lib/arm64/libqemu-system-aarch64.so")
        assertEquals(4321, HostMetrics.childPidByExecutable(100, names, tmp.root))
    }
}
