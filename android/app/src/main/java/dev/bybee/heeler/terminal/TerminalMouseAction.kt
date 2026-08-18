// Adapted from chuchu (MIT, jossephus, commit 73dfe07); see android/native/NOTICE.md.
package dev.bybee.heeler.terminal

import dev.bybee.heeler.core.terminal.NativeTerminal

/** Native ghostty mouse action values accepted by [NativeTerminal.encodeMouse]. */
object TerminalMouseAction {
    const val Press: Int = 0
    const val Release: Int = 1
    const val Motion: Int = 2
}
