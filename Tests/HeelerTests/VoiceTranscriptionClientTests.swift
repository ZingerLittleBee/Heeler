import Foundation
import Synchronization
import Testing

@testable import Heeler

@Suite("Voice Input endpoints")
struct VoiceInputEndpointTests {
    struct URLCase: CustomTestStringConvertible, Sendable {
        let raw: String
        let expected: Result<String, VoiceInputCustomURL.Problem>
        var testDescription: String { raw.isEmpty ? "(empty)" : raw }
    }

    @Test(
        "Custom URLs normalize to an https base",
        arguments: [
            URLCase(raw: "https://api.example.com/v1", expected: .success("https://api.example.com/v1")),
            URLCase(raw: " https://API.Example.com/v1/ ", expected: .success("https://api.example.com/v1")),
            URLCase(
                raw: "https://api.example.com/v1/audio/transcriptions",
                expected: .success("https://api.example.com/v1")),
            URLCase(
                raw: "https://api.example.com/openai/Audio/Transcriptions/",
                expected: .success("https://api.example.com/openai")),
            URLCase(raw: "https://asr.example.com", expected: .success("https://asr.example.com")),
            URLCase(raw: "https://localhost:8443/v1", expected: .success("https://localhost:8443/v1")),
            URLCase(raw: "", expected: .failure(.empty)),
            URLCase(raw: "api.example.com/v1", expected: .failure(.invalid)),
            URLCase(raw: "http://api.example.com/v1", expected: .failure(.notHTTPS)),
            URLCase(raw: "https://user:secret@api.example.com/v1", expected: .failure(.containsCredentials)),
            URLCase(raw: "https://api.example.com/v1?key=abc", expected: .failure(.containsQueryOrFragment)),
            URLCase(raw: "https://api.example.com/v1#top", expected: .failure(.containsQueryOrFragment)),
        ])
    func customURLNormalization(_ urlCase: URLCase) {
        let result = VoiceInputCustomURL.normalize(urlCase.raw).map(\.absoluteString)
        #expect(result == urlCase.expected)
    }

    @Test func presetsPostToTheirTranscriptionEndpoints() throws {
        let openAI = try #require(VoiceInputEndpoint.preset(.openAI))
        let deepInfra = try #require(VoiceInputEndpoint.preset(.deepInfra))
        let siliconFlow = try #require(VoiceInputEndpoint.preset(.siliconFlowCN))
        #expect(openAI.transcriptionURL.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(
            deepInfra.transcriptionURL.absoluteString
                == "https://api.deepinfra.com/v1/openai/audio/transcriptions")
        #expect(
            siliconFlow.transcriptionURL.absoluteString
                == "https://api.siliconflow.cn/v1/audio/transcriptions")
        #expect(openAI.model == "gpt-transcribe")
        #expect(deepInfra.model == "Qwen/Qwen3-ASR-1.7B")
    }

    @Test func aCustomKeyBelongsToItsURLAndConsentToItsModel() throws {
        let first = try #require(try? VoiceInputCustomURL.normalize("https://a.example.com/v1").get())
        let second = try #require(try? VoiceInputCustomURL.normalize("https://b.example.com/v1").get())
        let a = VoiceInputEndpoint.custom(baseURL: first, model: "whisper-1", sendsLanguage: false)
        let aOtherModel = VoiceInputEndpoint.custom(baseURL: first, model: "large-v3", sendsLanguage: false)
        let b = VoiceInputEndpoint.custom(baseURL: second, model: "whisper-1", sendsLanguage: false)

        #expect(a.keyAccount == aOtherModel.keyAccount)
        #expect(a.keyAccount != b.keyAccount)
        #expect(a.consentID != aOtherModel.consentID)
        #expect(a.consentID != b.consentID)
        #expect(!a.keyAccount.contains("example"), "the account does not spell out the URL")
    }

    @Test func languagesPutTheSystemsFirstLanguageBeforeEnglish() {
        #expect(VoiceInputLanguage.primary(preferredLanguages: ["zh-Hans-CN", "en-US"]) == "zh")
        #expect(VoiceInputLanguage.primary(preferredLanguages: ["ja-JP"]) == "ja")
        #expect(VoiceInputLanguage.primary(preferredLanguages: []) == "en")
        #expect(VoiceInputLanguage.candidates(primary: "zh") == ["zh", "en"])
        #expect(VoiceInputLanguage.candidates(primary: "en") == ["en"])
    }
}

