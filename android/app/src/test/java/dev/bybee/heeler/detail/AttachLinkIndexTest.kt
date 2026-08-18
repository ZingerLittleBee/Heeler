package dev.bybee.heeler.detail

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AttachLinkIndexTest {
    @Test
    fun indexesAUrlSplitAcrossPtyChunksAndStripsAnsiStyling() {
        val index = AttachLinkIndex()

        index.receive("open https://exam".encodeToByteArray())
        index.receive("\u001B[31mple.test/path?x=1\u001B[0m now".encodeToByteArray())

        assertEquals(listOf("https://example.test/path?x=1"), index.links.map(AttachLink::target))
    }

    @Test
    fun indexesOsc8TargetWithoutIndexingItsLabel() {
        val index = AttachLinkIndex()

        index.receive("\u001B]8;;https://example.test/docs\u0007documentation\u001B]8;;\u0007".encodeToByteArray())

        assertEquals(listOf("https://example.test/docs"), index.links.map(AttachLink::target))
    }

    @Test
    fun retainsTwentyDistinctLinksAndMovesARepeatToTheFront() {
        val index = AttachLinkIndex()
        repeat(21) { index.receive("https://example$it.test ".encodeToByteArray()) }
        index.receive("https://example1.test ".encodeToByteArray())

        assertEquals(20, index.links.size)
        assertEquals("https://example1.test", index.links.first().target)
        assertTrue(index.links.none { it.target == "https://example0.test" })
    }

    @Test
    fun removesViewportOnlyPrefixWhenStreamObservesTheCompleteUrl() {
        val index = AttachLinkIndex()

        index.receiveViewportText("https://example.test/path")
        index.receive("https://example.test/path/complete ".encodeToByteArray())

        assertEquals(listOf("https://example.test/path/complete"), index.links.map(AttachLink::target))
    }
}
