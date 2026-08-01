package com.bbflight.background_downloader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Cross-language contract test: these golden vectors are asserted identically
 * in test/resume_data_cleanup_test.dart. The Kotlin and Dart implementations
 * of partFileSuffix must never diverge, because the Dart orphan scan
 * reconstructs Android-created part file paths from destination and taskId.
 */
class PartFileSuffixTest {

    @Test
    fun goldenVectors() {
        assertEquals("811c9dc5", partFileSuffix(""))
        assertEquals("e40c292c", partFileSuffix("a"))
        assertEquals("bf9cf968", partFileSuffix("foobar"))
    }

    @Test
    fun uniquePerTaskId() {
        assertEquals(
            partialDownloadFilePath("/dir/file.bin", "A"),
            partialDownloadFilePath("/dir/file.bin", "A")
        )
        assertNotEquals(
            partialDownloadFilePath("/dir/file.bin", "A"),
            partialDownloadFilePath("/dir/file.bin", "B")
        )
    }

    @Test
    fun pathFormat() {
        assertEquals(
            "/dir/file.bin.bf9cf968.part",
            partialDownloadFilePath("/dir/file.bin", "foobar")
        )
    }
}
