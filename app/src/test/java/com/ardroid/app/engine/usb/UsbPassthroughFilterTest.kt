package com.ardroid.app.engine.usb

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UsbPassthroughFilterTest {

    // Literal USB class codes: local unit tests run against the stubbed
    // android.jar, where UsbConstants fields are all 0.
    private companion object {
        const val HID = 3
        const val MASS_STORAGE = 8
        const val AUDIO = 1
        const val VENDOR_SPEC = 255
    }

    @Test
    fun `wifi adapter passes through`() {
        assertTrue(UsbPassthroughManager.isPassthroughCandidate(0, listOf(VENDOR_SPEC)))
    }

    @Test
    fun `mass storage passes through`() {
        assertTrue(UsbPassthroughManager.isPassthroughCandidate(0, listOf(MASS_STORAGE)))
    }

    @Test
    fun `keyboard stays with Android`() {
        assertFalse(UsbPassthroughManager.isPassthroughCandidate(0, listOf(HID)))
    }

    @Test
    fun `composite device with any HID interface stays with Android`() {
        // A dock exposing keyboard + trackpad alongside audio: passing it through
        // would take the dock's input away from Android.
        assertFalse(
            UsbPassthroughManager.isPassthroughCandidate(
                0,
                listOf(AUDIO, HID, AUDIO),
            )
        )
    }

    @Test
    fun `device-level HID class stays with Android`() {
        assertFalse(UsbPassthroughManager.isPassthroughCandidate(HID, emptyList()))
    }
}
