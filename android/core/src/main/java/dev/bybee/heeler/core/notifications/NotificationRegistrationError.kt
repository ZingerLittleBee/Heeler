package dev.bybee.heeler.core.notifications

/**
 * Why Notification Registration failed. A closed taxonomy lets callers
 * distinguish "install the plugin" from a broken read/write without matching
 * error strings. Transport connection failures remain TransportError.
 */
sealed class NotificationRegistrationError(message: String) : Exception(message) {
    /** The Heeler plugin is absent or disabled, so no Host process would read it. */
    data object PluginNotInstalled : NotificationRegistrationError("The Heeler plugin is not installed.")

    /** Plugin list/config-dir probing failed or produced invalid output. */
    data class PluginProbeFailed(val detail: String) : NotificationRegistrationError(detail)

    /** The registration/config file could not be read. */
    data class ReadFailed(val detail: String) : NotificationRegistrationError(detail)

    /** The registration/config file could not be atomically replaced. */
    data class WriteFailed(val detail: String) : NotificationRegistrationError(detail)

    /** A newer registration-file version cannot safely be overwritten. */
    data class UnsupportedFileVersion(val version: Int) : NotificationRegistrationError(
        "Unsupported notification registration version $version.",
    )
}
