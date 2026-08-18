package dev.bybee.heeler.core.transport

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * herdr's NDJSON wire format: request `{"id","method","params"}` + `\\n`,
 * success `{"id","result"}`, failure `{"id","error":{"code","message"}}`.
 * One request per connection; decoding is lenient because herdr's API has no
 * stability guarantee.
 */
object HerdrWire {
    internal val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = false
    }

    /** The empty `params` object herdr requires on parameterless methods. */
    @Serializable
    data object EmptyParams

    /** Encodes a parameterless request, including its required empty params object. */
    fun requestLine(id: String, method: String): ByteArray =
        requestLine(id, method, EmptyParams, EmptyParams.serializer())

    /** Encodes one request line with its required params payload. */
    fun <P> requestLine(
        id: String,
        method: String,
        params: P,
        paramsSerializer: KSerializer<P>,
    ): ByteArray = try {
        json.encodeToString(
            buildJsonObject {
                put("id", id)
                put("method", method)
                put("params", json.encodeToJsonElement(paramsSerializer, params))
            },
        ).plus("\n").encodeToByteArray()
    } catch (failure: Exception) {
        throw TransportError.MalformedResponse("failed to encode request for $method: $failure")
    }

    /**
     * Encodes `events.subscribe`. Subscription kinds use canonical dotted
     * spellings and pane-scoped entries carry the required `pane_id`.
     */
    fun subscribeRequestLine(id: String, subscriptions: List<EventSubscription>): ByteArray =
        json.encodeToString(
            buildJsonObject {
                put("id", id)
                put("method", "events.subscribe")
                put("params", buildJsonObject {
                    put("subscriptions", buildJsonArray {
                        subscriptions.forEach { subscription ->
                            add(buildJsonObject {
                                when (subscription) {
                                    is EventSubscription.Global -> put("type", subscription.kind.wireName)
                                    is EventSubscription.Pane -> {
                                        put("type", subscription.kind.wireName)
                                        put("pane_id", subscription.paneID)
                                    }
                                }
                            })
                        }
                    })
                })
            },
        ).plus("\n").encodeToByteArray()

    /**
     * Decodes one events-channel line. Anything that is not an event line is
     * dropped, never fatal: junk on the stream must not kill the subscription.
     */
    fun decodeEvent(line: ByteArray): HerdrEvent? = try {
        val objectValue = json.parseToJsonElement(line.decodeToString()).jsonObject
        val event = objectValue["event"]?.jsonPrimitive?.contentOrNull ?: return null
        HerdrEvent(
            HerdrEventKind.fromWireName(event),
            objectValue["data"] ?: JsonNull,
        )
    } catch (_: Exception) {
        null
    }

    /**
     * Decodes one response line, checks id correlation, and either returns its
     * result or throws the server's structured error.
     *
     * Each herdr API connection serves one request, so the response is always
     * for its sole in-flight request. Success still requires an exact id.
     * Errors do not: malformed requests are answered with `id: ""`, and
     * `events.subscribe` probe failures use a derived id. Without this fallback
     * those requests would pend until deadline instead of surfacing rejection.
     */
    fun <R> decodeResult(
        responseLine: ByteArray,
        requestID: String,
        resultSerializer: KSerializer<R>,
    ): R {
        val line = responseLine.takeBeforeNewline()
        val envelope = try {
            json.decodeFromString(ResponseEnvelope.serializer(), line.decodeToString())
        } catch (_: Exception) {
            throw TransportError.MalformedResponse(
                "undecodable response line: ${line.copyOfRange(0, minOf(200, line.size)).decodeToString()}",
            )
        }
        envelope.error?.let { error ->
            if (envelope.id != requestID && envelope.id != "") {
                throw TransportError.MalformedResponse(
                    "response id ${envelope.id ?: "<none>"} does not match request id $requestID",
                )
            }
            throw HerdrApiError(
                code = error.code.jsonPrimitive.contentOrNull ?: error.code.toString(),
                serverMessage = error.message,
            )
        }
        if (envelope.id != requestID) {
            throw TransportError.MalformedResponse(
                "response id ${envelope.id ?: "<none>"} does not match request id $requestID",
            )
        }
        val result = envelope.result
            ?: throw TransportError.MalformedResponse("response has neither result nor error")
        return try {
            json.decodeFromJsonElement(resultSerializer, result)
        } catch (_: Exception) {
            throw TransportError.MalformedResponse("response result could not be decoded")
        }
    }

    @Serializable
    private data class ResponseEnvelope(
        val id: String? = null,
        val result: JsonElement? = null,
        val error: ErrorEnvelope? = null,
    )

    @Serializable
    private data class ErrorEnvelope(
        val code: JsonElement,
        val message: String,
    )
}

private fun ByteArray.takeBeforeNewline(): ByteArray {
    val newline = indexOf('\n'.code.toByte())
    return if (newline < 0) this else copyOfRange(0, newline)
}
