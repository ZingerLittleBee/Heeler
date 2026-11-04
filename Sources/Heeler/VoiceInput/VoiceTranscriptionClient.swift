import Foundation

/// One recording on its way to a speech service.
struct VoiceTranscriptionRequest: Sendable {
    let endpoint: VoiceInputEndpoint
    let apiKey: String
    /// 16 kHz mono 16-bit WAV.
    let audio: Data
    let primaryLanguage: String
    /// Names and terms to spell, already split and cleaned.
    let keywords: [String]
    /// What recordings are about, trimmed; empty when unset.
    let prompt: String
}

/// Why a transcription produced no text, in words the Composer can show.
enum VoiceTranscriptionError: Error, Equatable, Sendable {
    case unauthorized(String?)
    case rejected(status: Int, message: String?)
    case unavailable(status: Int, message: String?)
    /// A redirect is refused rather than followed: it would resend the
    /// recording to a host the user never confirmed.
    case redirected(to: String?)
    case emptyTranscript
    case unreadableResponse
    case timedOut
    case network(String)

    var message: String {
        switch self {
        case .unauthorized(let detail):
            Self.joined("The speech service rejected the API key.", detail)
        case .rejected(let status, let detail):
            Self.joined("The speech service refused the recording (HTTP \(status)).", detail)
        case .unavailable(let status, let detail):
            Self.joined("The speech service is unavailable (HTTP \(status)).", detail)
        case .redirected(let host):
            if let host {
                "The speech service redirected to \(host). Voice Input does not follow redirects; check the URL."
            } else {
                "The speech service redirected the request. Voice Input does not follow redirects; check the URL."
            }
        case .emptyTranscript:
            "No speech was recognized."
        case .unreadableResponse:
            "The speech service sent a response Voice Input could not read."
        case .timedOut:
            "The speech service took too long to answer."
        case .network(let detail):
            Self.joined("Couldn't reach the speech service.", detail)
        }
    }

    /// Whether the fix is in Voice Input's settings.
    var suggestsSettings: Bool {
        switch self {
        case .unauthorized, .redirected:
            true
        case .rejected(let status, _):
            status == 404
        default:
            false
        }
    }

    private static func joined(_ summary: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return summary }
        return "\(summary) \(detail)"
    }
}

/// The network boundary, so the request and its handling are tested without
/// a server.
protocol VoiceTranscriptionHTTP: Sendable {
    func upload(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse)
}

/// An ephemeral session: no cookies, cache, or credential storage. Every
/// redirect is refused (`VoiceTranscriptionRedirectRefusal`).
struct URLSessionVoiceTranscriptionHTTP: VoiceTranscriptionHTTP {
    private let session: URLSession

    /// `protocolClasses` lets tests answer in place of a server.
    init(protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
    }

    func upload(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.upload(
            for: request, from: body, delegate: VoiceTranscriptionRedirectRefusal())
        guard let http = response as? HTTPURLResponse else {
            throw VoiceTranscriptionError.unreadableResponse
        }
        return (data, http)
    }
}

/// Declining a redirect hands back the 3xx response itself. URLSession would
/// otherwise resend the multipart body on 307 and 308.
final class VoiceTranscriptionRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

struct VoiceTranscriptionClient: Sendable {
    let http: any VoiceTranscriptionHTTP

    init(http: any VoiceTranscriptionHTTP = URLSessionVoiceTranscriptionHTTP()) {
        self.http = http
    }

    func transcribe(_ request: VoiceTranscriptionRequest) async throws -> String {
        let (urlRequest, body) = Self.makeRequest(request)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.upload(urlRequest, body: body)
        } catch let error as VoiceTranscriptionError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw VoiceTranscriptionError.timedOut }
            throw VoiceTranscriptionError.network(error.localizedDescription)
        }
        return try Self.transcript(from: data, response: response)
    }

    static func makeRequest(
        _ request: VoiceTranscriptionRequest,
        boundary: String = "heeler-\(UUID().uuidString)"
    ) -> (URLRequest, Data) {
        var urlRequest = URLRequest(url: request.endpoint.transcriptionURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 90
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = multipartBody(
            boundary: boundary, fields: fields(for: request), audio: request.audio)
        return (urlRequest, body)
    }

    /// Form fields besides the file, in order.
    static func fields(for request: VoiceTranscriptionRequest) -> [(name: String, value: String)] {
        var fields: [(name: String, value: String)] = [("model", request.endpoint.model)]
        switch request.endpoint.languageField {
        case .none:
            break
        case .primary:
            fields.append(("language", request.primaryLanguage))
        case .candidates:
            for language in VoiceInputLanguage.candidates(primary: request.primaryLanguage) {
                fields.append(("languages[]", language))
            }
        }
        if request.endpoint.takesKeywords {
            fields += request.keywords.map { ("keywords[]", $0) }
            if !request.prompt.isEmpty {
                fields.append(("prompt", request.prompt))
            }
        } else if let prompt = prompt(request.prompt, folding: request.keywords) {
            fields.append(("prompt", prompt))
        }
        if request.endpoint.sendsResponseFormat {
            fields.append(("response_format", "json"))
        }
        return fields
    }

    /// The prompt for a service without `keywords`: the user's prompt, then
    /// the terms on a `Vocabulary:` line, the form Qwen3-ASR's model card
    /// gives and a glossary Whisper-style servers read as prior text.
    static func prompt(_ prompt: String, folding keywords: [String]) -> String? {
        var lines: [String] = []
        if !prompt.isEmpty { lines.append(prompt) }
        if !keywords.isEmpty { lines.append("Vocabulary: " + keywords.joined(separator: ", ")) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func multipartBody(
        boundary: String,
        fields: [(name: String, value: String)],
        audio: Data
    ) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for field in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            append("\(field.value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    static func transcript(from data: Data, response: HTTPURLResponse) throws -> String {
        let status = response.statusCode
        switch status {
        case 200..<300:
            let text: String
            if let decoded = try? JSONDecoder().decode(TranscriptBody.self, from: data) {
                text = decoded.text
            } else if isPlainText(response), let plain = String(data: data, encoding: .utf8) {
                text = plain
            } else {
                throw VoiceTranscriptionError.unreadableResponse
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw VoiceTranscriptionError.emptyTranscript }
            return trimmed
        case 300..<400:
            let location = response.value(forHTTPHeaderField: "Location")
                .flatMap { URL(string: $0, relativeTo: response.url)?.host() }
            throw VoiceTranscriptionError.redirected(to: location)
        case 401, 403:
            throw VoiceTranscriptionError.unauthorized(errorMessage(in: data))
        case 408, 429, 500..<600:
            throw VoiceTranscriptionError.unavailable(status: status, message: errorMessage(in: data))
        default:
            throw VoiceTranscriptionError.rejected(status: status, message: errorMessage(in: data))
        }
    }

    /// OpenAI-style `{"error":{"message":…}}`, plus the shapes other hosts
    /// use: `{"error":"…"}`, `{"message":…}`, `{"detail":…}`.
    static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let candidates: [Any?] = [
            (object["error"] as? [String: Any])?["message"],
            object["error"],
            object["message"],
            object["detail"],
        ]
        for candidate in candidates {
            if let text = candidate as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                return String(trimmed.prefix(240))
            }
        }
        return nil
    }

    private static func isPlainText(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/plain")
            ?? false
    }

    private struct TranscriptBody: Decodable {
        let text: String
    }
}