@Suite("Voice transcription client")
struct VoiceTranscriptionClientTests {
    private let audio = Data("RIFF-audio".utf8)

    private func request(
        _ endpoint: VoiceInputEndpoint, language: String = "zh", keywords: [String] = [],
        prompt: String = ""
    ) -> VoiceTranscriptionRequest {
        VoiceTranscriptionRequest(
            endpoint: endpoint, apiKey: "sk-test", audio: audio, primaryLanguage: language,
            keywords: keywords, prompt: prompt)
    }

    private func fieldNames(
        _ endpoint: VoiceInputEndpoint, keywords: [String] = [], prompt: String = ""
    ) -> [String] {
        VoiceTranscriptionClient.fields(for: request(endpoint, keywords: keywords, prompt: prompt))
            .map { "\($0.name)=\($0.value)" }
    }

    @Test func eachPresetNamesItsLanguagesTheWayItsServiceAccepts() throws {
        // gpt-transcribe answers 400 when `language` comes with `languages`.
        #expect(
            fieldNames(try #require(VoiceInputEndpoint.preset(.openAI)))
                == ["model=gpt-transcribe", "languages[]=zh", "languages[]=en"])
        #expect(
            fieldNames(try #require(VoiceInputEndpoint.preset(.deepInfra))) == ["model=Qwen/Qwen3-ASR-1.7B", "language=zh"])
        #expect(fieldNames(try #require(VoiceInputEndpoint.preset(.siliconFlowCN))) == ["model=Qwen/Qwen3-ASR-1.7B"])
    }

    @Test func keywordsGoOnlyWhereTheServiceReadsThemAndThePromptAsWritten() throws {
        let terms = ["herdr", "Heeler"]
        let about = "Instructions to a coding agent\nVocabulary: herdr"
        let openAI = try #require(VoiceInputEndpoint.preset(.openAI))
        #expect(
            fieldNames(openAI, keywords: terms, prompt: about)
                == [
                    "model=gpt-transcribe", "languages[]=zh", "languages[]=en",
                    "keywords[]=herdr", "keywords[]=Heeler", "prompt=\(about)",
                ])
        #expect(
            fieldNames(try #require(VoiceInputEndpoint.preset(.deepInfra)), keywords: terms, prompt: about)
                == ["model=Qwen/Qwen3-ASR-1.7B", "language=zh", "prompt=\(about)"])
        #expect(
            fieldNames(try #require(VoiceInputEndpoint.preset(.siliconFlowCN)), keywords: terms, prompt: about)
                == ["model=Qwen/Qwen3-ASR-1.7B", "prompt=\(about)"])
        let base = try #require(try? VoiceInputCustomURL.normalize("https://asr.example.com/v1").get())
        let custom = VoiceInputEndpoint.custom(baseURL: base, model: "whisper-1", sendsLanguage: false)
        #expect(
            fieldNames(custom, keywords: terms, prompt: about)
                == ["model=whisper-1", "prompt=\(about)", "response_format=json"])
        #expect(fieldNames(custom, keywords: terms) == ["model=whisper-1", "response_format=json"])
    }

    @Test func customAsksForJSONAndSendsLanguageOnlyWhenOn() throws {
        let base = try #require(try? VoiceInputCustomURL.normalize("https://asr.example.com/v1").get())
        #expect(
            fieldNames(.custom(baseURL: base, model: "whisper-1", sendsLanguage: false))
                == ["model=whisper-1", "response_format=json"])
        #expect(
            fieldNames(.custom(baseURL: base, model: "whisper-1", sendsLanguage: true))
                == ["model=whisper-1", "language=zh", "response_format=json"])
    }

    @Test func theRequestCarriesTheKeyAndTheRecordingAsOneMultipartBody() throws {
        let endpoint = try #require(VoiceInputEndpoint.preset(.openAI))
        let (urlRequest, body) = VoiceTranscriptionClient.makeRequest(request(endpoint), boundary: "B")

        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=B")
        let text = String(decoding: body, as: UTF8.self)
        #expect(
            text == "--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n"
                + "--B\r\nContent-Disposition: form-data; name=\"languages[]\"\r\n\r\nzh\r\n"
                + "--B\r\nContent-Disposition: form-data; name=\"languages[]\"\r\n\r\nen\r\n"
                + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\n"
                + "Content-Type: audio/wav\r\n\r\nRIFF-audio\r\n--B--\r\n")
    }

    struct ResponseCase: CustomTestStringConvertible, Sendable {
        let name: String
        let status: Int
        let body: String
        var headers: [String: String] = ["Content-Type": "application/json"]
        let expected: Result<String, VoiceTranscriptionError>
        var testDescription: String { name }
    }

    @Test(
        "Responses map to text or a failure",
        arguments: [
            ResponseCase(
                name: "JSON text", status: 200, body: #"{"text":" 把这个 useEffect 改一下。 ","usage":{}}"#,
                expected: .success("把这个 useEffect 改一下。")),
            ResponseCase(
                name: "plain text", status: 200, body: "hello there\n",
                headers: ["Content-Type": "text/plain; charset=utf-8"], expected: .success("hello there")),
            ResponseCase(name: "blank text", status: 200, body: #"{"text":"  "}"#, expected: .failure(.emptyTranscript)),
            ResponseCase(name: "not JSON", status: 200, body: "<html>", expected: .failure(.unreadableResponse)),
            ResponseCase(
                name: "bad key", status: 401,
                body: #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error"}}"#,
                expected: .failure(.unauthorized("Incorrect API key provided."))),
            ResponseCase(
                name: "rejected", status: 400, body: #"{"error":"model not found"}"#,
                expected: .failure(.rejected(status: 400, message: "model not found"))),
            ResponseCase(
                name: "busy", status: 429, body: #"{"detail":"Rate limit"}"#,
                expected: .failure(.unavailable(status: 429, message: "Rate limit"))),
            ResponseCase(
                name: "redirect", status: 308, body: "",
                headers: ["Location": "https://other.example.com/v1/audio/transcriptions"],
                expected: .failure(.redirected(to: "other.example.com"))),
        ])
    func responseMapping(_ responseCase: ResponseCase) throws {
        let url = try #require(URL(string: "https://api.example.com/v1/audio/transcriptions"))
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: responseCase.status, httpVersion: "HTTP/1.1",
                headerFields: responseCase.headers))
        let result = Result {
            try VoiceTranscriptionClient.transcript(from: Data(responseCase.body.utf8), response: response)
        }.mapError { $0 as? VoiceTranscriptionError ?? .unreadableResponse }
        #expect(result == responseCase.expected)
    }

    @Test func networkFailuresBecomeTheirOwnMessages() async throws {
        let endpoint = try #require(VoiceInputEndpoint.preset(.openAI))
        let timedOut = VoiceTranscriptionClient(http: ThrowingHTTP(error: URLError(.timedOut)))
        await #expect(throws: VoiceTranscriptionError.timedOut) {
            try await timedOut.transcribe(request(endpoint))
        }
        let cancelled = VoiceTranscriptionClient(http: ThrowingHTTP(error: URLError(.cancelled)))
        await #expect(throws: CancellationError.self) {
            try await cancelled.transcribe(request(endpoint))
        }
    }

    /// The recording and key must never follow a redirect: URLSession would
    /// resend the body on 307 and 308.
    @Test func aRedirectIsRefusedAndNothingReachesItsTarget() async throws {
        RedirectingProtocol.requestedHosts.withLock { $0.removeAll() }
        let base = try #require(try? VoiceInputCustomURL.normalize("https://asr.heeler-test.invalid/v1").get())
        let client = VoiceTranscriptionClient(
            http: URLSessionVoiceTranscriptionHTTP(protocolClasses: [RedirectingProtocol.self]))

        await #expect(throws: VoiceTranscriptionError.redirected(to: "elsewhere.heeler-test.invalid")) {
            try await client.transcribe(
                request(.custom(baseURL: base, model: "whisper-1", sendsLanguage: false)))
        }
        #expect(RedirectingProtocol.requestedHosts.withLock { $0 } == ["asr.heeler-test.invalid"])
    }
}

private struct ThrowingHTTP: VoiceTranscriptionHTTP {
    let error: URLError

    func upload(_: URLRequest, body _: Data) async throws -> (Data, HTTPURLResponse) {
        throw error
    }
}

/// Answers every request to the speech host with a 307 elsewhere, and
/// records each host a request reached.
private final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    static let requestedHosts = Mutex<[String]>([])

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.requestedHosts.withLock { $0.append(url.host() ?? "") }
        guard url.host() == "asr.heeler-test.invalid" else {
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"text":"leaked"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let target = URL(string: "https://elsewhere.heeler-test.invalid/v1/audio/transcriptions")!
        let response = HTTPURLResponse(
            url: url, statusCode: 307, httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString])!
        var redirected = request
        redirected.url = target
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
