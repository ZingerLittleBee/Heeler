package dev.bybee.heeler.core.transport

import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull

/**
 * Canonical event kind: the dotted name (`pane.created`) as herdr's
 * subscription API spells it. Event lines arrive snake_case (`pane_created`);
 * [fromWireName] maps either spelling here, so consumers only see one naming.
 */
data class HerdrEventKind(val name: String) {
    companion object {
        /** All kinds herdr 0.8.0's schema declares subscribable. */
        val known: List<HerdrEventKind>
            get() = GlobalEventKind.entries.map { it.kind } +
                PaneEventKind.entries.map { it.kind } +
                paneOutputMatched

        /**
         * `pane.output_matched` is subscribable only with a full output-match
         * query (`source` + `match`; the server rejects a bare pane id). M0
         * does not subscribe to it, but its events still decode canonically.
         */
        val paneOutputMatched = HerdrEventKind("pane.output_matched")

        /**
         * Synthetic, local-only kind: stands in for updates a bounded event
         * buffer shed under overflow. It is never sent by herdr and is not
         * subscribable. Consumers treat it like a membership event and
         * re-snapshot because deltas may be missing.
         */
        val eventsDropped = HerdrEventKind("local.events_dropped")

        private val byWireName: Map<String, HerdrEventKind> = buildMap {
            known.forEach { kind ->
                put(kind.name, kind)
                put(kind.name.replace('.', '_'), kind)
            }
        }

        /**
         * Maps a dotted or snake_case wire spelling onto a canonical kind.
         * Unknown names pass through untouched: herdr's API has no stability
         * guarantee, so an unknown kind must not be guess-mangled or kill the
         * stream.
         */
        fun fromWireName(wireName: String): HerdrEventKind =
            byWireName[wireName] ?: HerdrEventKind(wireName)
    }
}

/** Host-wide subscription kinds, subscribed with no parameters. */
enum class GlobalEventKind(val wireName: String) {
    WORKSPACE_CREATED("workspace.created"),
    WORKSPACE_UPDATED("workspace.updated"),
    WORKSPACE_METADATA_UPDATED("workspace.metadata_updated"),
    WORKSPACE_RENAMED("workspace.renamed"),
    WORKSPACE_MOVED("workspace.moved"),
    /**
     * Added in protocol 19. Declared so it decodes canonically, but left out
     * of membership projections: reordering changes no membership or label.
     */
    WORKSPACE_REORDERED("workspace.reordered"),
    WORKSPACE_CLOSED("workspace.closed"),
    WORKSPACE_FOCUSED("workspace.focused"),
    WORKTREE_CREATED("worktree.created"),
    WORKTREE_OPENED("worktree.opened"),
    WORKTREE_REMOVED("worktree.removed"),
    TAB_CREATED("tab.created"),
    TAB_CLOSED("tab.closed"),
    TAB_FOCUSED("tab.focused"),
    TAB_RENAMED("tab.renamed"),
    TAB_MOVED("tab.moved"),
    PANE_CREATED("pane.created"),
    PANE_CLOSED("pane.closed"),
    PANE_UPDATED("pane.updated"),
    PANE_FOCUSED("pane.focused"),
    PANE_MOVED("pane.moved"),
    PANE_EXITED("pane.exited"),
    PANE_AGENT_DETECTED("pane.agent_detected"),
    LAYOUT_UPDATED("layout.updated"),
    ;

    val kind: HerdrEventKind get() = HerdrEventKind(wireName)
}

/** Pane-scoped subscription kinds; their subscriptions carry a `pane_id`. */
enum class PaneEventKind(val wireName: String) {
    AGENT_STATUS_CHANGED("pane.agent_status_changed"),
    SCROLL_CHANGED("pane.scroll_changed"),
    ;

    val kind: HerdrEventKind get() = HerdrEventKind(wireName)
}

/** One entry in an `events.subscribe` request. */
sealed interface EventSubscription {
    data class Global(val kind: GlobalEventKind) : EventSubscription
    data class Pane(val kind: PaneEventKind, val paneID: String) : EventSubscription
}

/** One event from the Host's events channel, in canonical naming. */
data class HerdrEvent(
    val kind: HerdrEventKind,
    /** Raw payload; consumers select the fields they understand. */
    val data: JsonElement,
) {
    companion object {
        /**
         * The drop marker yielded when a bounded buffer sheds updates.
         * Snapshot-then-delta makes dropping safe only when the consumer learns
         * it happened; this marker provides that signal.
         */
        val eventsDropped = HerdrEvent(HerdrEventKind.eventsDropped, JsonNull)
    }
}

/**
 * A live `events.subscribe` flow over its Host's dedicated forwarding channel.
 * Ending is explicit: call [end]. Abandoning the flow leaves the forwarding
 * channel live until the SSH connection closes.
 */
class HerdrEventStream internal constructor(
    /** Events in arrival order. It completes after [end] or fails if the channel dies. */
    val events: Flow<HerdrEvent>,
    private val ender: suspend () -> Unit,
) {
    companion object {
        /**
         * Buffer bound for event delivery, sized for stall absorption rather
         * than history. Beyond this, one snapshot resync beats a stale backlog.
         */
        const val BUFFER_LIMIT = 256
    }

    /** Closes the events channel explicitly and waits for teardown. Idempotent. */
    suspend fun end() = ender()
}
