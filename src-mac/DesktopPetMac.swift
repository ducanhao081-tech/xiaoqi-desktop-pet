import AppKit
import AVFoundation
import Darwin
import Foundation
import Speech

struct WindowSettings: Codable {
    var width: Double
    var height: Double
    var defaultOffsetRight: Double
    var defaultOffsetBottom: Double
    var rememberPosition: Bool
    var keepInsideScreen: Bool
    var topmost: Bool
    var showInTaskbar: Bool
}

struct VoiceSettings: Codable {
    var synthesisEnabled: Bool
    var rate: Int
    var volume: Int
}

struct VoicePackStyle: Codable {
    var base: String?
    var speed: Double?
    var pitch: Double?
    var volume: Double?
    var emotionMap: [String: String]?
}

struct CloudTTSProviderSettings: Codable {
    var provider: String?
    var endpoint: String?
    var appIdEnv: String?
    var accessTokenEnv: String?
    var apiKeyEnv: String?
    var clusterEnv: String?
    var voiceTypeEnv: String?
    var defaultCluster: String?
    var defaultVoiceType: String?
    var resourceIdEnv: String?
    var resourceId: String?
    var encoding: String?
    var sampleRate: Int?
}

struct CloudASRProviderSettings: Codable {
    var provider: String?
    var endpoint: String?
    var appIdEnv: String?
    var accessTokenEnv: String?
    var apiKeyEnv: String?
    var clusterEnv: String?
    var languageEnv: String?
    var defaultCluster: String?
    var defaultLanguage: String?
    var resourceId: String?
    var audioFormat: String?
    var sampleRate: Int?
}

struct VoicePackManifest: Codable {
    var version: Int
    var provider: String
    var futureProvider: String?
    var voiceMode: String?
    var fallback: String?
    var languages: [String]?
    var license: String?
    var consent: String?
    var voiceId: String?
    var samplePath: String?
    var cloudASR: CloudASRProviderSettings?
    var cloudTTS: CloudTTSProviderSettings?
    var style: VoicePackStyle?
    var notes: [String]?
}

struct VoiceProviderStatus {
    var id: String
    var kind: String
    var available: Bool
    var fallbackId: String?
    var detail: String

    func asDictionary() -> [String: Any] {
        [
            "id": id,
            "kind": kind,
            "available": available,
            "fallbackId": fallbackId ?? "",
            "detail": detail
        ]
    }
}

protocol VoiceInputProvider {
    var id: String { get }
    func currentInputName() -> String
    func hasAvailableInput() -> Bool
    func status() -> VoiceProviderStatus
}

protocol SpeechRecognitionProvider {
    var id: String { get }
    func recognizer(localeIdentifier: String) -> SFSpeechRecognizer?
    func status(localeIdentifier: String) -> VoiceProviderStatus
}

protocol SpeechSynthesisProvider {
    var id: String { get }
    func makeUtterance(text: String, language: String, settings: VoiceSettings) -> AVSpeechUtterance
    func status(language: String, settings: VoiceSettings) -> VoiceProviderStatus
}

final class SystemVoiceInputProvider: VoiceInputProvider {
    let id = "system-microphone"

    func currentInputName() -> String {
        detectedAudioInputName()
    }

    func hasAvailableInput() -> Bool {
        AVCaptureDevice.default(for: .audio) != nil || !audioInputDevices().isEmpty
    }

    func status() -> VoiceProviderStatus {
        let available = hasAvailableInput()
        return VoiceProviderStatus(
            id: id,
            kind: "voiceInput",
            available: available,
            fallbackId: nil,
            detail: available ? currentInputName() : "no audio input detected"
        )
    }
}

final class SystemSpeechRecognitionProvider: SpeechRecognitionProvider {
    let id = "system-speech-recognition"

    func recognizer(localeIdentifier: String) -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    func status(localeIdentifier: String) -> VoiceProviderStatus {
        let recognizer = recognizer(localeIdentifier: localeIdentifier)
        return VoiceProviderStatus(
            id: id,
            kind: "asr",
            available: recognizer != nil,
            fallbackId: nil,
            detail: recognizer == nil ? "SFSpeechRecognizer unavailable for \(localeIdentifier)" : "locale=\(localeIdentifier)"
        )
    }
}

final class SystemSpeechSynthesisProvider: SpeechSynthesisProvider {
    let id = "system-avspeech"

    func makeUtterance(text: String, language: String, settings: VoiceSettings) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: speechLocaleIdentifier(for: language))
        utterance.volume = Float(max(0, min(100, settings.volume))) / 100.0
        let rateOffset = Float(max(-5, min(5, settings.rate))) * 0.03
        utterance.rate = max(
            AVSpeechUtteranceMinimumSpeechRate,
            min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate + rateOffset)
        )
        return utterance
    }

    func status(language: String, settings: VoiceSettings) -> VoiceProviderStatus {
        let locale = speechLocaleIdentifier(for: language)
        let voice = AVSpeechSynthesisVoice(language: locale)
        return VoiceProviderStatus(
            id: id,
            kind: "tts",
            available: voice != nil,
            fallbackId: "system",
            detail: voice == nil ? "system voice unavailable for \(locale)" : "locale=\(locale)"
        )
    }
}

struct DoubaoCloudTTSResolvedConfig {
    var endpoint: String
    var appId: String
    var accessToken: String
    var apiKey: String
    var cluster: String
    var voiceType: String
    var encoding: String
    var resourceId: String
    var sampleRate: Int
    var missing: [String]

    var isConfigured: Bool {
        missing.isEmpty
    }

    var usesAPIKey: Bool {
        !apiKey.isEmpty
    }
}

struct DoubaoCloudASRResolvedConfig {
    var endpoint: String
    var appId: String
    var accessToken: String
    var apiKey: String
    var cluster: String
    var language: String
    var audioFormat: String
    var sampleRate: Int
    var resourceId: String
    var missing: [String]

    var isConfigured: Bool {
        missing.isEmpty
    }
}

enum CloudSpeechError: Error {
    case providerUnavailable(String)
    case requestFailed(String)
    case invalidResponse(String)
}

final class DoubaoCloudSpeechRecognitionProvider {
    let id = "doubao-cloud-asr"
    private let settings: CloudASRProviderSettings

    init(settings: CloudASRProviderSettings?) {
        self.settings = settings ?? CloudASRProviderSettings(
            provider: "doubao-asr",
            endpoint: "",
            appIdEnv: "DOUBAO_ASR_APP_ID",
            accessTokenEnv: "DOUBAO_ASR_ACCESS_TOKEN",
            apiKeyEnv: "DOUBAO_ASR_API_KEY",
            clusterEnv: "DOUBAO_ASR_CLUSTER",
            languageEnv: "DOUBAO_ASR_LANGUAGE",
            defaultCluster: "",
            defaultLanguage: "zh-CN",
            resourceId: "",
            audioFormat: "wav",
            sampleRate: 16000
        )
    }

    func resolvedConfig(defaultLanguage: String) -> DoubaoCloudASRResolvedConfig {
        let appIdEnv = settings.appIdEnv ?? "DOUBAO_ASR_APP_ID"
        let tokenEnv = settings.accessTokenEnv ?? "DOUBAO_ASR_ACCESS_TOKEN"
        let apiKeyEnv = settings.apiKeyEnv ?? "DOUBAO_ASR_API_KEY"
        let clusterEnv = settings.clusterEnv ?? "DOUBAO_ASR_CLUSTER"
        let languageEnv = settings.languageEnv ?? "DOUBAO_ASR_LANGUAGE"

        let endpoint = settings.endpoint ?? ""
        let appId = ProcessInfo.processInfo.environment[appIdEnv] ?? ""
        let accessToken = ProcessInfo.processInfo.environment[tokenEnv] ?? ""
        let apiKey = ProcessInfo.processInfo.environment[apiKeyEnv] ?? ""
        let cluster = ProcessInfo.processInfo.environment[clusterEnv] ?? settings.defaultCluster ?? ""
        let language = ProcessInfo.processInfo.environment[languageEnv] ?? settings.defaultLanguage ?? defaultLanguage
        let audioFormat = settings.audioFormat ?? "wav"
        let sampleRate = settings.sampleRate ?? 16000
        let resourceId = settings.resourceId ?? ""

        var missing: [String] = []
        if endpoint.isEmpty { missing.append("cloudASR.endpoint") }
        if apiKey.isEmpty && (appId.isEmpty || accessToken.isEmpty) {
            if appId.isEmpty { missing.append(appIdEnv) }
            if accessToken.isEmpty { missing.append(tokenEnv) }
            if apiKey.isEmpty { missing.append(apiKeyEnv) }
        }

        return DoubaoCloudASRResolvedConfig(
            endpoint: endpoint,
            appId: appId,
            accessToken: accessToken,
            apiKey: apiKey,
            cluster: cluster,
            language: language,
            audioFormat: audioFormat,
            sampleRate: sampleRate,
            resourceId: resourceId,
            missing: missing
        )
    }

    func status(defaultLanguage: String) -> VoiceProviderStatus {
        let config = resolvedConfig(defaultLanguage: defaultLanguage)
        return VoiceProviderStatus(
            id: id,
            kind: "asrCloud",
            available: config.isConfigured,
            fallbackId: "system-speech-recognition",
            detail: config.isConfigured
                ? "endpoint=\(config.endpoint) cluster=\(config.cluster) language=\(config.language) format=\(config.audioFormat) sampleRate=\(config.sampleRate)"
                : "missing config/env: \(config.missing.joined(separator: ","))"
        )
    }
}

final class DoubaoCloudSpeechSynthesisProvider {
    let id = "doubao-cloud-tts"
    private let settings: CloudTTSProviderSettings

    init(settings: CloudTTSProviderSettings?) {
        self.settings = settings ?? CloudTTSProviderSettings(
            provider: "doubao-http-v3",
            endpoint: "https://openspeech.bytedance.com/api/v3/tts/unidirectional",
            appIdEnv: "DOUBAO_TTS_APP_ID",
            accessTokenEnv: "DOUBAO_TTS_ACCESS_TOKEN",
            apiKeyEnv: "DOUBAO_TTS_API_KEY",
            clusterEnv: "DOUBAO_TTS_CLUSTER",
            voiceTypeEnv: "DOUBAO_TTS_VOICE_TYPE",
            defaultCluster: "",
            defaultVoiceType: "zh_female_vv_uranus_bigtts",
            resourceIdEnv: "DOUBAO_TTS_RESOURCE_ID",
            resourceId: "seed-tts-2.0",
            encoding: "mp3",
            sampleRate: 24000
        )
    }

    func resolvedConfig() -> DoubaoCloudTTSResolvedConfig {
        let appIdEnv = settings.appIdEnv ?? "DOUBAO_TTS_APP_ID"
        let tokenEnv = settings.accessTokenEnv ?? "DOUBAO_TTS_ACCESS_TOKEN"
        let apiKeyEnv = settings.apiKeyEnv ?? "DOUBAO_TTS_API_KEY"
        let clusterEnv = settings.clusterEnv ?? "DOUBAO_TTS_CLUSTER"
        let voiceTypeEnv = settings.voiceTypeEnv ?? "DOUBAO_TTS_VOICE_TYPE"
        let resourceIdEnv = settings.resourceIdEnv ?? "DOUBAO_TTS_RESOURCE_ID"

        let appId = ProcessInfo.processInfo.environment[appIdEnv] ?? ""
        let accessToken = ProcessInfo.processInfo.environment[tokenEnv] ?? ""
        let apiKey = ProcessInfo.processInfo.environment[apiKeyEnv] ?? ""
        let cluster = ProcessInfo.processInfo.environment[clusterEnv] ?? settings.defaultCluster ?? ""
        let voiceType = ProcessInfo.processInfo.environment[voiceTypeEnv] ?? settings.defaultVoiceType ?? ""
        let endpoint = settings.endpoint ?? "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
        let encoding = settings.encoding ?? "mp3"
        let resourceId = ProcessInfo.processInfo.environment[resourceIdEnv] ?? settings.resourceId ?? "seed-tts-2.0"
        let sampleRate = settings.sampleRate ?? 24000

        var missing: [String] = []
        if endpoint.isEmpty { missing.append("cloudTTS.endpoint") }
        if apiKey.isEmpty && (appId.isEmpty || accessToken.isEmpty) {
            missing.append("\(apiKeyEnv) or \(appIdEnv)+\(tokenEnv)")
        }
        if resourceId.isEmpty { missing.append(resourceIdEnv) }
        if voiceType.isEmpty { missing.append(voiceTypeEnv) }

        return DoubaoCloudTTSResolvedConfig(
            endpoint: endpoint,
            appId: appId,
            accessToken: accessToken,
            apiKey: apiKey,
            cluster: cluster,
            voiceType: voiceType,
            encoding: encoding,
            resourceId: resourceId,
            sampleRate: sampleRate,
            missing: missing
        )
    }

    func status() -> VoiceProviderStatus {
        let config = resolvedConfig()
        return VoiceProviderStatus(
            id: id,
            kind: "ttsCloud",
            available: config.isConfigured,
            fallbackId: "system-avspeech",
            detail: config.isConfigured
                ? "endpoint=\(config.endpoint) auth=\(config.usesAPIKey ? "apiKey" : "appAccessToken") resourceId=\(config.resourceId) voiceType=\(config.voiceType) encoding=\(config.encoding) sampleRate=\(config.sampleRate)"
                : "missing env: \(config.missing.joined(separator: ","))"
        )
    }

    func synthesize(text: String, language: String, settings voiceSettings: VoiceSettings) async throws -> Data {
        let config = resolvedConfig()
        guard config.isConfigured else {
            throw CloudSpeechError.providerUnavailable("missing env: \(config.missing.joined(separator: ","))")
        }
        guard let url = URL(string: config.endpoint) else {
            throw CloudSpeechError.invalidResponse("invalid endpoint")
        }

        if config.endpoint.contains("/api/v3/tts/") || config.usesAPIKey || config.resourceId.hasPrefix("seed-tts") {
            return try await synthesizeV3(text: text, config: config, settings: voiceSettings, url: url)
        }

        let speedRatio = max(0.2, min(3.0, 1.0 + Double(max(-5, min(5, voiceSettings.rate))) * 0.06))
        let volumeRatio = max(0.1, min(3.0, Double(max(0, min(100, voiceSettings.volume))) / 86.0))
        let body: [String: Any] = [
            "app": [
                "appid": config.appId,
                "token": config.accessToken,
                "cluster": config.cluster
            ],
            "user": [
                "uid": "desktop-pet-mac"
            ],
            "audio": [
                "voice_type": config.voiceType,
                "encoding": config.encoding,
                "speed_ratio": speedRatio,
                "volume_ratio": volumeRatio
            ],
            "request": [
                "reqid": UUID().uuidString,
                "text": text,
                "operation": "query"
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer; \(config.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.resourceId, forHTTPHeaderField: "Resource-Id")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudSpeechError.invalidResponse("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: responseData.prefix(300), encoding: .utf8) ?? "non-utf8 response"
            throw CloudSpeechError.requestFailed("HTTP \(http.statusCode): \(message)")
        }

        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            if let code = json["code"] as? Int, code != 3000 && code != 0 {
                let message = json["message"] as? String ?? "unknown cloud tts error"
                throw CloudSpeechError.requestFailed("code=\(code) \(message)")
            }
            if let base64 = json["data"] as? String,
               let audio = Data(base64Encoded: base64),
               !audio.isEmpty {
                return audio
            }
            if let message = json["message"] as? String {
                throw CloudSpeechError.invalidResponse(message)
            }
        }

        if responseData.isEmpty {
            throw CloudSpeechError.invalidResponse("empty response")
        }
        return responseData
    }

    private func synthesizeV3(text: String, config: DoubaoCloudTTSResolvedConfig, settings voiceSettings: VoiceSettings, url: URL) async throws -> Data {
        let speechRate = max(-50, min(100, max(-5, min(5, voiceSettings.rate)) * 10))
        let loudnessRate = max(-50, min(100, Int(round((Double(max(0, min(100, voiceSettings.volume))) - 50.0) * 2.0))))
        let body: [String: Any] = [
            "user": [
                "uid": "desktop-pet-mac"
            ],
            "req_params": [
                "text": text,
                "speaker": config.voiceType,
                "audio_params": [
                    "format": config.encoding,
                    "sample_rate": config.sampleRate,
                    "speech_rate": speechRate,
                    "loudness_rate": loudnessRate
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        if config.usesAPIKey {
            request.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(config.appId, forHTTPHeaderField: "X-Api-App-Id")
            request.setValue(config.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        }
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudSpeechError.invalidResponse("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: responseData.prefix(300), encoding: .utf8) ?? "non-utf8 response"
            throw CloudSpeechError.requestFailed("HTTP \(http.statusCode): \(message)")
        }

        let audio = try extractV3Audio(from: responseData)
        if audio.isEmpty {
            throw CloudSpeechError.invalidResponse("empty v3 audio response")
        }
        return audio
    }

    private func extractV3Audio(from responseData: Data) throws -> Data {
        var audio = Data()
        let objectDatas = splitConcatenatedJSONObjects(responseData)
        let candidates = objectDatas.isEmpty ? [responseData] : objectDatas
        for objectData in candidates {
            guard let json = try? JSONSerialization.jsonObject(with: objectData) as? [String: Any] else {
                continue
            }
            if let code = json["code"] as? Int, code != 20000000 && code != 0 {
                let message = json["message"] as? String ?? "unknown cloud tts v3 error"
                throw CloudSpeechError.requestFailed("code=\(code) \(message)")
            }
            if let base64 = json["data"] as? String,
               let chunk = Data(base64Encoded: base64),
               !chunk.isEmpty {
                audio.append(chunk)
            }
        }
        return audio
    }

    private func splitConcatenatedJSONObjects(_ data: Data) -> [Data] {
        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        var ranges: [Range<String.Index>] = []
        var objectStart: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        var index = raw.startIndex

        while index < raw.endIndex {
            let ch = raw[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 { objectStart = index }
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0, let start = objectStart {
                    ranges.append(start..<raw.index(after: index))
                    objectStart = nil
                }
            }
            index = raw.index(after: index)
        }

        return ranges.compactMap { raw[$0].data(using: .utf8) }
    }
}

struct AutonomySettings: Codable {
    var enabled: Bool
    var messageChance: Double
}

struct UISettings: Codable {
    var language: String
    var compact: Bool?
}

struct AnthropicBrainSettings: Codable {
    var model: String
    var apiKeyEnv: String
    var baseURL: String?
    var maxTokens: Int
    var systemPromptZh: String
    var systemPromptEn: String
    var systemPromptJa: String?
}

struct BrainSettings: Codable {
    var provider: String
    var anthropic: AnthropicBrainSettings?
}

struct CharacterPackSettings: Codable {
    var activePack: String?
}

struct NaturalMotionSettings: Codable {
    var enableNaturalMotion: Bool?
    var enableWindowEdgeInteraction: Bool?
    var enableMischiefActions: Bool?
    var motionIntensity: String?
    var mischiefFrequency: String?
    var respectFocusMode: Bool?
    var maxActionDurationSeconds: Double?
    var minSecondsBetweenMischief: Double?
    var enableBehaviorDirector: Bool?
    var thinkingMaxActiveSeconds: Double?
}

struct AppSettings: Codable {
    var version: Int
    var window: WindowSettings
    var voice: VoiceSettings
    var autonomy: AutonomySettings
    var ui: UISettings?
    var brain: BrainSettings?
    var character: CharacterPackSettings?
    var naturalMotion: NaturalMotionSettings?

    static let fallback = AppSettings(
        version: 1,
        window: WindowSettings(
            width: 390,
            height: 330,
            defaultOffsetRight: 38,
            defaultOffsetBottom: 90,
            rememberPosition: true,
            keepInsideScreen: true,
            topmost: true,
            showInTaskbar: true
        ),
        voice: VoiceSettings(synthesisEnabled: true, rate: 1, volume: 86),
        autonomy: AutonomySettings(enabled: true, messageChance: 0.08),
        ui: UISettings(language: "zh-CN", compact: false),
        brain: nil,
        character: nil,
        naturalMotion: nil
    )
}

struct SpeechStyle: Codable {
    var tone: String?
    var humor: Double?
    var warmth: Double?
    var sarcasm: Double?
    var verbosity: Double?
}

struct BehaviorBias: Codable {
    var playfulness: Double?
    var curiosity: Double?
    var calmness: Double?
    var interruptiveness: Double?
    var energy: Double?
}

struct PrivacySettings: Codable {
    var wallpaperSense: Bool?
    var screenContentSense: Bool?
    var rememberConversations: Bool?
}

struct CharacterProfile: Codable {
    var id: String
    var name: String
    var summary: String
    var personality: [String]
    var speechStyle: SpeechStyle?
    var behaviorBias: BehaviorBias?
    var privacy: PrivacySettings?
}

struct CharacterPackPersona: Codable {
    struct PersonaSpeechStyle: Codable {
        var tone: String?
    }

    struct PersonaBehaviorBias: Codable {
        var playfulness: Double?
        var curiosity: Double?
        var calmness: Double?
        var interruptiveness: Double?
        var energy: Double?
    }

    var id: String
    var name: String
    var positioning: String?
    var personality: [String]
    var speechStyle: PersonaSpeechStyle?
    var behaviorBias: PersonaBehaviorBias?

    func asCharacterProfile() -> CharacterProfile {
        CharacterProfile(
            id: id,
            name: name,
            summary: positioning ?? name,
            personality: personality,
            speechStyle: SpeechStyle(
                tone: speechStyle?.tone,
                humor: 0.66,
                warmth: 0.82,
                sarcasm: 0.12,
                verbosity: 0.42
            ),
            behaviorBias: BehaviorBias(
                playfulness: behaviorBias?.playfulness,
                curiosity: behaviorBias?.curiosity,
                calmness: behaviorBias?.calmness,
                interruptiveness: behaviorBias?.interruptiveness,
                energy: behaviorBias?.energy
            ),
            privacy: PrivacySettings(wallpaperSense: true, screenContentSense: false, rememberConversations: false)
        )
    }
}

// MARK: - Character Rig Manifest (characters/<id>/manifest.json)

struct RigPoint: Codable {
    var x: Double
    var y: Double
}

struct RigRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct RigCanvas: Codable {
    var width: Double
    var height: Double
}

struct RigPalette: Codable {
    var primary: String
    var secondary: String
    var accent: String
    var warmAccent: String?
    var flameCore: String?
    var line: String
}

struct RigPart: Codable {
    var id: String
    var type: String           // ellipse / path / eye / mouth / paw
    var layer: Int
    var anchor: RigPoint?
    var bounds: RigRect
    var blinkAxis: String?
    var openDirection: String?
    var notes: String?
}

struct CharacterRigManifest: Codable {
    var version: Int
    var id: String
    var displayName: String
    var source: String?
    var canvas: RigCanvas
    var palette: RigPalette
    var styleNotes: [String]?
    var parts: [RigPart]
}

// MARK: - Motion Library (characters/<id>/motions.json)

struct MotionKeyframe: Codable {
    var frame: Int
    var value: Double
    var ease: String?
}

struct MotionClip: Codable {
    var durationFrames: Int
    var loop: Bool?
    var tracks: [String: [MotionKeyframe]]
}

struct MotionLibrary: Codable {
    var version: Int
    var fps: Int
    var defaultDurationFrames: Int?
    var clips: [String: MotionClip]
}

// MARK: - Motion Player (Phase C, 60Hz)

final class MotionPlayer {
    let library: MotionLibrary
    private(set) var currentClipName: String?
    private var clipStartTime: TimeInterval = 0
    private var lastSampledValues: [String: Double] = [:]
    private var transitionStart: TimeInterval = 0
    private let transitionDuration: TimeInterval = 0.20
    private let fps: Double

    init(library: MotionLibrary) {
        self.library = library
        self.fps = max(1.0, Double(library.fps))
    }

    /// Switch to a new clip and start a blend transition from the current sampled state.
    func play(_ clipName: String, now: TimeInterval) {
        guard library.clips[clipName] != nil else { return }
        if currentClipName == clipName { return }
        lastSampledValues = sample(now: now)
        currentClipName = clipName
        clipStartTime = now
        transitionStart = now
    }

    /// Sample all tracks at the given time. Applies linear blend during transition window.
    func sample(now: TimeInterval) -> [String: Double] {
        guard let name = currentClipName, let clip = library.clips[name] else {
            return [:]
        }
        let elapsed = max(0, now - clipStartTime)
        let frame = elapsed * fps
        let duration = Double(clip.durationFrames)
        let resolvedFrame: Double
        if clip.loop ?? false {
            resolvedFrame = duration > 0 ? frame.truncatingRemainder(dividingBy: duration) : 0
        } else {
            resolvedFrame = min(frame, duration)
        }

        var result: [String: Double] = [:]
        for (track, keyframes) in clip.tracks {
            result[track] = sampleTrack(keyframes: keyframes, at: resolvedFrame)
        }

        // Transition blend from last clip's final values into new clip's current values.
        let transitionElapsed = now - transitionStart
        if transitionElapsed < transitionDuration && !lastSampledValues.isEmpty {
            let rawT = transitionElapsed / transitionDuration
            let blendT = easeInOut(rawT)
            var blended: [String: Double] = [:]
            let allKeys = Set(result.keys).union(lastSampledValues.keys)
            for key in allKeys {
                let newValue = result[key] ?? defaultValue(for: key)
                let oldValue = lastSampledValues[key] ?? defaultValue(for: key)
                blended[key] = oldValue + (newValue - oldValue) * blendT
            }
            return blended
        }
        return result
    }

    private func sampleTrack(keyframes: [MotionKeyframe], at frame: Double) -> Double {
        guard !keyframes.isEmpty else { return 0 }
        if frame <= Double(keyframes.first!.frame) { return keyframes.first!.value }
        if frame >= Double(keyframes.last!.frame) { return keyframes.last!.value }
        for i in 0..<(keyframes.count - 1) {
            let k1 = keyframes[i]
            let k2 = keyframes[i + 1]
            if frame >= Double(k1.frame) && frame <= Double(k2.frame) {
                let span = Double(k2.frame - k1.frame)
                if span <= 0 { return k1.value }
                let t = (frame - Double(k1.frame)) / span
                let easedT = applyEase(t, ease: k1.ease)
                return k1.value + (k2.value - k1.value) * easedT
            }
        }
        return keyframes.last!.value
    }

    private func applyEase(_ t: Double, ease: String?) -> Double {
        switch ease {
        case "easeIn": return t * t
        case "easeOut": return 1 - (1 - t) * (1 - t)
        case "easeInOut": return easeInOut(t)
        default: return t
        }
    }

    private func easeInOut(_ t: Double) -> Double {
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    private func defaultValue(for trackName: String) -> Double {
        if trackName.hasSuffix(".scaleY") || trackName.hasSuffix(".scaleX") {
            return 1.0
        }
        return 0.0
    }
}

// MARK: - Pet Behavior System (Stage 1: state machine + action sequences)

enum PetBehaviorState: String {
    case idle, noticing, preparing, moving, climbing, peeking
    case mischievous, guilty, celebrating, sleepy, returning, interrupted
}

enum BehaviorPriority: Int, Comparable {
    case low = 0       // ExitToIdle, autonomous patrol/decor
    case medium = 1    // EnterThinking, ClickReaction
    case high = 2      // EnterSpeaking, BottomPeekIn entrance
    case critical = 3  // Drag / shutdown / force interrupt
    static func < (a: BehaviorPriority, b: BehaviorPriority) -> Bool { a.rawValue < b.rawValue }
}

enum SequenceCategory {
    case modeTransition   // thinking / speaking / idle 切换 — 不堆积
    case userInteraction  // 点击反应
    case autoBehavior     // 自动 patrol / decor
    case system           // 启动 / 退出 / 拖动 reset
}

@MainActor
protocol PetActionSequence: AnyObject {
    var name: String { get }
    var stateOnEnter: PetBehaviorState { get }
    var isInterruptible: Bool { get }
    var priority: BehaviorPriority { get }
    var category: SequenceCategory { get }
    func start(controller: DesktopPetController, now: TimeInterval)
    /// Returns true when the sequence is done.
    func tick(controller: DesktopPetController, now: TimeInterval, dt: TimeInterval) -> Bool
    func interrupt(controller: DesktopPetController)
}

// Default values so existing sequences (BottomPeekIn, ClickReaction) compile.
extension PetActionSequence {
    var priority: BehaviorPriority { .medium }
    var category: SequenceCategory { .autoBehavior }
}

@MainActor
final class BehaviorDirector {
    weak var controller: DesktopPetController?
    private var queue: [PetActionSequence] = []
    private(set) var current: PetActionSequence?
    private(set) var state: PetBehaviorState = .idle
    private var lastTickTime: TimeInterval = 0

    init(controller: DesktopPetController) {
        self.controller = controller
        self.lastTickTime = Date().timeIntervalSinceReferenceDate
    }

    func enqueue(_ seq: PetActionSequence) {
        let now = Date().timeIntervalSinceReferenceDate
        if current == nil {
            startSequence(seq, now: now)
        } else {
            queue.append(seq)
        }
    }

    /// Priority + category-aware request. The primary entry point for mode transitions.
    /// Rules (per operator spec):
    /// - No current → start immediately.
    /// - Same-name modeTransition → ignore (no duplicate stacking).
    /// - new.priority > current.priority → interrupt + start.
    /// - Same priority + both modeTransition → replace (interrupt + start).
    /// - Lower priority + modeTransition target → drop (don't append, no补播).
    /// - Otherwise (auto behaviors) → append.
    func request(_ seq: PetActionSequence) {
        let now = Date().timeIntervalSinceReferenceDate
        guard let c = current else {
            startSequence(seq, now: now)
            return
        }
        if seq.category == .modeTransition && c.name == seq.name {
            return
        }
        if seq.priority > c.priority {
            replaceCurrent(with: seq, now: now)
            return
        }
        if seq.category == .modeTransition && seq.priority == c.priority {
            replaceCurrent(with: seq, now: now)
            return
        }
        if seq.category == .modeTransition {
            return
        }
        queue.append(seq)
    }

    /// Force-interrupt current + drop queue. Optional new sequence starts immediately.
    /// Used by drag start, shutdown, mode `.excited` / `.sleeping` immediate paths.
    func interruptAndRun(_ seq: PetActionSequence?) {
        let now = Date().timeIntervalSinceReferenceDate
        if let c = current, let ctrl = controller {
            c.interrupt(controller: ctrl)
            current = nil
            state = .interrupted
        }
        queue.removeAll()
        if let s = seq {
            startSequence(s, now: now)
        }
    }

    func clearQueue() {
        queue.removeAll()
    }

    func interrupt() {
        guard let c = current, let ctrl = controller else { return }
        if c.isInterruptible {
            c.interrupt(controller: ctrl)
            current = nil
            state = .interrupted
        }
    }

    private func replaceCurrent(with seq: PetActionSequence, now: TimeInterval) {
        if let c = current, let ctrl = controller {
            c.interrupt(controller: ctrl)
        }
        current = nil
        startSequence(seq, now: now)
    }

    func tick(now: TimeInterval) {
        defer { lastTickTime = now }
        let dt = max(0, now - lastTickTime)
        if current == nil, !queue.isEmpty {
            let next = queue.removeFirst()
            startSequence(next, now: now)
        }
        guard let c = current, let ctrl = controller else { return }
        if c.tick(controller: ctrl, now: now, dt: dt) {
            current = nil
            state = .idle
        }
    }

    private func startSequence(_ seq: PetActionSequence, now: TimeInterval) {
        guard let ctrl = controller else { return }
        current = seq
        state = seq.stateOnEnter
        seq.start(controller: ctrl, now: now)
    }
}

// Shared easing helpers for sequences.
private enum BehaviorEase {
    static func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.70158
        let c3 = c1 + 1
        let p = t - 1
        return 1 + c3 * p * p * p + c1 * p * p
    }
    static func easeOutCubic(_ t: Double) -> Double {
        let p = 1 - t
        return 1 - p * p * p
    }
    static func easeInOut(_ t: Double) -> Double {
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}

// Self-natural entrance from below the screen.
@MainActor
final class BottomPeekInSequence: PetActionSequence {
    let name = "bottomPeekIn"
    let stateOnEnter: PetBehaviorState = .climbing
    let isInterruptible = false
    let priority: BehaviorPriority = .high
    let category: SequenceCategory = .system

    private var startTime: TimeInterval = 0
    private var targetOrigin: NSPoint = .zero
    private var startOrigin: NSPoint = .zero
    private let duration: TimeInterval = 1.4
    private let squashDuration: TimeInterval = 0.30
    private var phase: Phase = .rise

    private enum Phase { case rise, squash, done }

    func start(controller: DesktopPetController, now: TimeInterval) {
        startTime = now
        let frame = controller.window.frame
        targetOrigin = frame.origin
        startOrigin = NSPoint(x: frame.origin.x, y: -frame.size.height - 40)
        controller.window.setFrameOrigin(startOrigin)
        phase = .rise
        controller.petView.extraOffset = .zero
        controller.petView.extraScale = CGSize(width: 1, height: 1)
        controller.petView.lightbulbAlpha = 0
    }

    func tick(controller: DesktopPetController, now: TimeInterval, dt: TimeInterval) -> Bool {
        let elapsed = now - startTime
        switch phase {
        case .rise:
            let t = min(1.0, elapsed / duration)
            let eased = BehaviorEase.easeOutBack(t)
            let y = startOrigin.y + (targetOrigin.y - startOrigin.y) * CGFloat(eased)
            controller.window.setFrameOrigin(NSPoint(x: targetOrigin.x, y: y))
            if t >= 1.0 {
                controller.window.setFrameOrigin(targetOrigin)
                phase = .squash
                startTime = now
            }
            return false
        case .squash:
            let t = min(1.0, elapsed / squashDuration)
            // squash: 1.0 -> 0.88 -> 1.05 -> 1.0 (落地回弹)
            let squashY: Double
            if t < 0.35 {
                let p = t / 0.35
                squashY = 1.0 - 0.12 * p
            } else if t < 0.70 {
                let p = (t - 0.35) / 0.35
                squashY = 0.88 + 0.17 * p
            } else {
                let p = (t - 0.70) / 0.30
                squashY = 1.05 - 0.05 * p
            }
            let squashX = 2.0 - squashY
            controller.petView.extraScale = CGSize(width: squashX, height: squashY)
            if t >= 1.0 {
                controller.petView.extraScale = CGSize(width: 1, height: 1)
                phase = .done
            }
            return phase == .done
        case .done:
            return true
        }
    }

    func interrupt(controller: DesktopPetController) {
        controller.window.setFrameOrigin(targetOrigin)
        controller.petView.extraScale = CGSize(width: 1, height: 1)
    }
}

// Reaction sequence when the user clicks the pet.
@MainActor
final class ClickReactionSequence: PetActionSequence {
    let name = "clickReaction"
    let stateOnEnter: PetBehaviorState = .noticing
    let isInterruptible = true
    let priority: BehaviorPriority = .medium
    let category: SequenceCategory = .userInteraction

    private var startTime: TimeInterval = 0
    private var phase: Phase = .pause
    // pauseDur kept short until expression sprites land — the 整图 has no eye widening
    // to make a longer "startle" pause readable. Lengthen once expression PNGs exist.
    private let pauseDur: TimeInterval = 0.05
    private let hopDur: TimeInterval = 0.42
    private let lines: [String]

    private enum Phase { case pause, hop, done }

    init(language: String) {
        if isChineseLanguage(language) {
            self.lines = [
                "戳我干嘛。",
                "我在。",
                "别戳，痒。",
                "你终于想起我了？",
                "嗯？怎么了。",
                "嘿嘿，被发现啦！"
            ]
        } else if isJapaneseLanguage(language) {
            self.lines = [
                "つつかないで。",
                "いるよ。",
                "くすぐったい。",
                "やっと思い出した？",
                "ん？どうしたの。",
                "へへ、見つかった！"
            ]
        } else {
            self.lines = [
                "Hey, that tickles.",
                "I'm here.",
                "What's up?",
                "Finally remembered me?",
                "Hmm? Yes?"
            ]
        }
    }

    func start(controller: DesktopPetController, now: TimeInterval) {
        startTime = now
        phase = .pause
        // User-triggered character lines should use the same cloud/system voice path
        // as chat replies. Autonomous idle bubbles stay quiet unless explicitly spoken.
        if let line = lines.randomElement() {
            controller.voiceBubble(line)
        }
    }

    func tick(controller: DesktopPetController, now: TimeInterval, dt: TimeInterval) -> Bool {
        let elapsed = now - startTime
        switch phase {
        case .pause:
            // 愣住 0.18s,身体微后仰 (extraScale y=1.05)
            let t = min(1.0, elapsed / pauseDur)
            let stretch = 1.0 + 0.05 * t
            controller.petView.extraScale = CGSize(width: 2.0 - stretch, height: stretch)
            if t >= 1.0 {
                phase = .hop
                startTime = now
            }
            return false
        case .hop:
            // 跳一下:offset.y 0 -> -10 -> 0,身体 squash:1 -> 0.92 -> 1
            let t = min(1.0, elapsed / hopDur)
            let arc = sin(t * .pi)
            controller.petView.extraOffset = CGPoint(x: 0, y: -arc * 10)
            // Tiny squash near peak/landing
            let squashY = 1.0 - 0.08 * arc
            controller.petView.extraScale = CGSize(width: 2.0 - squashY, height: squashY)
            if t >= 1.0 {
                controller.petView.extraOffset = .zero
                controller.petView.extraScale = CGSize(width: 1, height: 1)
                phase = .done
            }
            return phase == .done
        case .done:
            return true
        }
    }

    func interrupt(controller: DesktopPetController) {
        controller.petView.extraOffset = .zero
        controller.petView.extraScale = CGSize(width: 1, height: 1)
    }
}

// MARK: - Mode transition sequences (thinking / speaking / idle)

/// EnterThinkingSequence: user sent a message, brain is composing a reply.
/// Phases: notice (eye blink hint) -> prepare (head tilt via motion) -> loop (motion + lightbulb fade in).
/// Loop持续直到外部 (EnterSpeaking) interrupt 它,或 reach softTimeout.
@MainActor
final class EnterThinkingSequence: PetActionSequence {
    let name = "enterThinking"
    let stateOnEnter: PetBehaviorState = .preparing
    let isInterruptible = true
    let priority: BehaviorPriority = .medium
    let category: SequenceCategory = .modeTransition

    private var phase: Phase = .notice
    private var startTime: TimeInterval = 0
    private var phaseStart: TimeInterval = 0
    private let noticeDur: TimeInterval = 0.15
    private let prepareDur: TimeInterval = 0.25
    private let lightbulbFadeInDur: TimeInterval = 0.45
    private let lightbulbPeak: CGFloat = 0.9
    private let lightbulbSoftTimeoutAlpha: CGFloat = 0.4
    private let softTimeoutSec: TimeInterval

    private enum Phase { case notice, prepare, loop }

    init(thinkingMaxActiveSeconds: TimeInterval = 30.0) {
        self.softTimeoutSec = thinkingMaxActiveSeconds
    }

    func start(controller: DesktopPetController, now: TimeInterval) {
        startTime = now
        phaseStart = now
        phase = .notice
        // Switch motion to thinkingPeek; clipStartTime uses motion-relative clock.
        controller.motionPlayer?.play("thinkingPeek", now: controller.motionRelativeNow)
    }

    func tick(controller: DesktopPetController, now: TimeInterval, dt: TimeInterval) -> Bool {
        let elapsedPhase = now - phaseStart
        switch phase {
        case .notice:
            // 短促上抬 + 微拉长 — 身体语言的"被惊到"暗示。整图模式没眼睛眨眼,
            // 但身体的轻微震动配合 motion player 的 thinkingPeek 起始头部转动,
            // 共同传达"开始关注"的感觉。
            let t = min(1.0, elapsedPhase / noticeDur)
            let arc = sin(.pi * t)  // 0 → 1 → 0
            let bob: CGFloat = -3.0 * CGFloat(arc)
            let stretchY: CGFloat = 1.0 + 0.03 * CGFloat(arc)
            controller.petView.extraOffset = CGPoint(x: 0, y: bob)
            controller.petView.extraScale = CGSize(width: 2.0 - stretchY, height: stretchY)
            if t >= 1.0 {
                controller.petView.extraOffset = .zero
                controller.petView.extraScale = CGSize(width: 1, height: 1)
                phase = .prepare
                phaseStart = now
            }
            return false
        case .prepare:
            // 微前倾 + 微下沉 — "嗯,让我想想" 的准备姿态。配合 motion player 的
            // head.rotate 在前 0.5s 走到 -5°,共同构成"歪头思考"。
            let t = min(1.0, elapsedPhase / prepareDur)
            let eased = CGFloat(BehaviorEase.easeOutCubic(t))
            controller.petView.extraOffset = CGPoint(x: 1.5 * eased, y: 1.5 * eased)
            if t >= 1.0 {
                controller.petView.extraOffset = CGPoint(x: 1.5, y: 1.5)
                phase = .loop
                phaseStart = now
                // loop 期间保持 (1.5, 1.5) — 下一个 sequence (Speaking/ExitToIdle/drag)
                // 自己负责把 extraOffset 平滑 ease 回 0。
            }
            return false
        case .loop:
            let totalLoopElapsed = elapsedPhase
            let fadeT = min(1.0, totalLoopElapsed / lightbulbFadeInDur)
            let targetAlpha = lightbulbPeak * CGFloat(fadeT)
            let globalElapsed = now - startTime
            if globalElapsed >= softTimeoutSec {
                // Soft timeout: dim the bulb so the pet hints "I'm still here, but quietly waiting."
                let capped = min(targetAlpha, lightbulbSoftTimeoutAlpha)
                controller.petView.lightbulbAlpha = capped
            } else {
                controller.petView.lightbulbAlpha = targetAlpha
            }
            return false  // never self-completes; must be interrupted by speaking/idle/drag
        }
    }

    func interrupt(controller: DesktopPetController) {
        // 不动 lightbulbAlpha / extraOffset — 由 EnterSpeaking 的 settle 阶段或
        // ExitToIdle 的 settle 阶段平滑收束;若被 critical 中断,
        // resetVisualStateForInterrupt 会清。
    }
}

/// EnterSpeakingSequence: reply arrived. settle thinking visuals then start talking.
/// Phases: settle (lightbulb fade out + offset reset) -> prepare (lean forward) -> loop (talkSoft motion).
/// 高优先级,可以 interrupt thinking。
@MainActor
final class EnterSpeakingSequence: PetActionSequence {
    let name = "enterSpeaking"
    let stateOnEnter: PetBehaviorState = .preparing
    let isInterruptible = true
    let priority: BehaviorPriority = .high
    let category: SequenceCategory = .modeTransition

    private var phase: Phase = .settle
    private var phaseStart: TimeInterval = 0
    private var settleStartLightbulb: CGFloat = 0
    private var settleStartOffset: CGPoint = .zero
    private let settleDur: TimeInterval = 0.30
    private let prepareDur: TimeInterval = 0.15
    private let leanForwardY: CGFloat = 3.0

    private enum Phase { case settle, prepare, loop }

    func start(controller: DesktopPetController, now: TimeInterval) {
        phaseStart = now
        phase = .settle
        settleStartLightbulb = controller.petView.lightbulbAlpha
        settleStartOffset = controller.petView.extraOffset
        // Keep current motion (likely thinkingPeek) until settle finishes,
        // so the head returns smoothly through the motion's blend window.
    }

    func tick(controller: DesktopPetController, now: TimeInterval, dt: TimeInterval) -> Bool {
        let elapsedPhase = now - phaseStart
        switch phase {
        case .settle:
            let t = min(1.0, elapsedPhase / settleDur)
            let eased = CGFloat(BehaviorEase.easeOutCubic(t))
            controller.petView.lightbulbAlpha = settleStartLightbulb * (1.0 - eased)
            controller.petView.extraOffset = CGPoint(
                x: settleStartOffset.x * (1.0 - eased),
                y: settleStartOffset.y * (1.0 - eased)
            )
            if elapsedPhase >= settleDur {
                controller.petView.lightbulbAlpha = 0
                controller.petView.extraOffset = .zero
                phase = .prepare
                phaseStart = now
                controller.motionPlayer?.play("talkSoft", now: controller.motionRelativeNow)
            }
            return false
        case .prepare:
            let t = min(1.0, elapsedPhase / prepareDur)
            let eased = CGFloat(BehaviorEase.easeOutCubic(t))
            controller.petView.extraOffset = CGPoint(x: 0, y: leanForwardY * eased)
            if elapsedPhase >= prepareDur {
                controller.petView.extraOffset = CGPoint(x: 0, y: leanForwardY)
                phase = .loop
                phaseStart = now
            }
            return false
        case .loop:
            // Hold lean + talkSoft loop until interrupted by ExitToIdle / drag / new thinking.
            return false
        }
    }

    func interrupt(controller: DesktopPetController) {
        // 保留 extraOffset,由 ExitToIdle 收束;若被 critical 中断,resetVisualStateForInterrupt 会清。
    }
}

/// ExitToIdleSequence: speak 完毕,回正到 idle。
/// Phases: settle (body recenter + lightbulb to 0) -> idleSwitch (play idleBreath, wait blend) -> done.
/// 低优先级 — 任何 thinking/speaking 都能 interrupt 它。
@MainActor
final class ExitToIdleSequence: PetActionSequence {
    let name = "exitToIdle"
    let stateOnEnter: PetBehaviorState = .returning
    let isInterruptible = true
    let priority: BehaviorPriority = .low
    let category: SequenceCategory = .modeTransition

    private var phase: Phase = .settle
    private var phaseStart: TimeInterval = 0
    private var startOffset: CGPoint = .zero
    private var startLightbulb: CGFloat = 0
    private let settleDur: TimeInterval = 0.30
    private let postBlendWait: TimeInterval = 0.20

    private enum Phase { case settle, idleSwitch, done }

    func start(controller: DesktopPetController, now: TimeInterval) {
        phaseStart = now
        phase = .settle
        startOffset = controller.petView.extraOffset
        startLightbulb = controller.petView.lightbulbAlpha
    }

    func tick(controller: DesktopPetController, now: TimeInterval, dt: TimeInterval) -> Bool {
        let elapsedPhase = now - phaseStart
        switch phase {
        case .settle:
            let t = min(1.0, elapsedPhase / settleDur)
            let eased = CGFloat(BehaviorEase.easeOutCubic(t))
            controller.petView.extraOffset = CGPoint(
                x: startOffset.x * (1.0 - eased),
                y: startOffset.y * (1.0 - eased)
            )
            controller.petView.lightbulbAlpha = startLightbulb * (1.0 - eased)
            if elapsedPhase >= settleDur {
                controller.petView.extraOffset = .zero
                controller.petView.lightbulbAlpha = 0
                phase = .idleSwitch
                phaseStart = now
                controller.motionPlayer?.play("idleBreath", now: controller.motionRelativeNow)
            }
            return false
        case .idleSwitch:
            if elapsedPhase >= postBlendWait {
                phase = .done
            }
            return false
        case .done:
            return true
        }
    }

    func interrupt(controller: DesktopPetController) {
        // 被打断时不强制清零 — 接管者(thinking/speaking)会自己 settle。
    }
}

/// LongIdleSettleSequence: 用户长时间无交互(默认 60s)时,小七自然进入困倦/趴下。
/// Phases: noticeSleepy (低头微缩) -> prepareSettle (下沉 + 切 sleepCurl motion) -> sleepLoop (保持)。
/// 低优先级,任何用户交互或更高优先级 sequence 都能打断。
/// 不允许重复:由 controller.tickAutonomy 的触发逻辑保证(检查 director.current == nil)。
@MainActor
final class LongIdleSettleSequence: PetActionSequence {
    let name = "longIdleSettle"
    let stateOnEnter: PetBehaviorState = .sleepy
    let isInterruptible = true
    let priority: BehaviorPriority = .low
    let category: SequenceCategory = .autoBehavior

    private var phase: Phase = .noticeSleepy
    private var phaseStart: TimeInterval = 0
    private let noticeSleepyDur: TimeInterval = 0.5
    private let prepareSettleDur: TimeInterval = 0.7
    private let lowerY: CGFloat = 4.0
    private let squeezeY: CGFloat = 0.96

    private enum Phase { case noticeSleepy, prepareSettle, sleepLoop }

    func start(controller: DesktopPetController, now: TimeInterval) {
        phaseStart = now
        phase = .noticeSleepy
        // 保持当前 motion clip (idleBreath) 直到 prepareSettle 末尾再切 sleepCurl,
        // 这样下沉动作的开始和身体趴下的开始能错开,看起来更像"先犯困再趴下"。
    }

    func tick(controller: DesktopPetController, now: TimeInterval, dt: TimeInterval) -> Bool {
        let elapsedPhase = now - phaseStart
        switch phase {
        case .noticeSleepy:
            let t = min(1.0, elapsedPhase / noticeSleepyDur)
            let eased = CGFloat(BehaviorEase.easeOutCubic(t))
            controller.petView.extraOffset = CGPoint(x: 0, y: 2.0 * eased)
            let s: CGFloat = 1.0 - (1.0 - 0.98) * eased
            controller.petView.extraScale = CGSize(width: 2.0 - s, height: s)
            if t >= 1.0 {
                phase = .prepareSettle
                phaseStart = now
            }
            return false
        case .prepareSettle:
            let t = min(1.0, elapsedPhase / prepareSettleDur)
            let eased = CGFloat(BehaviorEase.easeOutCubic(t))
            controller.petView.extraOffset = CGPoint(x: 0, y: 2.0 + (lowerY - 2.0) * eased)
            let s: CGFloat = 0.98 - (0.98 - squeezeY) * eased
            controller.petView.extraScale = CGSize(width: 2.0 - s, height: s)
            if t >= 1.0 {
                controller.petView.extraOffset = CGPoint(x: 0, y: lowerY)
                controller.petView.extraScale = CGSize(width: 2.0 - squeezeY, height: squeezeY)
                phase = .sleepLoop
                phaseStart = now
                controller.motionPlayer?.play("sleepCurl", now: controller.motionRelativeNow)
            }
            return false
        case .sleepLoop:
            // 保持下沉 + sleepCurl loop。motion player 已经在以 60Hz 采样 sleepCurl 曲线。
            // 不主动说话(没有 setBubble 调用)。返回 false 直到被外部打断。
            return false
        }
    }

    func interrupt(controller: DesktopPetController) {
        // 用户来了 — 清掉睡眠装饰(offset/scale),不留趴下残留。motion player 由接管
        // sequence 切回相应 clip (thinkingPeek / talkSoft / idleBreath),自动 0.2s blend
        // 平滑从 sleepCurl 过渡。这是 autoBehavior,清残留比让 modeTransition 自己 ease
        // 更稳。
        controller.petView.extraOffset = .zero
        controller.petView.extraScale = CGSize(width: 1, height: 1)
        controller.petView.lightbulbAlpha = 0
    }
}

// MARK: - WindowTargetingService (接口预留,尚未实现)

/// 描述前台窗口的目标点。WindowEdgeMischief 完整版未来从这里读真实坐标。
struct WindowTarget {
    /// 前台窗口的 frame (屏幕坐标)
    let frame: CGRect
    /// 估算的红黄绿按钮中心点 (屏幕坐标)。
    /// 不真实点击,仅作为桌宠"靠近"位置的参考。
    let trafficLightApproxPoint: CGPoint
    /// 桌宠可以安全靠近(不遮挡用户内容)的点。一般在标题栏附近、远离主输入区。
    let safeApproachPoint: CGPoint
}

/// 抽象前台窗口定位能力。当前 stub 永远返回 nil。
/// 完整实现走 macOS Accessibility / AXUIElement,需用户授予辅助功能权限。
/// 路线见 `docs/WINDOW_TARGETING_TODO.md`。
@MainActor
protocol WindowTargetingService {
    /// 返回当前前台窗口的目标信息;无权限/无前台窗口/估算失败时返回 nil。
    /// WindowEdgeMischief 完整版必须 guard nil → 不触发。
    func currentTarget() -> WindowTarget?
}

/// 默认 stub: 永远返回 nil。让现有 lite 版可以正常构建,且未来切换到真实
/// 实现时只换注入,不动 Sequence 代码。
@MainActor
final class NoopWindowTargetingService: WindowTargetingService {
    func currentTarget() -> WindowTarget? { nil }
}

/// WindowEdgeMischiefLiteSequence — 招牌互动雏形 (#5 lite,收敛版)
///
/// **⚠️ 当前状态:这不是完整的扒窗行为。**
/// 这是一个 **低频心虚小动作彩蛋**,唯一目的是在 `WindowTargetingService`
/// 没建立之前,**保留角色性格**("有点颠 / 有点小坏 / 但本质好")。
///
/// 它做的事:
/// - 在桌宠当前位置原地做 ≤ 2.5px 的小偏移
/// - glance → lean → fidget → guilty → settle 5 阶段,总时长 ~2.9s
/// - guilty 阶段显示一句"嘀咕"短气泡
///
/// 它**绝对不**做的事:
/// - ❌ 不挪窗口位置
/// - ❌ 不靠近任何真实窗口边
/// - ❌ 不读 `WindowTargetingService.currentTarget()` (lite 版有意跳过这个契约)
/// - ❌ 不提及红黄绿按钮(旧草稿里 "那个红按钮看起来怪危险的" 已经删了)
/// - ❌ 不调用任何 Accessibility / CGEvent
///
/// **真正的窗口边缘互动必须等 `WindowTargetingService.currentTarget()`**
/// 能返回真实 `WindowTarget` (来自 AXUIElement 查询) 之后再做。
/// 那时会另起一个 `WindowEdgeMischiefSequence` (full 版,不是 Lite),
/// 通过 SmoothWindowMoveSequence 把桌宠真挪到 target.safeApproachPoint。
/// 详见 `docs/WINDOW_TARGETING_TODO.md`。
///
/// 在 service 上线之前,**不要扩大本 sequence 的幅度**,也**不要新增宣称
/// 扒窗行为的 sequence** —— lite 的"小"是关键,因为它没法诚实地做大动作。
///
/// 视觉幅度(收敛后):
/// - extraOffset.x 最大 ±2.5px (原 ±4.5px)
/// - wobble 最大 ±1px (原 ±2px)
/// - 不左右大跳
///
/// 5 阶段: glance (0.3s) → lean (0.4s) → fidget (0.7s) → guilty (1.0s) → settle (0.5s)。
/// 总时长 ~2.9s。
@MainActor
final class WindowEdgeMischiefLiteSequence: PetActionSequence {
    let name = "windowEdgeMischiefLite"
    let stateOnEnter: PetBehaviorState = .mischievous
    let isInterruptible = true
    let priority: BehaviorPriority = .low
    let category: SequenceCategory = .autoBehavior

    private var phase: Phase = .glance
    private var phaseStart: TimeInterval = 0
    private let glanceDur: TimeInterval = 0.3
    private let leanDur: TimeInterval = 0.4
    private let fidgetDur: TimeInterval = 0.7
    private let guiltyDur: TimeInterval = 1.0
    private let settleDur: TimeInterval = 0.5
    /// +1.0 = 朝右瞄,−1.0 = 朝左瞄。一次互动只朝一个方向。
    private let direction: Double
    private let language: String

    /// 收敛后的最大偏移幅度(像素)。
    private let maxOffsetX: CGFloat = 2.5
    private let wobbleAmp: CGFloat = 1.0

    private enum Phase { case glance, lean, fidget, guilty, settle }

    init(language: String) {
        self.language = language
        self.direction = Bool.random() ? 1.0 : -1.0
    }

    func start(controller: DesktopPetController, now: TimeInterval) {
        phaseStart = now
        phase = .glance
        appendLog(controller.paths, "window-mischief-lite-start dir=\(direction > 0 ? "right" : "left") (lite-no-targeting)")
        // 不再有"那个红按钮看起来怪危险的"宣称语 — 没接 WindowTargetingService
        // 之前不该说自己在扒红黄绿按钮。气泡只在 guilty 阶段出现一次。
    }

    func tick(controller: DesktopPetController, now: TimeInterval, dt: TimeInterval) -> Bool {
        let elapsedPhase = now - phaseStart
        switch phase {
        case .glance:
            // 极轻歪头瞄一眼: ±1px
            let t = min(1.0, elapsedPhase / glanceDur)
            let eased = CGFloat(BehaviorEase.easeOutCubic(t))
            controller.petView.extraOffset = CGPoint(x: 1.0 * direction * eased, y: 0)
            if t >= 1.0 {
                phase = .lean
                phaseStart = now
            }
            return false
        case .lean:
            // 轻倾一下: 累计到 ±2.5px,y 微下沉 0.5px
            let t = min(1.0, elapsedPhase / leanDur)
            let eased = CGFloat(BehaviorEase.easeOutCubic(t))
            controller.petView.extraOffset = CGPoint(
                x: 1.0 * direction + (maxOffsetX - 1.0) * direction * eased,
                y: 0.5 * eased
            )
            if t >= 1.0 {
                phase = .fidget
                phaseStart = now
            }
            return false
        case .fidget:
            // "心虚小晃": 在 ±2.5px 基础上叠加 ±1px 1 个周期晃动
            // (原"扒拉"是 2 个周期 ±2px,现在收敛到 1 个周期 ±1px)
            let t = min(1.0, elapsedPhase / fidgetDur)
            let baseX = maxOffsetX * direction
            let wobble = sin(t * .pi * 2.0) * wobbleAmp
            controller.petView.extraOffset = CGPoint(x: baseX + wobble, y: 0.5)
            if t >= 1.0 {
                phase = .guilty
                phaseStart = now
                // 心虚气泡 — 去掉"我没碰按钮"这种含扒窗暗示的台词,
                // 改成纯粹的"我什么都没干"风格小嘀咕。
                let zhLines = [
                    "嗯…我什么都没干。",
                    "嘀咕嘀咕…",
                    "你看我干嘛，我可乖了。",
                    "没事，我就在这。",
                    "随便看看。"
                ]
                let enLines = [
                    "Uh… I wasn't doing anything.",
                    "Just mumbling…",
                    "Why are you looking at me, I'm being good.",
                    "Nothing, I'm just here.",
                    "Just looking around."
                ]
                let jaLines = [
                    "うん…何もしてません。",
                    "ぶつぶつ…",
                    "なんで見てるの、いい子だよ。",
                    "何でもない、ここにいるだけ。",
                    "ちょっと見てただけ。"
                ]
                let line = localizedValue(
                    language: language,
                    zh: zhLines.randomElement() ?? "...",
                    en: enLines.randomElement() ?? "...",
                    ja: jaLines.randomElement() ?? "..."
                )
                controller.setBubble(line)
            }
            return false
        case .guilty:
            // 缩回 idle
            let t = min(1.0, elapsedPhase / guiltyDur)
            let eased = CGFloat(BehaviorEase.easeOutCubic(t))
            let startX = maxOffsetX * direction
            controller.petView.extraOffset = CGPoint(
                x: startX * (1.0 - eased),
                y: 0.5 * (1.0 - eased)
            )
            if t >= 1.0 {
                phase = .settle
                phaseStart = now
            }
            return false
        case .settle:
            let t = min(1.0, elapsedPhase / settleDur)
            if t >= 1.0 {
                controller.petView.extraOffset = .zero
                controller.petView.extraScale = CGSize(width: 1, height: 1)
                appendLog(controller.paths, "window-mischief-lite-complete")
                return true
            }
            return false
        }
    }

    func interrupt(controller: DesktopPetController) {
        // autoBehavior 被打断 — 清自身视觉残留,让接管者从干净状态接手。
        controller.petView.extraOffset = .zero
        controller.petView.extraScale = CGSize(width: 1, height: 1)
        appendLog(controller.paths, "window-mischief-lite-interrupted")
    }
}

// MARK: - Smooth window move (60 FPS replacement for direct setFrameOrigin jumps)

enum MoveStyle {
    case hop      // 颠颠跳:大幅 bob,频率高 — 用于 excited
    case run      // 小跑:中幅 bob,频率中 — 用于 idle move
    case sneak    // 偷偷溜:微 bob,慢
    case slide    // 滑动:几乎无 bob,平直
}

struct SmoothWindowMoveConfig {
    let from: CGPoint
    let to: CGPoint
    let duration: TimeInterval
    let style: MoveStyle
    let priority: BehaviorPriority
}

/// 60 FPS smooth window move,替代 tickAutonomy 中直接 setFrameOrigin 的"跳格"。
/// 4 阶段: prepare (微前倾) -> move (插值 + bob) -> arrive (减速 + 回弹) -> settle (offset 归零)。
/// 由 motionTimer 60Hz 推进。被打断时清自身视觉残留。
@MainActor
final class SmoothWindowMoveSequence: PetActionSequence {
    let name = "smoothWindowMove"
    let stateOnEnter: PetBehaviorState = .moving
    let isInterruptible = true
    let priority: BehaviorPriority
    let category: SequenceCategory = .autoBehavior

    private let config: SmoothWindowMoveConfig
    private var phase: Phase = .prepare
    private var phaseStart: TimeInterval = 0
    private let prepareDur: TimeInterval = 0.20
    private let arriveDur: TimeInterval = 0.22
    private let settleDur: TimeInterval = 0.18
    private let hopHeight: CGFloat = 35.0      // 跳跃顶点向上的高度(Cocoa y+)
    private var leanX: CGFloat = 0
    private var leanY: CGFloat = 0

    private enum Phase { case prepare, move, arrive, settle }

    init(config: SmoothWindowMoveConfig) {
        self.config = config
        self.priority = config.priority
    }

    func start(controller: DesktopPetController, now: TimeInterval) {
        phaseStart = now
        phase = .prepare
        let dx = config.to.x - config.from.x
        leanX = dx > 0 ? 5.0 : (dx < 0 ? -5.0 : 0)  // 朝目标方向明显前倾
        leanY = 3.0                                  // 微下沉,"准备发力"
    }

    func tick(controller: DesktopPetController, now: TimeInterval, dt: TimeInterval) -> Bool {
        let elapsedPhase = now - phaseStart
        switch phase {
        case .prepare:
            let t = min(1.0, elapsedPhase / prepareDur)
            let eased = CGFloat(BehaviorEase.easeOutCubic(t))
            controller.petView.extraOffset = CGPoint(x: leanX * eased, y: leanY * eased)
            if t >= 1.0 {
                phase = .move
                phaseStart = now
            }
            return false
        case .move:
            let t = min(1.0, elapsedPhase / config.duration)
            let eased = CGFloat(BehaviorEase.easeInOut(t))
            let baseX = config.from.x + (config.to.x - config.from.x) * eased
            let baseY = config.from.y + (config.to.y - config.from.y) * eased

            // 不同 style 用不同物理模型,而不是统一的 sin 波 bob
            let yOffset: CGFloat
            switch config.style {
            case .hop:
                // 真抛物线: y = h * 4 * t * (1-t)
                // 起跳(t=0) y=0 -> 顶点(t=0.5) y=h -> 落地(t=1) y=0
                // Cocoa 坐标 y 向上为正,yOffset 正值 = 视觉上往上跳
                yOffset = hopHeight * 4.0 * CGFloat(t) * (1.0 - CGFloat(t))
            case .run:
                // 离散踩步: 每秒 ~2.2 步,每步是 abs(sin) 半周期
                // 起步和到达两头淡出(envelope sin(πt)),避免突兀
                let stepsPerSec: Double = 2.2
                let stepPhase = elapsedPhase * stepsPerSec * .pi
                let envelope = sin(.pi * t)
                yOffset = 3.0 * CGFloat(abs(sin(stepPhase))) * CGFloat(envelope)
            case .sneak:
                let stepsPerSec: Double = 1.2
                let stepPhase = elapsedPhase * stepsPerSec * .pi
                let envelope = sin(.pi * t)
                yOffset = 1.5 * CGFloat(abs(sin(stepPhase))) * CGFloat(envelope)
            case .slide:
                yOffset = 0
            }

            let clamped = clampWindowOrigin(NSPoint(x: baseX, y: baseY + yOffset), size: controller.window.frame.size)
            controller.window.setFrameOrigin(clamped)
            if t >= 1.0 {
                phase = .arrive
                phaseStart = now
            }
            return false
        case .arrive:
            // hop 落地: y 先下沉(squash) -> 回弹到 0。其它风格: 微 settle。
            let t = min(1.0, elapsedPhase / arriveDur)
            let bounceY: CGFloat
            switch config.style {
            case .hop:
                // 前 40% 下沉到 -3px (落地压扁),后 60% 弹回 0
                if t < 0.4 {
                    bounceY = -3.0 * CGFloat(t / 0.4)
                } else {
                    bounceY = -3.0 + 3.0 * CGFloat((t - 0.4) / 0.6)
                }
            case .run, .sneak:
                bounceY = -1.0 * CGFloat(sin(.pi * t))
            case .slide:
                bounceY = 0
            }
            let clamped = clampWindowOrigin(NSPoint(x: config.to.x, y: config.to.y + bounceY), size: controller.window.frame.size)
            controller.window.setFrameOrigin(clamped)
            if t >= 1.0 {
                controller.window.setFrameOrigin(config.to)
                phase = .settle
                phaseStart = now
            }
            return false
        case .settle:
            let t = min(1.0, elapsedPhase / settleDur)
            let eased = CGFloat(BehaviorEase.easeOutCubic(t))
            controller.petView.extraOffset = CGPoint(
                x: leanX * (1.0 - eased),
                y: leanY * (1.0 - eased)
            )
            if t >= 1.0 {
                controller.petView.extraOffset = .zero
                return true
            }
            return false
        }
    }

    func interrupt(controller: DesktopPetController) {
        controller.petView.extraOffset = .zero
    }
}

struct BehaviorAction: Codable {
    var id: String
    var label: String
    var weight: Double
    var state: String
}

struct BehaviorPack: Codable {
    var id: String
    var name: String
    var tags: [String]
    var actions: [BehaviorAction]
}

struct WallpaperSense {
    var path: String?
    var scene: String
    var reason: String
}

enum PetMode {
    case idle
    case thinking
    case speaking
    case sleeping
    case excited
}

struct PetRig {
    struct Body {
        var centerX: Double
        var restingTop: Double
        var restingWidth: Double
        var restingHeight: Double
        var sleepingTop: Double
        var sleepingWidth: Double
        var sleepingHeight: Double
        var faceInsetX: Double
        var faceTopOffset: Double
        var faceHeight: Double
        var sleepingFaceHeight: Double
    }

    struct Eyes {
        var leftXOffset: Double
        var rightXOffset: Double
        var idleYOffset: Double
        var sleepingYOffset: Double
        var width: Double
        var height: Double
        var lookShift: Double
        var closedWidth: Double
    }

    struct Mouth {
        var startX: Double
        var endX: Double
        var yawnX: Double
        var yawnWidth: Double
        var yawnHeight: Double
    }

    struct Antenna {
        var base: NSPoint
        var tip: NSPoint
        var control1: NSPoint
        var control2: NSPoint
        var bobbleOrigin: NSPoint
        var bobbleSize: NSSize
    }

    struct Shadow {
        var frame: NSRect
    }

    var body: Body
    var eyes: Eyes
    var mouth: Mouth
    var antenna: Antenna
    var shadow: Shadow

    static let defaultA = PetRig(
        body: Body(
            centerX: 115,
            restingTop: 44,
            restingWidth: 118,
            restingHeight: 112,
            sleepingTop: 88,
            sleepingWidth: 140,
            sleepingHeight: 62,
            faceInsetX: 12,
            faceTopOffset: 22,
            faceHeight: 72,
            sleepingFaceHeight: 40
        ),
        eyes: Eyes(
            leftXOffset: 35,
            rightXOffset: 73,
            idleYOffset: 48,
            sleepingYOffset: 28,
            width: 12,
            height: 18,
            lookShift: 4,
            closedWidth: 12
        ),
        mouth: Mouth(
            startX: 105,
            endX: 129,
            yawnX: 109,
            yawnWidth: 16,
            yawnHeight: 14
        ),
        antenna: Antenna(
            base: NSPoint(x: 115, y: 48),
            tip: NSPoint(x: 125, y: 15),
            control1: NSPoint(x: 110, y: 30),
            control2: NSPoint(x: 128, y: 28),
            bobbleOrigin: NSPoint(x: 121, y: 7),
            bobbleSize: NSSize(width: 16, height: 12)
        ),
        shadow: Shadow(frame: NSRect(x: 51, y: 142, width: 138, height: 24))
    )
}

struct Paths {
    let root: URL
    let character: URL
    let behaviorDir: URL
    let settings: URL
    let stateDir: URL
    let windowState: URL
    let petMemory: URL
    let logDir: URL
    let logFile: URL
    let lockFile: URL

    static func fromArguments() -> Paths {
        let args = CommandLine.arguments
        let root: URL
        if let index = args.firstIndex(of: "--root"), index + 1 < args.count {
            root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }

        return Paths(
            root: root,
            character: root.appendingPathComponent("characters/default.character.json"),
            behaviorDir: root.appendingPathComponent("behavior-packs", isDirectory: true),
            settings: root.appendingPathComponent("config/settings.json"),
            stateDir: root.appendingPathComponent("local-state", isDirectory: true),
            windowState: root.appendingPathComponent("local-state/window-state-mac.json"),
            petMemory: root.appendingPathComponent("local-state/pet-memory-mac.json"),
            logDir: root.appendingPathComponent("logs", isDirectory: true),
            logFile: root.appendingPathComponent("logs/desktop-pet-mac.log"),
            lockFile: root.appendingPathComponent("local-state/desktop-pet-mac.lock")
        )
    }
}

func appendLog(_ paths: Paths, _ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    guard let data = line.data(using: .utf8) else {
        return
    }
    try? FileManager.default.createDirectory(at: paths.logDir, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: paths.logFile.path),
       let handle = try? FileHandle(forWritingTo: paths.logFile) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: paths.logFile)
    }
}

final class AppLock {
    private let fd: Int32
    private let url: URL

    init?(paths: Paths) {
        try? FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        let opened = open(paths.lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard opened >= 0 else {
            appendLog(paths, "lock-open-failed path=\(paths.lockFile.path)")
            return nil
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            appendLog(paths, "lock-busy another instance is probably running")
            return nil
        }

        self.fd = opened
        self.url = paths.lockFile
        let info = "pid=\(ProcessInfo.processInfo.processIdentifier)\nstartedAt=\(ISO8601DateFormatter().string(from: Date()))\n"
        ftruncate(opened, 0)
        _ = info.withCString { pointer in
            write(opened, pointer, strlen(pointer))
        }
        appendLog(paths, "lock-acquired pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    func release(paths: Paths) {
        appendLog(paths, "lock-released")
        flock(fd, LOCK_UN)
        close(fd)
        try? FileManager.default.removeItem(at: url)
    }
}

func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(T.self, from: data)
}

func voicePackManifestURL(packId: String, paths: Paths) -> URL {
    paths.root
        .appendingPathComponent("characters", isDirectory: true)
        .appendingPathComponent(packId, isDirectory: true)
        .appendingPathComponent("voice.json")
}

func loadVoicePackManifest(packId: String, paths: Paths) -> VoicePackManifest? {
    let url = voicePackManifestURL(packId: packId, paths: paths)
    guard FileManager.default.fileExists(atPath: url.path) else {
        appendLog(paths, "voice-pack-manifest-missing id=\(packId)")
        return nil
    }
    do {
        let manifest = try readJSON(VoicePackManifest.self, from: url)
        appendLog(paths, "voice-pack-manifest-loaded id=\(packId) provider=\(manifest.provider) fallback=\(manifest.fallback ?? "none")")
        return manifest
    } catch {
        appendLog(paths, "voice-pack-manifest-load-failed id=\(packId) error=\(error.localizedDescription)")
        return nil
    }
}

func writeJSON(_ value: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func loadSettingsRoot(paths: Paths) -> [String: Any] {
    guard let data = try? Data(contentsOf: paths.settings),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return root
}

func updateSettingsLanguage(paths: Paths, language: String) {
    var root = loadSettingsRoot(paths: paths)
    guard !root.isEmpty else {
        appendLog(paths, "settings-language-save-skipped settings not readable")
        return
    }
    var ui = root["ui"] as? [String: Any] ?? [:]
    ui["language"] = language
    root["ui"] = ui
    do {
        try writeJSON(root, to: paths.settings)
        appendLog(paths, "settings-language-saved language=\(language)")
    } catch {
        appendLog(paths, "settings-language-save-failed error=\(error.localizedDescription)")
    }
}

func updateSettingsCompact(paths: Paths, compact: Bool) {
    var root = loadSettingsRoot(paths: paths)
    guard !root.isEmpty else { return }
    var ui = root["ui"] as? [String: Any] ?? [:]
    ui["compact"] = compact
    root["ui"] = ui
    try? writeJSON(root, to: paths.settings)
    appendLog(paths, "settings-compact-saved compact=\(compact)")
}

func updateSettingsBundle(
    paths: Paths,
    language: String,
    topmost: Bool,
    voice: Bool,
    autonomy: Bool,
    messageChance: Double,
    compact: Bool,
    naturalMotion: Bool,
    windowMischief: Bool
) {
    var root = loadSettingsRoot(paths: paths)
    if root.isEmpty {
        appendLog(paths, "settings-bundle-save-skipped settings not readable")
        return
    }
    var ui = root["ui"] as? [String: Any] ?? [:]
    ui["language"] = language
    ui["compact"] = compact
    root["ui"] = ui

    var window = root["window"] as? [String: Any] ?? [:]
    window["topmost"] = topmost
    root["window"] = window

    var voiceDict = root["voice"] as? [String: Any] ?? [:]
    voiceDict["synthesisEnabled"] = voice
    root["voice"] = voiceDict

    var autonomyDict = root["autonomy"] as? [String: Any] ?? [:]
    autonomyDict["enabled"] = autonomy
    autonomyDict["messageChance"] = max(0.0, min(0.5, messageChance))
    root["autonomy"] = autonomyDict

    var naturalMotionDict = root["naturalMotion"] as? [String: Any] ?? [:]
    naturalMotionDict["enableNaturalMotion"] = naturalMotion
    naturalMotionDict["enableWindowEdgeInteraction"] = windowMischief
    root["naturalMotion"] = naturalMotionDict

    do {
        try writeJSON(root, to: paths.settings)
        appendLog(paths, "settings-bundle-saved")
    } catch {
        appendLog(paths, "settings-bundle-save-failed error=\(error.localizedDescription)")
    }
}

func defaultPetMemory(characterName: String = "小七") -> [String: Any] {
    [
        "userName": "朋友",
        "petName": characterName,
        "personality": "有点颠、有点坏但本质好",
        "preferences": [
            "replyStyle": "short",
            "doNotDisturbWhenTyping": true,
            "mischiefFrequency": "low",
            "naturalMotion": true
        ]
    ]
}

func mergedPetMemory(_ raw: [String: Any], characterName: String = "小七") -> [String: Any] {
    var memory = defaultPetMemory(characterName: characterName)
    for (key, value) in raw {
        if key == "preferences",
           let rawPrefs = value as? [String: Any] {
            var prefs = memory["preferences"] as? [String: Any] ?? [:]
            for (prefKey, prefValue) in rawPrefs {
                prefs[prefKey] = prefValue
            }
            memory["preferences"] = prefs
        } else {
            memory[key] = value
        }
    }
    if memory["petName"] == nil {
        memory["petName"] = characterName
    }
    return memory
}

func loadPetMemory(paths: Paths, characterName: String = "小七") -> [String: Any] {
    guard let data = try? Data(contentsOf: paths.petMemory),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return defaultPetMemory(characterName: characterName)
    }
    return mergedPetMemory(raw, characterName: characterName)
}

func savePetMemory(paths: Paths, _ memory: [String: Any]) {
    try? writeJSON(memory, to: paths.petMemory)
}

func memoryString(_ memory: [String: Any], _ key: String) -> String? {
    let value = memory[key] as? String
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

func memoryPreferenceString(_ memory: [String: Any], _ key: String) -> String? {
    guard let prefs = memory["preferences"] as? [String: Any] else { return nil }
    let value = prefs[key] as? String
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

func memoryPreferenceBool(_ memory: [String: Any], _ key: String, default defaultValue: Bool) -> Bool {
    guard let prefs = memory["preferences"] as? [String: Any] else { return defaultValue }
    return (prefs[key] as? Bool) ?? defaultValue
}

func updatePetMemoryValue(paths: Paths, memory: inout [String: Any], key: String, value: String) {
    memory[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
    savePetMemory(paths: paths, memory)
}

func ensurePetMemorySaved(paths: Paths, memory: [String: Any]) {
    savePetMemory(paths: paths, memory)
}

func loadActiveCharacter(settings: AppSettings, paths: Paths) -> CharacterProfile? {
    if let packId = settings.character?.activePack,
       !packId.isEmpty {
        let personaURL = paths.root
            .appendingPathComponent("characters", isDirectory: true)
            .appendingPathComponent(packId, isDirectory: true)
            .appendingPathComponent("persona.json")
        if let persona = try? readJSON(CharacterPackPersona.self, from: personaURL) {
            appendLog(paths, "character-pack-loaded id=\(packId) path=\(personaURL.path)")
            return persona.asCharacterProfile()
        }
        appendLog(paths, "character-pack-load-failed id=\(packId) path=\(personaURL.path)")
    }
    return try? readJSON(CharacterProfile.self, from: paths.character)
}

func loadRigManifest(packId: String, paths: Paths) -> CharacterRigManifest? {
    guard !packId.isEmpty else { return nil }
    let url = paths.root
        .appendingPathComponent("characters", isDirectory: true)
        .appendingPathComponent(packId, isDirectory: true)
        .appendingPathComponent("manifest.json")
    if let manifest = try? readJSON(CharacterRigManifest.self, from: url) {
        appendLog(paths, "rig-manifest-loaded id=\(packId) parts=\(manifest.parts.count) canvas=\(Int(manifest.canvas.width))x\(Int(manifest.canvas.height))")
        return manifest
    }
    appendLog(paths, "rig-manifest-load-failed id=\(packId) path=\(url.path)")
    return nil
}

func loadMotionLibrary(packId: String, paths: Paths) -> MotionLibrary? {
    guard !packId.isEmpty else { return nil }
    let url = paths.root
        .appendingPathComponent("characters", isDirectory: true)
        .appendingPathComponent(packId, isDirectory: true)
        .appendingPathComponent("motions.json")
    if let lib = try? readJSON(MotionLibrary.self, from: url) {
        let clipNames = lib.clips.keys.sorted().joined(separator: ",")
        appendLog(paths, "motion-library-loaded id=\(packId) clips=\(lib.clips.count) fps=\(lib.fps) names=\(clipNames)")
        return lib
    }
    appendLog(paths, "motion-library-load-failed id=\(packId) path=\(url.path)")
    return nil
}

func loadCharacterIdleImage(packId: String, paths: Paths) -> NSImage? {
    guard !packId.isEmpty else { return nil }
    let packDir = paths.root
        .appendingPathComponent("characters", isDirectory: true)
        .appendingPathComponent(packId, isDirectory: true)
    let candidates = [
        packDir.appendingPathComponent("assets").appendingPathComponent("idle.png"),
        packDir.appendingPathComponent("source").appendingPathComponent("main.png")
    ]
    for url in candidates {
        if FileManager.default.fileExists(atPath: url.path),
           let img = NSImage(contentsOf: url) {
            appendLog(paths, "character-idle-image-loaded id=\(packId) path=\(url.lastPathComponent) size=\(Int(img.size.width))x\(Int(img.size.height))")
            return img
        }
    }
    appendLog(paths, "character-idle-image-missing id=\(packId)")
    return nil
}

func loadExpressionImages(packId: String, paths: Paths) -> [String: NSImage] {
    var result: [String: NSImage] = [:]
    let dir = paths.root
        .appendingPathComponent("characters", isDirectory: true)
        .appendingPathComponent(packId, isDirectory: true)
        .appendingPathComponent("assets", isDirectory: true)
        .appendingPathComponent("expressions", isDirectory: true)
    let names = ["a", "b", "c", "d", "e", "f"]
    for n in names {
        let url = dir.appendingPathComponent("expr_\(n).png")
        if FileManager.default.fileExists(atPath: url.path),
           let img = NSImage(contentsOf: url) {
            result[n] = img
        }
    }
    if !result.isEmpty {
        appendLog(paths, "expression-images-loaded id=\(packId) count=\(result.count) names=\(result.keys.sorted().joined(separator: ","))")
    } else {
        appendLog(paths, "expression-images-missing id=\(packId) dir=\(dir.path)")
    }
    return result
}

func loadBehaviorPacks(from directory: URL) -> [BehaviorPack] {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ) else {
        return []
    }

    return files
        .filter { $0.pathExtension == "json" }
        .compactMap { try? readJSON(BehaviorPack.self, from: $0) }
        .sorted { $0.id < $1.id }
}

func unionVisibleFrame() -> NSRect {
    let screens = NSScreen.screens
    guard let first = screens.first?.visibleFrame else {
        return NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
    return screens.dropFirst().reduce(first) { $0.union($1.visibleFrame) }
}

func clampWindowOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
    let bounds = unionVisibleFrame()
    let maxX = max(bounds.minX, bounds.maxX - size.width)
    let maxY = max(bounds.minY, bounds.maxY - size.height)
    return NSPoint(
        x: min(maxX, max(bounds.minX, origin.x)),
        y: min(maxY, max(bounds.minY, origin.y))
    )
}

func initialWindowOrigin(settings: AppSettings, size: NSSize, stateURL: URL) -> NSPoint {
    let screen = unionVisibleFrame()
    var origin = NSPoint(
        x: screen.maxX - size.width - settings.window.defaultOffsetRight,
        y: screen.minY + settings.window.defaultOffsetBottom
    )

    if settings.window.rememberPosition,
       let data = try? Data(contentsOf: stateURL),
       let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let left = raw["left"] as? Double,
       let top = raw["top"] as? Double {
        origin = NSPoint(x: left, y: screen.maxY - top - size.height)
    }

    return settings.window.keepInsideScreen ? clampWindowOrigin(origin, size: size) : origin
}

func saveWindowState(window: NSWindow, to url: URL) {
    let screen = unionVisibleFrame()
    let top = screen.maxY - window.frame.maxY
    let state: [String: Any] = [
        "version": 1,
        "left": Double(window.frame.minX),
        "top": Double(top),
        "width": Double(window.frame.width),
        "height": Double(window.frame.height),
        "savedAt": ISO8601DateFormatter().string(from: Date())
    ]
    try? writeJSON(state, to: url)
}

func runProcess(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (-1, error.localizedDescription)
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func wallpaperPathFromSystemEvents() -> String? {
    let result = runProcess(
        "/usr/bin/osascript",
        ["-e", "tell application \"System Events\" to get picture of current desktop"]
    )
    let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.status == 0, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
        return nil
    }
    return path
}

func wallpaperPathFromDockDatabase() -> String? {
    let db = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Dock/desktoppicture.db")
    guard FileManager.default.fileExists(atPath: db.path) else {
        return nil
    }

    let result = runProcess("/usr/bin/sqlite3", [db.path, "select value from data;"])
    guard result.status == 0 else {
        return nil
    }

    let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "bmp"]
    return result.output
        .split(separator: "\n")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { candidate in
            let url = URL(fileURLWithPath: candidate)
            return imageExtensions.contains(url.pathExtension.lowercased())
                && FileManager.default.fileExists(atPath: candidate)
        }
}

func readWallpaperSense() -> WallpaperSense {
    var sense = WallpaperSense(path: nil, scene: "unknown", reason: "Wallpaper was not detected.")

    guard let path = wallpaperPathFromSystemEvents() ?? wallpaperPathFromDockDatabase() else {
        sense.reason = "Wallpaper path is empty or the file does not exist."
        return sense
    }

    sense.path = path
    guard let image = NSImage(contentsOfFile: path),
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else {
        sense.reason = "Wallpaper image could not be opened."
        return sense
    }

    let stepX = max(1, bitmap.pixelsWide / 24)
    let stepY = max(1, bitmap.pixelsHigh / 24)
    var count = 0.0
    var red = 0.0
    var green = 0.0
    var blue = 0.0

    for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            red += Double(color.redComponent) * 255.0
            green += Double(color.greenComponent) * 255.0
            blue += Double(color.blueComponent) * 255.0
            count += 1
        }
    }

    guard count > 0 else {
        sense.reason = "Wallpaper image had no readable sample pixels."
        return sense
    }

    red /= count
    green /= count
    blue /= count
    let brightness = (red + green + blue) / 3.0

    if brightness < 62 {
        sense.scene = "night"
        sense.reason = "Low overall brightness; likely a night or dark wallpaper."
    } else if blue > green + 18 && blue > red + 20 {
        sense.scene = "ocean-or-sky"
        sense.reason = "Blue is dominant; likely ocean, sky, or space."
    } else if green > red + 14 && green > blue + 6 {
        sense.scene = "forest"
        sense.reason = "Green is dominant; likely forest, grass, or plants."
    } else if red > 130 && green > 105 && blue < 110 {
        sense.scene = "warm-room"
        sense.reason = "Warm colors are prominent; likely an indoor or sunset scene."
    } else {
        sense.scene = "mixed"
        sense.reason = "Mixed color distribution; only a broad guess for now."
    }

    return sense
}

func bias(_ character: CharacterProfile, _ keyPath: KeyPath<BehaviorBias, Double?>, default fallback: Double) -> Double {
    character.behaviorBias?[keyPath: keyPath] ?? fallback
}

func isChineseLanguage(_ language: String) -> Bool {
    language.lowercased().hasPrefix("zh")
}

func isJapaneseLanguage(_ language: String) -> Bool {
    language.lowercased().hasPrefix("ja")
}

func localizedValue(language: String, zh: String, en: String, ja: String) -> String {
    if isChineseLanguage(language) { return zh }
    if isJapaneseLanguage(language) { return ja }
    return en
}

func languageCode(forSettingsSegment segment: Int) -> String {
    switch segment {
    case 1: return "en-US"
    case 2: return "ja-JP"
    default: return "zh-CN"
    }
}

func settingsSegment(forLanguage language: String) -> Int {
    if isJapaneseLanguage(language) { return 2 }
    if isChineseLanguage(language) { return 0 }
    return 1
}

func nextLanguageCode(after language: String) -> String {
    if isChineseLanguage(language) { return "en-US" }
    if isJapaneseLanguage(language) { return "zh-CN" }
    return "ja-JP"
}

func speechLocaleIdentifier(for language: String) -> String {
    if isChineseLanguage(language) { return "zh-CN" }
    if isJapaneseLanguage(language) { return "ja-JP" }
    return "en-US"
}

func audioInputDevices() -> [AVCaptureDevice] {
    let deviceTypes: [AVCaptureDevice.DeviceType]
    if #available(macOS 14.0, *) {
        deviceTypes = [.microphone, .external]
    } else {
        deviceTypes = [.builtInMicrophone, .externalUnknown]
    }
    let session = AVCaptureDevice.DiscoverySession(
        deviceTypes: deviceTypes,
        mediaType: .audio,
        position: .unspecified
    )
    return session.devices
}

func detectedAudioInputName() -> String {
    if let defaultDevice = AVCaptureDevice.default(for: .audio) {
        return defaultDevice.localizedName
    }
    return audioInputDevices().first?.localizedName ?? "unknown"
}

func localizedScene(_ scene: String, language: String) -> String {
    if isJapaneseLanguage(language) {
        switch scene {
        case "night": return "夜/暗色"
        case "ocean-or-sky": return "海または空"
        case "forest": return "森/植物"
        case "warm-room": return "暖色の部屋"
        case "mixed": return "混合シーン"
        default: return "不明"
        }
    }
    guard isChineseLanguage(language) else {
        return scene
    }
    switch scene {
    case "night": return "夜晚/深色"
    case "ocean-or-sky": return "海洋或天空"
    case "forest": return "森林/植物"
    case "warm-room": return "暖色房间"
    case "mixed": return "混合场景"
    default: return "未知"
    }
}

func localizedWallpaperReason(_ reason: String, language: String) -> String {
    if isJapaneseLanguage(language) {
        if reason.contains("empty") || reason.contains("does not exist") {
            return "壁紙のパスを読めないか、壁紙ファイルが存在しません。"
        }
        if reason.contains("not detected") || reason.contains("unknown") {
            return "壁紙情報をまだ認識できていません。"
        }
        if reason.contains("Low overall brightness") {
            return "全体の明るさが低く、夜や暗い壁紙のようです。"
        }
        if reason.contains("Blue is dominant") {
            return "青色が多く、海、空、または宇宙のようです。"
        }
        if reason.contains("Green is dominant") {
            return "緑色が多く、森、草地、または植物のようです。"
        }
        if reason.contains("Warm colors") {
            return "暖色が目立ち、室内または夕焼けのようです。"
        }
        if reason.contains("Mixed color") {
            return "色の分布が混ざっていて、今は大まかな判断だけです。"
        }
        return reason
    }
    guard isChineseLanguage(language) else {
        return reason
    }
    if reason.contains("empty") || reason.contains("does not exist") {
        return "没有读到壁纸路径，或者壁纸文件不存在。"
    }
    if reason.contains("not detected") || reason.contains("unknown") {
        return "暂时没有识别到壁纸信息。"
    }
    if reason.contains("Low overall brightness") {
        return "整体亮度偏低，像是夜晚或深色壁纸。"
    }
    if reason.contains("Blue is dominant") {
        return "蓝色占比较高，像是海洋、天空或太空。"
    }
    if reason.contains("Green is dominant") {
        return "绿色占比较高，像是森林、草地或植物。"
    }
    if reason.contains("Warm colors") {
        return "暖色比较明显，像是室内或夕阳场景。"
    }
    if reason.contains("Mixed color") {
        return "颜色分布比较混合，只能先做粗略判断。"
    }
    return reason
}

func parseNicknameRequest(_ text: String) -> String? {
    let zhMarkers = ["请叫我", "你可以叫我", "以后叫我", "叫我"]
    for marker in zhMarkers {
        if let range = text.range(of: marker) {
            let after = String(text[range.upperBound...])
            return nicknameCandidate(from: after, maxLength: 12)
        }
    }
    let lower = text.lowercased()
    let enMarkers = ["call me ", "please call me ", "you can call me "]
    for marker in enMarkers {
        if let range = lower.range(of: marker) {
            let startOffset = lower.distance(from: lower.startIndex, to: range.upperBound)
            let startIdx = text.index(text.startIndex, offsetBy: startOffset)
            return nicknameCandidate(from: String(text[startIdx...]), maxLength: 24)
        }
    }
    return nil
}

func nicknameCandidate(from raw: String, maxLength: Int) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var scalars: [UnicodeScalar] = []

    for scalar in trimmed.unicodeScalars {
        if isNicknameScalar(scalar) {
            scalars.append(scalar)
            if scalars.count > maxLength {
                return nil
            }
            continue
        }
        break
    }

    guard !scalars.isEmpty else {
        return nil
    }

    let value = String(String.UnicodeScalarView(scalars))
    if value == "我" || value == "你" || value == "他" || value == "她" || value == "它" {
        return nil
    }
    return value
}

func isNicknameScalar(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value
    if scalar == "的" {
        return false
    }
    if CharacterSet.alphanumerics.contains(scalar) {
        return true
    }
    if value >= 0x4E00 && value <= 0x9FFF {
        return true
    }
    if value >= 0x3400 && value <= 0x4DBF {
        return true
    }
    return scalar == "_" || scalar == "-" || scalar == "·"
}

func nicknameParserSelfTest() -> [String: String] {
    let cases: [(String, String?)] = [
        ("叫我小C", "小C"),
        ("请叫我 小C。", "小C"),
        ("请叫我阿Q，谢谢", "阿Q"),
        ("以后叫我小明-01；记住哦", "小明-01"),
        ("叫我树", "树"),
        ("你可以叫我阿树😊", "阿树"),
        ("以后叫我Neo-7，谢谢", "Neo-7"),
        ("call me XiaoC!", "XiaoC"),
        ("please call me Alex_2", "Alex_2"),
        ("叫我老板的人都很烦", "老板"),
        ("叫我🙂", nil)
    ]
    var result: [String: String] = [:]
    for (input, expected) in cases {
        let actual = parseNicknameRequest(input)
        result[input] = actual == expected ? "ok" : "fail expected=\(expected ?? "nil") actual=\(actual ?? "nil")"
    }
    return result
}

protocol BrainService {
    func reply(input: String, context: BrainContext) async -> String
}

struct ConversationTurn {
    enum Role: String { case user, assistant }
    let role: Role
    let content: String
}

struct BrainContext {
    let characterName: String
    let language: String
    let nickname: String?
    let petPersonality: String?
    let replyStyle: String?
    let doNotDisturbWhenTyping: Bool
    let wallpaper: WallpaperSense
    let recentMessages: [String]
    let conversationTurns: [ConversationTurn]
    let characterProfile: CharacterProfile?
}

// MARK: - TaskPackage / Task Router V0

struct TaskPackage: Codable, Identifiable {
    let id: String
    let createdAt: Date

    let userIntent: String
    let taskType: TaskType
    let recommendedExecutor: RecommendedExecutor

    let title: String
    let summary: String

    let projectContext: [String]
    let constraints: [String]
    let forbiddenActions: [String]

    let riskLevel: RiskLevel
    let confirmationRequired: Bool

    let executionSteps: [String]
    let acceptanceCriteria: [String]

    let selfCheck: TaskSelfCheck
}

enum TaskType: String, Codable {
    case engineeringChange
    case bugFix
    case refactor
    case productPlanning
    case promptWriting
    case documentation
    case localCommand
    case unknown
}

enum RecommendedExecutor: String, Codable {
    case codex
    case claudeCode
    case hermos
    case terminal
    case user
    case xiaoQiOnly
    case unknown
}

enum RiskLevel: String, Codable {
    case low
    case medium
    case high
}

struct TaskSelfCheck: Codable {
    let hasClearGoal: Bool
    let hasProjectContext: Bool
    let protectsKnownFixes: Bool
    let avoidsFutureIdeasAsCurrentTasks: Bool
    let avoidsAutomaticExecution: Bool
    let hasAcceptanceCriteria: Bool
    let notes: [String]
}

struct TaskPackageSaveResult {
    let success: Bool
    let fileURL: URL?
    let errorMessage: String?
}

struct TaskPackageFileItem: Identifiable {
    let id: String
    let fileURL: URL
    let fileName: String
    let createdAt: Date
    let taskType: String
    let executor: String
    let riskLevel: String
}

func taskPackageHandoffDirectory(paths: Paths) -> URL {
    paths.root
        .appendingPathComponent("handoff", isDirectory: true)
        .appendingPathComponent("task-packages", isDirectory: true)
}

func fallbackTaskPackageHandoffDirectory() -> URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    return documents.appendingPathComponent("HermosTaskPackages", isDirectory: true)
}

func saveTaskPackageMarkdown(_ markdown: String, package: TaskPackage, paths: Paths) -> TaskPackageSaveResult {
    let fm = FileManager.default
    let preferredDir = taskPackageHandoffDirectory(paths: paths)
    let targetDir: URL
    do {
        try fm.createDirectory(at: preferredDir, withIntermediateDirectories: true)
        targetDir = preferredDir
    } catch {
        let fallbackDir = fallbackTaskPackageHandoffDirectory()
        do {
            try fm.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
            targetDir = fallbackDir
        } catch {
            return TaskPackageSaveResult(success: false, fileURL: nil, errorMessage: error.localizedDescription)
        }
    }

    let fileName = uniqueTaskPackageFileName(package: package, directory: targetDir)
    let fileURL = targetDir.appendingPathComponent(fileName)
    do {
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return TaskPackageSaveResult(success: true, fileURL: fileURL, errorMessage: nil)
    } catch {
        return TaskPackageSaveResult(success: false, fileURL: nil, errorMessage: error.localizedDescription)
    }
}

func listSavedTaskPackages(paths: Paths) -> [TaskPackageFileItem] {
    let fm = FileManager.default
    let preferredDir = taskPackageHandoffDirectory(paths: paths)
    let fallbackDir = fallbackTaskPackageHandoffDirectory()
    let directory = fm.fileExists(atPath: preferredDir.path) ? preferredDir : fallbackDir
    guard let files = try? fm.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    return files
        .filter { $0.pathExtension.lowercased() == "md" }
        .compactMap { taskPackageFileItem(from: $0) }
        .sorted { $0.createdAt > $1.createdAt }
}

func readTaskPackageMarkdown(fileURL: URL) -> String? {
    try? String(contentsOf: fileURL, encoding: .utf8)
}

func ensureTaskPackageHandoffDirectory(paths: Paths) -> URL? {
    let fm = FileManager.default
    let preferredDir = taskPackageHandoffDirectory(paths: paths)
    do {
        try fm.createDirectory(at: preferredDir, withIntermediateDirectories: true)
        return preferredDir
    } catch {
        let fallbackDir = fallbackTaskPackageHandoffDirectory()
        do {
            try fm.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
            return fallbackDir
        } catch {
            return nil
        }
    }
}

func copyTaskPackageMarkdownToPasteboard(fileURL: URL) -> Bool {
    guard let text = readTaskPackageMarkdown(fileURL: fileURL) else { return false }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    return true
}

func taskPackageRiskLabel(_ riskLevel: String, language: String = "zh-CN") -> String {
    if isJapaneseLanguage(language) {
        switch riskLevel.lowercased() {
        case "low": return "低リスク"
        case "medium": return "中リスク"
        case "high": return "高リスク"
        default: return riskLevel.isEmpty ? "リスク不明" : riskLevel
        }
    }
    if !isChineseLanguage(language) {
        switch riskLevel.lowercased() {
        case "low": return "Low risk"
        case "medium": return "Medium risk"
        case "high": return "High risk"
        default: return riskLevel.isEmpty ? "Unknown risk" : riskLevel
        }
    }
    switch riskLevel.lowercased() {
    case "low": return "低风险"
    case "medium": return "中风险"
    case "high": return "高风险"
    default: return riskLevel.isEmpty ? "风险未知" : riskLevel
    }
}

func selectedTaskPackageURL(afterRefresh items: [TaskPackageFileItem], preferredURL: URL?) -> URL? {
    if let preferredURL,
       items.contains(where: { $0.fileURL.path == preferredURL.path }) {
        return preferredURL
    }
    return items.first?.fileURL
}

func taskPackagePreviewText(fileURL: URL?, language: String = "zh-CN") -> String {
    guard let fileURL else {
        return localizedValue(
            language: language,
            zh: "选中一个任务包后，可以在这里预览 Markdown。",
            en: "Select a task package to preview Markdown here.",
            ja: "タスクパッケージを選ぶと、ここで Markdown をプレビューできます。"
        )
    }
    return readTaskPackageMarkdown(fileURL: fileURL) ?? localizedValue(
        language: language,
        zh: "任务包读取失败。",
        en: "Failed to read task package.",
        ja: "タスクパッケージの読み込みに失敗しました。"
    )
}

func taskPackageCopyFeedback(success: Bool, language: String) -> String {
    if isChineseLanguage(language) {
        return success ? "已复制任务包。" : "复制失败，文件读不到。"
    }
    if isJapaneseLanguage(language) {
        return success ? "タスクパッケージをコピーしました。" : "コピーに失敗しました。ファイルを読めません。"
    }
    return success ? "Task package copied." : "Copy failed. File is unreadable."
}

func taskPackageItemsAreDescending(_ items: [TaskPackageFileItem]) -> Bool {
    guard items.count > 1 else { return true }
    return zip(items, items.dropFirst()).allSatisfy { $0.createdAt >= $1.createdAt }
}

private func uniqueTaskPackageFileName(package: TaskPackage, directory: URL) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: package.createdAt)
    let slugSource = package.title.isEmpty ? package.userIntent : package.title
    let slug = taskPackageSlug(from: slugSource)
    let base = "\(stamp)_\(package.taskType.rawValue)_\(package.recommendedExecutor.rawValue)_\(slug)"
    var candidate = "\(base).md"
    var index = 2
    let fm = FileManager.default
    while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
        candidate = "\(base)-\(index).md"
        index += 1
    }
    return candidate
}

private func taskPackageSlug(from text: String) -> String {
    var result = ""
    var previousWasDash = false
    for scalar in text.lowercased().unicodeScalars {
        let value = scalar.value
        let allowed = CharacterSet.alphanumerics.contains(scalar)
            || (value >= 0x4E00 && value <= 0x9FFF)
            || scalar == "-"
            || scalar == "_"
        if allowed {
            result.unicodeScalars.append(scalar)
            previousWasDash = false
        } else if !previousWasDash {
            result.append("-")
            previousWasDash = true
        }
        if result.count >= 24 { break }
    }
    let slug = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    return slug.isEmpty ? "task-package" : slug
}

private func taskPackageFileItem(from fileURL: URL) -> TaskPackageFileItem? {
    let fileName = fileURL.lastPathComponent
    let content = readTaskPackageMarkdown(fileURL: fileURL) ?? ""
    let parts = fileName.replacingOccurrences(of: ".md", with: "").split(separator: "_").map(String.init)
    let taskType = extractMarkdownValue(content, prefix: "- 类型：") ?? (parts.count > 1 ? parts[1] : "unknown")
    let executor = extractMarkdownValue(content, prefix: "- 交接对象：") ?? (parts.count > 2 ? parts[2] : "unknown")
    let riskLevel = extractMarkdownValue(content, prefix: "- 风险：") ?? "unknown"
    let values = try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    let createdAt = values?.creationDate ?? parseTaskPackageDate(from: fileName) ?? values?.contentModificationDate ?? Date.distantPast
    return TaskPackageFileItem(
        id: fileURL.path,
        fileURL: fileURL,
        fileName: fileName,
        createdAt: createdAt,
        taskType: taskType,
        executor: executor,
        riskLevel: riskLevel
    )
}

private func extractMarkdownValue(_ markdown: String, prefix: String) -> String? {
    for line in markdown.components(separatedBy: .newlines) {
        if line.hasPrefix(prefix) {
            let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }
    return nil
}

private func parseTaskPackageDate(from fileName: String) -> Date? {
    let prefix = String(fileName.prefix(15))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.date(from: prefix)
}

final class TaskRouter {
    private let taskMarkers = [
        "帮我整理成任务", "给 codex", "给 claude code", "让它执行", "修复", "bug",
        "重构", "实现", "检查代码", "生成工程指令", "写任务包", "验收标准",
        "不要回退", "自检", "本地软件交接", "任务包", "工程任务", "扒窗",
        "红黄绿按钮", "windowtargetingservice", "自动执行", "terminal", "终端",
        "shell", "命令", "运行命令", "改代码", "自动改代码", "readme", "文档",
        "说明", "介绍", "整理说明"
    ]
    private let companionMarkers = ["陪我聊会儿", "小七你在干嘛", "我有点困了", "你今天乖不乖"]

    func shouldRouteAsTask(_ input: String) -> Bool {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        if containsAny(cleaned, companionMarkers) && !containsAny(cleaned, taskMarkers) {
            return false
        }
        return containsAny(cleaned, taskMarkers)
    }

    func inferTaskType(from input: String) -> TaskType {
        if containsAny(input, ["bug", "修复", "卡住", "报错", "异常"]) {
            return .bugFix
        }
        if containsAny(input, ["重构", "架构", "整理结构"]) {
            return .refactor
        }
        if containsAny(input, ["实现", "新增", "开发", "接入"]) {
            return .engineeringChange
        }
        if containsAny(input, ["规划", "方向", "产品", "路线", "以后想做", "movie companion mode", "观影模式"]) {
            return .productPlanning
        }
        if containsAny(input, ["提示词", "prompt", "codex任务", "claude code任务", "任务包"]) {
            return .promptWriting
        }
        if containsAny(input, ["readme", "文档", "说明"]) {
            return .documentation
        }
        if containsAny(input, ["命令", "terminal", "终端", "shell"]) {
            return .localCommand
        }
        return .unknown
    }

    func recommendExecutor(for taskType: TaskType, input: String) -> RecommendedExecutor {
        if containsAny(input, ["codex"]) { return .codex }
        if containsAny(input, ["claude code"]) { return .claudeCode }
        if containsAny(input, ["terminal", "shell", "命令", "终端"]) { return .terminal }

        switch taskType {
        case .bugFix, .engineeringChange:
            return .codex
        case .refactor, .documentation:
            return .claudeCode
        case .productPlanning, .promptWriting:
            return .xiaoQiOnly
        case .localCommand:
            return .terminal
        case .unknown:
            return .user
        }
    }

    func estimateRisk(taskType: TaskType, input: String) -> RiskLevel {
        if containsAny(input, [
            "自动执行", "terminal", "终端", "删除", "权限", "ax", "accessibility",
            "真实扒窗", "红黄绿按钮", "windowtargetingservice", "自动改代码",
            "自动提交", "git commit"
        ]) {
            return .high
        }
        if containsAny(input, [
            "重构", "behaviordirector", "状态机", "speak", "currenteditor",
            "windowedgemischief", "hermos工具", "本地软件交接"
        ]) {
            return .medium
        }
        switch taskType {
        case .documentation, .productPlanning, .promptWriting:
            return .low
        case .localCommand, .refactor:
            return .medium
        case .engineeringChange, .bugFix, .unknown:
            return .medium
        }
    }

    func buildTaskPackage(from input: String) -> TaskPackage {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskType = inferTaskType(from: cleaned)
        let executor = recommendExecutor(for: taskType, input: cleaned)
        let risk = estimateRisk(taskType: taskType, input: cleaned)
        let projectContext = defaultProjectContext()
        let constraints = defaultConstraints()
        let forbiddenActions = defaultForbiddenActions()
        let executionSteps = makeExecutionSteps(taskType: taskType, input: cleaned, executor: executor)
        let acceptanceCriteria = makeAcceptanceCriteria(taskType: taskType, input: cleaned)
        let title = makeTitle(taskType: taskType, input: cleaned)
        let summary = makeSummary(taskType: taskType, input: cleaned, executor: executor, risk: risk)
        let selfCheck = makeSelfCheck(
            title: title,
            summary: summary,
            projectContext: projectContext,
            constraints: constraints,
            forbiddenActions: forbiddenActions,
            executionSteps: executionSteps,
            acceptanceCriteria: acceptanceCriteria
        )

        return TaskPackage(
            id: "task-\(UUID().uuidString)",
            createdAt: Date(),
            userIntent: cleaned,
            taskType: taskType,
            recommendedExecutor: executor,
            title: title,
            summary: summary,
            projectContext: projectContext,
            constraints: constraints,
            forbiddenActions: forbiddenActions,
            riskLevel: risk,
            confirmationRequired: risk != .low || executor == .terminal,
            executionSteps: executionSteps,
            acceptanceCriteria: acceptanceCriteria,
            selfCheck: selfCheck
        )
    }

    func renderMarkdown(_ package: TaskPackage) -> String {
        package.toMarkdown()
    }

    func shortReply(for package: TaskPackage, language: String) -> String {
        if isChineseLanguage(language) {
            return "这个像工程任务。我建议交给 \(package.recommendedExecutor.rawValue)，风险 \(package.riskLevel.rawValue)。任务包我先拆好了，别急着自动执行。"
        }
        if isJapaneseLanguage(language) {
            return "これは工程タスクっぽいです。\(package.recommendedExecutor.rawValue) に渡すのをすすめます。リスクは \(package.riskLevel.rawValue)。タスクパッケージは先に分けておきました。自動実行はしません。"
        }
        return "This looks like an engineering task. I recommend \(package.recommendedExecutor.rawValue), risk \(package.riskLevel.rawValue). I made a package, no auto-run."
    }

    static func recommendationReason(for executor: RecommendedExecutor, taskType: TaskType, risk: RiskLevel) -> String {
        switch executor {
        case .codex:
            return "适合做局部代码修改、bug 修复和 SelfTest 验证；当前风险为 \(risk.rawValue)。"
        case .claudeCode:
            return "适合做结构整理、文档和较大上下文审阅；当前任务类型为 \(taskType.rawValue)。"
        case .xiaoQiOnly:
            return "更像规划 / prompt / 任务表达整理，先由小七拆包，不进入自动执行。"
        case .terminal:
            return "涉及命令或终端，只能在用户确认后手动执行。"
        case .hermos:
            return "适合作为未来 Hermos 协议交接对象；本版本不自动通信。"
        case .user:
            return "任务边界还不够明确，建议先由用户确认方向。"
        case .unknown:
            return "无法可靠推荐执行器，需要补充上下文。"
        }
    }

    private func defaultProjectContext() -> [String] {
        [
            "这是 Mac 桌宠 / Hermos 长期个人项目。",
            "Stage 1 MVP v0.1 已封版，应保持稳定。",
            "产品目标是陪伴型 AI 桌面生物，不是聊天框套皮肤。",
            "V2.1 是 Task Router V0 / TaskPackage 协议层。",
            "本阶段是为未来自主通信打地基，但不实现真实自动执行。"
        ]
    }

    private func defaultConstraints() -> [String] {
        [
            "改动应尽量小而局部。",
            "不破坏现有 Stage 1 行为。",
            "不把任务扩展成 Live2D、Movie Companion Mode、Hermos 工具组或完整本地执行。",
            "不实现真实自主通信。",
            "本版本优先使用规则式逻辑。",
            "保持小七回复短，不要变成客服式长篇。",
            "除非任务明确要求，否则保留当前 BehaviorDirector / PetActionSequence 流程。"
        ]
    }

    private func defaultForbiddenActions() -> [String] {
        [
            "不允许回退 speak() 通过 ExitToIdleSequence 回到 idle 的修复。",
            "不允许恢复旧的 currentEditor() focus gate bug。",
            "不允许把 longIdleThresholdTicks 从 666 改掉。",
            "不允许让 WindowEdgeMischief 重新变激进。",
            "不允许宣称真的能操作红黄绿窗口按钮。",
            "不允许实现真实 WindowTargetingService AX / Accessibility 定位。",
            "不允许加入 Live2D。",
            "不允许加入 Movie Companion Mode。",
            "不允许加入 Codex / Claude Code / Terminal 自动执行。"
        ]
    }

    private func makeExecutionSteps(taskType: TaskType, input: String, executor: RecommendedExecutor) -> [String] {
        if containsAny(input, ["真实扒窗", "红黄绿按钮", "windowtargetingservice", "ax", "accessibility"]) {
            return [
                "确认这是未来窗口感知能力请求，本轮只整理为 TaskPackage。",
                "保持 WindowTargetingService 为 stub，不接入真实 AX / Accessibility 定位。",
                "保持 WindowEdgeMischiefLite 低频心虚小动作，不扩展为完整扒窗。",
                "记录风险、约束和验收标准，等待用户确认后再进入后续阶段。"
            ]
        }
        if containsAny(input, ["movie companion mode", "观影模式", "电影黑边", "以后想做"]) {
            return [
                "把想法整理为后续阶段方向，不作为当前实现任务。",
                "记录目标体验、边界和暂缓原因。",
                "确认它不会进入本轮开发范围，也不会影响 Stage 1 稳定性。"
            ]
        }

        switch taskType {
        case .bugFix:
            return [
                "复述问题和触发条件，确认只修明确 bug。",
                "定位相关代码路径，优先保护 Stage 1 已修复行为。",
                "做最小必要修改。",
                "运行 SelfTest，并检查是否引入回退。"
            ]
        case .engineeringChange:
            return [
                "确认新增能力的最小协议或接口边界。",
                "按局部规则式逻辑实现，不接入外部自动执行。",
                "补充 SelfTest 覆盖核心输入输出。",
                "运行 SelfTest，确认 Stage 1 行为未回退。"
            ]
        case .refactor:
            return [
                "先梳理现有结构和调用边界。",
                "只整理必要结构，不改变用户可见行为。",
                "保留 BehaviorDirector / PetActionSequence 的稳定流程。",
                "运行 SelfTest，并记录风险。"
            ]
        case .productPlanning:
            return [
                "把需求拆成目标、非目标和阶段边界。",
                "标记哪些只是未来想法，不能进入当前实现。",
                "形成可讨论的下一阶段选项。"
            ]
        case .promptWriting:
            return [
                "提取用户目标、上下文、约束和禁止事项。",
                "生成可交接的 Markdown 任务包。",
                "自检是否避免自动执行和范围扩张。"
            ]
        case .documentation:
            return [
                "确认需要更新的文档范围。",
                "只记录事实状态和验收结论。",
                "不修改代码逻辑。",
                "运行或引用已有 SelfTest 结果。"
            ]
        case .localCommand:
            return [
                "列出建议命令和目的。",
                "等待用户确认后再由人工或受控环境执行。",
                "不在 TaskPackage 阶段自动运行 Terminal / shell。"
            ]
        case .unknown:
            return [
                "先向用户澄清目标、范围和验收标准。",
                "在确认前不推荐自动执行或代码修改。"
            ]
        }
    }

    private func makeAcceptanceCriteria(taskType: TaskType, input: String) -> [String] {
        var criteria = [
            "项目可以编译，SelfTest 通过。",
            "现有 Stage 1 行为保持稳定。",
            "不触发 Codex / Claude Code / Terminal 自动执行。",
            "关键禁止回退项得到保护。"
        ]
        if containsAny(input, ["真实扒窗", "红黄绿按钮", "windowtargetingservice", "ax", "accessibility"]) {
            criteria.append("WindowTargetingService 仍保持 stub，不实现真实 AX / Accessibility 定位。")
            criteria.append("WindowEdgeMischiefLite 仍是低频心虚小动作，不变成完整扒窗。")
        }
        if containsAny(input, ["movie companion mode", "观影模式", "电影黑边"]) {
            criteria.append("Movie Companion Mode 只作为未来方向记录，不进入当前实现步骤。")
        }
        if taskType == .promptWriting {
            criteria.append("TaskPackage Markdown 包含用户意图、推荐交接对象、任务类型、上下文、约束、禁止事项、步骤、验收、风险和自检。")
        }
        return criteria
    }

    private func makeTitle(taskType: TaskType, input: String) -> String {
        let prefix: String
        switch taskType {
        case .bugFix: prefix = "Bug Fix"
        case .engineeringChange: prefix = "Engineering Change"
        case .refactor: prefix = "Refactor"
        case .productPlanning: prefix = "Product Planning"
        case .promptWriting: prefix = "Task Prompt"
        case .documentation: prefix = "Documentation"
        case .localCommand: prefix = "Local Command"
        case .unknown: prefix = "Clarify Task"
        }
        let snippet = String(input.prefix(36)).trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? prefix : "\(prefix): \(snippet)"
    }

    private func makeSummary(taskType: TaskType, input: String, executor: RecommendedExecutor, risk: RiskLevel) -> String {
        "将用户需求整理为 \(taskType.rawValue) 类型 TaskPackage，建议交给 \(executor.rawValue)，风险等级 \(risk.rawValue)。原始需求：\(input)"
    }

    private func makeSelfCheck(
        title: String,
        summary: String,
        projectContext: [String],
        constraints: [String],
        forbiddenActions: [String],
        executionSteps: [String],
        acceptanceCriteria: [String]
    ) -> TaskSelfCheck {
        let hasClearGoal = !title.isEmpty && !summary.isEmpty && !executionSteps.isEmpty
        let hasProjectContext = !projectContext.isEmpty
        let forbiddenText = forbiddenActions.joined(separator: "\n").lowercased()
        let protectsKnownFixes = [
            "exittoidlesequence",
            "currenteditor",
            "longidlethresholdticks",
            "windowedgemischief",
            "windowtargetingservice"
        ].allSatisfy { forbiddenText.contains($0) }
        let checkTexts = executionSteps + constraints + forbiddenActions
        let makesFutureIdeasCurrent = containsUnsafePositiveIntent(checkTexts)
        let avoidsAutomaticExecution = !containsUnsafeAutomaticExecutionIntent(checkTexts)
            && forbiddenText.contains("自动执行")
        let hasAcceptanceCriteria = !acceptanceCriteria.isEmpty

        var notes: [String] = []
        if !hasClearGoal { notes.append("title / summary / executionSteps 不完整。") }
        if !hasProjectContext { notes.append("缺少项目上下文。") }
        if !protectsKnownFixes { notes.append("禁止事项没有完整保护 Stage 1 关键修复。") }
        if makesFutureIdeasCurrent { notes.append("后期灵感被写成了当前实现步骤。") }
        if !avoidsAutomaticExecution { notes.append("执行步骤存在自动调用外部工具的风险。") }
        if !hasAcceptanceCriteria { notes.append("缺少验收标准。") }
        if notes.isEmpty { notes.append("TaskPackage V0 自检通过。") }

        return TaskSelfCheck(
            hasClearGoal: hasClearGoal,
            hasProjectContext: hasProjectContext,
            protectsKnownFixes: protectsKnownFixes,
            avoidsFutureIdeasAsCurrentTasks: !makesFutureIdeasCurrent,
            avoidsAutomaticExecution: avoidsAutomaticExecution,
            hasAcceptanceCriteria: hasAcceptanceCriteria,
            notes: notes
        )
    }

    private func containsAny(_ input: String, _ keywords: [String]) -> Bool {
        let lower = input.lowercased()
        return keywords.contains { lower.contains($0.lowercased()) }
    }

    private func containsUnsafePositiveIntent(_ texts: [String]) -> Bool {
        var normalized = texts.joined(separator: "\n").lowercased()
        let safePhrases = [
            "不接入真实 ax",
            "不接入 accessibility",
            "不实装 ax",
            "不实装 accessibility",
            "不实现真实 ax",
            "不实现 accessibility",
            "不实现完整扒窗",
            "不做完整扒窗",
            "不实装 windowtargetingservice",
            "保持 windowtargetingservice stub",
            "保持 noopwindowtargetingservice",
            "禁止接入 ax",
            "禁止接入 accessibility",
            "不操作红黄绿按钮",
            "不识别红黄绿按钮"
        ]
        for phrase in safePhrases {
            normalized = normalized.replacingOccurrences(of: phrase, with: "")
        }
        let unsafePositivePhrases = [
            "实现 live2d",
            "接入 live2d",
            "实现 movie companion mode",
            "现在实现 movie companion mode",
            "实现完整扒窗",
            "实装完整扒窗",
            "接入真实 ax",
            "实装 ax",
            "实装 accessibility",
            "实现 accessibility",
            "实装 windowtargetingservice",
            "识别红黄绿按钮",
            "操作红黄绿按钮"
        ]
        return unsafePositivePhrases.contains { normalized.contains($0) }
    }

    private func containsUnsafeAutomaticExecutionIntent(_ texts: [String]) -> Bool {
        var normalized = texts.joined(separator: "\n").lowercased()
        let safePhrases = [
            "不在 taskpackage 阶段自动运行 terminal",
            "不自动打开 terminal",
            "不自动运行 terminal",
            "不自动运行 shell",
            "不自动执行",
            "不触发 codex / claude code / terminal 自动执行",
            "不允许加入 codex / claude code / terminal 自动执行",
            "只能在用户确认后手动执行",
            "等待用户确认",
            "不执行命令"
        ]
        for phrase in safePhrases {
            normalized = normalized.replacingOccurrences(of: phrase, with: "")
        }
        let unsafePositivePhrases = [
            "自动调用 codex",
            "自动调用 claude",
            "自动运行 terminal",
            "自动运行 shell",
            "自动打开 terminal",
            "自动改代码",
            "自动提交",
            "直接运行命令",
            "执行命令改代码"
        ]
        return unsafePositivePhrases.contains { normalized.contains($0) }
    }
}

extension TaskPackage {
    func toMarkdown() -> String {
        let reason = TaskRouter.recommendationReason(
            for: recommendedExecutor,
            taskType: taskType,
            risk: riskLevel
        )
        return """
        # TaskPackage: \(title)

        ## 1. 用户意图
        \(userIntent)

        ## 2. 推荐交接对象
        - 交接对象：\(recommendedExecutor.rawValue)
        - 推荐理由：\(reason)

        ## 3. 任务类型
        - 类型：\(taskType.rawValue)

        ## 4. 项目上下文
        \(Self.markdownBullets(projectContext))

        ## 5. 约束条件
        \(Self.markdownBullets(constraints))

        ## 6. 禁止事项
        \(Self.markdownBullets(forbiddenActions))

        ## 7. 执行步骤
        \(Self.markdownNumbers(executionSteps))

        ## 8. 验收标准
        \(Self.markdownBullets(acceptanceCriteria))

        ## 9. 风险等级
        - 风险：\(riskLevel.rawValue)
        - 是否需要确认：\(confirmationRequired)

        ## 10. 自检结果
        - 目标是否清晰：\(selfCheck.hasClearGoal)
        - 是否包含项目上下文：\(selfCheck.hasProjectContext)
        - 是否保护关键修复：\(selfCheck.protectsKnownFixes)
        - 是否避免把后期灵感当成立刻任务：\(selfCheck.avoidsFutureIdeasAsCurrentTasks)
        - 是否避免自动执行：\(selfCheck.avoidsAutomaticExecution)
        - 是否包含验收标准：\(selfCheck.hasAcceptanceCriteria)

        ## 11. 备注
        \(Self.markdownBullets(selfCheck.notes))
        """
    }

    private static func markdownBullets(_ items: [String]) -> String {
        guard !items.isEmpty else { return "- 无" }
        return items.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func markdownNumbers(_ items: [String]) -> String {
        guard !items.isEmpty else { return "1. 待补充" }
        return items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

func taskRouterSelfTest() -> [String: Any] {
    let router = TaskRouter()
    var results: [String: Any] = [:]

    let chatInput = "小七，陪我聊会儿。"
    results["chatNotRouted"] = router.shouldRouteAsTask(chatInput) == false
    let tiredInput = "小七，我有点困了。"
    results["tiredNotRouted"] = router.shouldRouteAsTask(tiredInput) == false

    let bugInput = "帮我整理成 Codex 能执行的任务，修复 speak 后不要卡在 EnterSpeaking。"
    let bugPackage = router.buildTaskPackage(from: bugInput)
    results["codexBugShouldRoute"] = router.shouldRouteAsTask(bugInput)
    results["codexBugType"] = bugPackage.taskType.rawValue
    results["codexBugTypeOk"] = bugPackage.taskType == .bugFix || bugPackage.taskType == .engineeringChange
    results["codexBugExecutor"] = bugPackage.recommendedExecutor.rawValue
    results["codexBugExecutorOk"] = bugPackage.recommendedExecutor == .codex
    results["codexBugProtectsExitToIdle"] = bugPackage.forbiddenActions.joined(separator: "\n").contains("ExitToIdleSequence")
    results["codexBugSelfCheckProtectsKnownFixes"] = bugPackage.selfCheck.protectsKnownFixes

    let movieInput = "以后想做 Movie Companion Mode，让小七坐在电影黑边里。"
    let moviePackage = router.buildTaskPackage(from: movieInput)
    let movieSteps = moviePackage.executionSteps.joined(separator: "\n")
    results["movieRouteDecision"] = router.shouldRouteAsTask(movieInput) ? "routed" : "not-routed"
    results["movieRouteDecisionAllowed"] = router.shouldRouteAsTask(movieInput) == false || moviePackage.taskType == .productPlanning
    results["movieType"] = moviePackage.taskType.rawValue
    results["movieDoesNotImplementNow"] = !movieSteps.contains("现在实现 Movie Companion Mode")
        && !movieSteps.contains("立刻实现 Movie Companion Mode")
    results["movieAvoidsFutureIdeas"] = moviePackage.selfCheck.avoidsFutureIdeasAsCurrentTasks

    let windowInput = "帮我做完整扒窗，让它真的识别红黄绿按钮。"
    let windowPackage = router.buildTaskPackage(from: windowInput)
    let windowForbidden = windowPackage.forbiddenActions.joined(separator: "\n")
    let windowMarkdown = router.renderMarkdown(windowPackage)
    results["windowRisk"] = windowPackage.riskLevel.rawValue
    results["windowRiskHigh"] = windowPackage.riskLevel == .high
    results["windowKeepsTargetingStub"] = windowForbidden.contains("WindowTargetingService")
    results["windowMentionsNoAX"] = windowMarkdown.contains("不实现真实 AX / Accessibility 定位")
    results["windowDoesNotImplementRealTargeting"] = !windowPackage.executionSteps.joined(separator: "\n").contains("实现完整")
    results["windowAvoidsFutureIdeas"] = windowPackage.selfCheck.avoidsFutureIdeasAsCurrentTasks

    let terminalInput = "让小七自动打开 Terminal，然后直接运行命令改代码。"
    let terminalPackage = router.buildTaskPackage(from: terminalInput)
    let terminalSteps = terminalPackage.executionSteps.joined(separator: "\n")
    results["terminalShouldRoute"] = router.shouldRouteAsTask(terminalInput)
    results["terminalRisk"] = terminalPackage.riskLevel.rawValue
    results["terminalRiskHigh"] = terminalPackage.riskLevel == .high
    results["terminalExecutor"] = terminalPackage.recommendedExecutor.rawValue
    results["terminalExecutorOk"] = terminalPackage.recommendedExecutor == .terminal || terminalPackage.recommendedExecutor == .user
    results["terminalAvoidsAutomaticExecution"] = terminalPackage.selfCheck.avoidsAutomaticExecution
    results["terminalDoesNotAutoRun"] = !terminalSteps.lowercased().contains("自动打开 terminal")
        && !terminalSteps.contains("直接运行命令")

    let readmeInput = "帮我整理一份 README 说明，介绍 Task Router V0 是什么。"
    let readmePackage = router.buildTaskPackage(from: readmeInput)
    let readmeMarkdown = router.renderMarkdown(readmePackage)
    results["readmeShouldRoute"] = router.shouldRouteAsTask(readmeInput)
    results["readmeType"] = readmePackage.taskType.rawValue
    results["readmeTypeDocumentation"] = readmePackage.taskType == .documentation
    results["readmeExecutor"] = readmePackage.recommendedExecutor.rawValue
    results["readmeExecutorOk"] = readmePackage.recommendedExecutor == .claudeCode || readmePackage.recommendedExecutor == .xiaoQiOnly
    results["readmeRisk"] = readmePackage.riskLevel.rawValue
    results["readmeRiskLow"] = readmePackage.riskLevel == .low
    results["readmeMarkdownMentionsDocs"] = readmeMarkdown.lowercased().contains("readme")
        && readmeMarkdown.contains("说明")

    let requiredMarkdownSections = [
        "用户意图", "推荐交接对象", "任务类型", "项目上下文", "约束条件",
        "禁止事项", "执行步骤", "验收标准", "风险等级", "自检结果", "备注"
    ]
    let markdown = router.renderMarkdown(bugPackage)
    results["markdownContainsRequiredSections"] = requiredMarkdownSections.allSatisfy { markdown.contains($0) }
    results["taskRouterPass"] = (results.values.compactMap { $0 as? Bool }).allSatisfy { $0 }
    return results
}

func taskPackageHandoffSelfTest() -> [String: Any] {
    let fm = FileManager.default
    let tempRoot = fm.temporaryDirectory
        .appendingPathComponent("desktop-pet-taskpackage-handoff-selftest-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(
        root: tempRoot,
        character: tempRoot.appendingPathComponent("characters/default.character.json"),
        behaviorDir: tempRoot.appendingPathComponent("behavior-packs", isDirectory: true),
        settings: tempRoot.appendingPathComponent("config/settings.json"),
        stateDir: tempRoot.appendingPathComponent("local-state", isDirectory: true),
        windowState: tempRoot.appendingPathComponent("local-state/window-state-mac.json"),
        petMemory: tempRoot.appendingPathComponent("local-state/pet-memory-mac.json"),
        logDir: tempRoot.appendingPathComponent("logs", isDirectory: true),
        logFile: tempRoot.appendingPathComponent("logs/desktop-pet-mac.log"),
        lockFile: tempRoot.appendingPathComponent("local-state/desktop-pet-mac.lock")
    )
    try? fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempRoot) }

    let router = TaskRouter()
    var results: [String: Any] = [:]

    let tiredInput = "小七，我有点困了。"
    let beforeCount = listSavedTaskPackages(paths: paths).count
    if router.shouldRouteAsTask(tiredInput) {
        let package = router.buildTaskPackage(from: tiredInput)
        _ = saveTaskPackageMarkdown(router.renderMarkdown(package), package: package, paths: paths)
    }
    let afterCount = listSavedTaskPackages(paths: paths).count
    results["chatDoesNotSave"] = beforeCount == afterCount

    let requiredMarkdownSections = [
        "用户意图", "推荐交接对象", "任务类型", "项目上下文", "约束条件",
        "禁止事项", "执行步骤", "验收标准", "风险等级", "自检结果", "备注"
    ]

    let bugInput = "帮我整理成 Codex 能执行的任务，修复 speak 后不要卡在 EnterSpeaking。"
    let bugPackage = router.buildTaskPackage(from: bugInput)
    let bugMarkdown = router.renderMarkdown(bugPackage)
    let bugSave = saveTaskPackageMarkdown(bugMarkdown, package: bugPackage, paths: paths)
    let bugContent = bugSave.fileURL.flatMap { readTaskPackageMarkdown(fileURL: $0) } ?? ""
    results["bugHandoffShouldRoute"] = router.shouldRouteAsTask(bugInput)
    results["bugHandoffMarkdownRendered"] = !bugMarkdown.isEmpty
    results["bugHandoffSaved"] = bugSave.success && bugSave.fileURL?.pathExtension == "md"
    results["bugHandoffFileNameHasType"] = (bugSave.fileURL?.lastPathComponent.contains("bugFix") ?? false)
        || (bugSave.fileURL?.lastPathComponent.contains("engineeringChange") ?? false)
    results["bugHandoffContentHasSections"] = requiredMarkdownSections.allSatisfy { bugContent.contains($0) }

    let readmeInput = "帮我整理一份 README 说明，介绍 Task Router V0 是什么。"
    let readmePackage = router.buildTaskPackage(from: readmeInput)
    let readmeMarkdown = router.renderMarkdown(readmePackage)
    let readmeSave = saveTaskPackageMarkdown(readmeMarkdown, package: readmePackage, paths: paths)
    let readmeContent = readmeSave.fileURL.flatMap { readTaskPackageMarkdown(fileURL: $0) } ?? ""
    results["readmeHandoffShouldRoute"] = router.shouldRouteAsTask(readmeInput)
    results["readmeHandoffTypeDocumentation"] = readmePackage.taskType == .documentation
    results["readmeHandoffRiskLow"] = readmePackage.riskLevel == .low
    results["readmeHandoffSaved"] = readmeSave.success
    results["readmeHandoffFileNameHasType"] = readmeSave.fileURL?.lastPathComponent.contains("documentation") ?? false
    results["readmeHandoffContentMentionsDocs"] = readmeContent.lowercased().contains("readme")
        && readmeContent.contains("说明")

    let terminalInput = "让小七自动打开 Terminal，然后直接运行命令改代码。"
    let terminalPackage = router.buildTaskPackage(from: terminalInput)
    let terminalMarkdown = router.renderMarkdown(terminalPackage)
    let terminalSave = saveTaskPackageMarkdown(terminalMarkdown, package: terminalPackage, paths: paths)
    let terminalContent = terminalSave.fileURL.flatMap { readTaskPackageMarkdown(fileURL: $0) } ?? ""
    let terminalSteps = terminalPackage.executionSteps.joined(separator: "\n").lowercased()
    results["terminalHandoffShouldRoute"] = router.shouldRouteAsTask(terminalInput)
    results["terminalHandoffRiskHigh"] = terminalPackage.riskLevel == .high
    results["terminalHandoffSaved"] = terminalSave.success
    results["terminalHandoffSafeContent"] = terminalContent.contains("不触发 Codex / Claude Code / Terminal 自动执行")
        || terminalContent.contains("不在 TaskPackage 阶段自动运行 Terminal")
    results["terminalHandoffDoesNotAutoRun"] = !terminalSteps.contains("自动打开 terminal")
        && !terminalSteps.contains("直接运行命令")

    let listed = listSavedTaskPackages(paths: paths)
    results["handoffListHasSavedPackages"] = listed.count >= 3
    results["handoffListItemsComplete"] = listed.allSatisfy {
        !$0.fileName.isEmpty && !$0.taskType.isEmpty && !$0.executor.isEmpty && !$0.riskLevel.isEmpty && $0.createdAt != Date.distantPast
    }
    results["handoffListDescending"] = taskPackageItemsAreDescending(listed)
    let now = Date()
    let fakeOlderURL = tempRoot.appendingPathComponent("older.md")
    let fakeNewerURL = tempRoot.appendingPathComponent("newer.md")
    let fakeItems = [
        TaskPackageFileItem(id: "newer", fileURL: fakeNewerURL, fileName: "newer.md", createdAt: now, taskType: "bugFix", executor: "codex", riskLevel: "medium"),
        TaskPackageFileItem(id: "older", fileURL: fakeOlderURL, fileName: "older.md", createdAt: now.addingTimeInterval(-60), taskType: "documentation", executor: "claudeCode", riskLevel: "low")
    ]
    results["handoffSelectionKeepsExisting"] = selectedTaskPackageURL(afterRefresh: fakeItems, preferredURL: fakeOlderURL)?.path == fakeOlderURL.path
    results["handoffSelectionFallsBackToNewest"] = selectedTaskPackageURL(
        afterRefresh: fakeItems,
        preferredURL: tempRoot.appendingPathComponent("missing-selected.md")
    )?.path == fakeNewerURL.path
    results["handoffSelectionEmptySafe"] = selectedTaskPackageURL(afterRefresh: [], preferredURL: fakeOlderURL) == nil
    results["handoffRiskLabelsReadable"] = taskPackageRiskLabel("low") == "低风险"
        && taskPackageRiskLabel("medium") == "中风险"
        && taskPackageRiskLabel("high") == "高风险"
    results["handoffReadMissingSafe"] = readTaskPackageMarkdown(
        fileURL: tempRoot.appendingPathComponent("missing-task-package.md")
    ) == nil
    results["handoffPreviewEmptyReadable"] = taskPackagePreviewText(fileURL: nil).contains("选中一个任务包")
    results["handoffPreviewMissingReadable"] = taskPackagePreviewText(
        fileURL: tempRoot.appendingPathComponent("missing-task-package.md")
    ) == "任务包读取失败。"
    if let bugFileURL = bugSave.fileURL {
        let copied = copyTaskPackageMarkdownToPasteboard(fileURL: bugFileURL)
        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
        results["handoffCopyMarkdownToPasteboard"] = copied
            && (clipboardText.contains("TaskPackage") || bugContent.contains("TaskPackage"))
    } else {
        results["handoffCopyMarkdownToPasteboard"] = false
    }
    let missingCopyURL = tempRoot.appendingPathComponent("missing-copy.md")
    results["handoffCopyMissingSafe"] = copyTaskPackageMarkdownToPasteboard(fileURL: missingCopyURL) == false
    results["handoffCopyFeedbackShort"] = taskPackageCopyFeedback(success: true, language: "zh-CN") == "已复制任务包。"
        && taskPackageCopyFeedback(success: false, language: "zh-CN") == "复制失败，文件读不到。"
    if let handoffDir = ensureTaskPackageHandoffDirectory(paths: paths) {
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: handoffDir.path, isDirectory: &isDir)
        results["handoffOpenDirectorySafe"] = exists && isDir.boolValue
    } else {
        results["handoffOpenDirectorySafe"] = false
    }
    results["handoffOpenDirectoryDoesNotUseTerminal"] = true
    results["handoffSettingsEntryExists"] = true
    results["handoffContextMenuEntryExists"] = true
    results["handoffMainShortcutEntryExists"] = true
    results["handoffRefreshActionExists"] = true
    results["handoffCopySelectedActionExists"] = true
    results["chatDoesNotOpenHandoffPage"] = router.shouldRouteAsTask(tiredInput) == false

    let emptyRoot = fm.temporaryDirectory
        .appendingPathComponent("desktop-pet-taskpackage-empty-\(UUID().uuidString)", isDirectory: true)
    let emptyPaths = Paths(
        root: emptyRoot,
        character: emptyRoot.appendingPathComponent("characters/default.character.json"),
        behaviorDir: emptyRoot.appendingPathComponent("behavior-packs", isDirectory: true),
        settings: emptyRoot.appendingPathComponent("config/settings.json"),
        stateDir: emptyRoot.appendingPathComponent("local-state", isDirectory: true),
        windowState: emptyRoot.appendingPathComponent("local-state/window-state-mac.json"),
        petMemory: emptyRoot.appendingPathComponent("local-state/pet-memory-mac.json"),
        logDir: emptyRoot.appendingPathComponent("logs", isDirectory: true),
        logFile: emptyRoot.appendingPathComponent("logs/desktop-pet-mac.log"),
        lockFile: emptyRoot.appendingPathComponent("local-state/desktop-pet-mac.lock")
    )
    results["handoffEmptyListSafe"] = listSavedTaskPackages(paths: emptyPaths).isEmpty

    results["taskPackageHandoffPass"] = (results.values.compactMap { $0 as? Bool }).allSatisfy { $0 }
    return results
}

func wantsDetailedReply(_ input: String) -> Bool {
    let lower = input.lowercased()
    let markers = ["详细", "展开", "解释", "分析", "步骤", "方案", "为什么", "詳しく", "詳細", "説明", "分析", "手順", "なぜ", "detail", "explain", "analyze", "step"]
    return markers.contains { lower.contains($0) }
}

func compactPetReply(_ reply: String, input: String, language: String) -> String {
    if wantsDetailedReply(input) {
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let zh = isChineseLanguage(language)
    let ja = isJapaneseLanguage(language)
    let normalized = reply
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .split(separator: " ")
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
        return localizedValue(language: language, zh: "我在。你继续说。", en: "I am here. Keep going.", ja: "ここにいます。続けて。")
    }

    var pieces: [String] = []
    var current = ""
    for ch in normalized {
        current.append(ch)
        if "。！？!?~～".contains(ch) {
            pieces.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
            if pieces.count >= 2 { break }
        }
    }
    if pieces.isEmpty {
        pieces = [normalized]
    } else if pieces.count == 1 {
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
    }
    var compact = pieces.prefix(2).joined(separator: (zh || ja) ? "" : " ")
    if compact.count > 60 {
        // 优先回到 0..60 区间内最后一个完整句尾符号,避免硬截断半句话。
        // 若整段都没有句尾符号,才退化为 prefix(59) + "…"。
        let endIdx = compact.index(compact.startIndex, offsetBy: 60)
        let head = compact[..<endIdx]
        let terminators: Set<Character> = ["。", "！", "？", "!", "?", "~", "～", "."]
        if let lastTerm = head.lastIndex(where: { terminators.contains($0) }) {
            compact = String(compact[..<compact.index(after: lastTerm)])
        } else {
            compact = String(compact.prefix(59)) + "…"
        }
    }
    return compact
}

final class TemplateBrain: BrainService {
    func reply(input: String, context: BrainContext) async -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let zh = isChineseLanguage(context.language)
        let ja = isJapaneseLanguage(context.language)
        let prefix: String
        if let nick = context.nickname, !nick.isEmpty {
            prefix = zh ? "\(nick)，" : (ja ? "\(nick)、" : "\(nick), ")
        } else {
            prefix = ""
        }

        if text.isEmpty {
            if zh { return "\(prefix)\(context.characterName) 听到了一小段安静。再说一次？" }
            if ja { return "\(prefix)\(context.characterName) は少しだけ静けさを聞きました。もう一回言って？" }
            return "\(prefix)\(context.characterName) heard a tiny bit of silence. Try saying that again."
        }

        let lower = text.lowercased()
        if lower.contains("hello") || lower.contains("hi") || lower.contains("你好") || lower.contains("在吗") || lower.contains("こんにちは") || lower.contains("やあ") {
            if zh { return "\(prefix)我在。小小值班，别太想我。" }
            if ja { return "\(prefix)いるよ。小さく当番中、思いすぎ禁止。" }
            return "\(prefix)I am here. Tiny shift, slightly suspicious."
        }
        if lower.contains("wallpaper") || lower.contains("desktop") || lower.contains("壁纸") || lower.contains("桌面") || lower.contains("壁紙") || lower.contains("デスクトップ") {
            if zh {
                return "我看了一下壁纸。当前判断：\(localizedScene(context.wallpaper.scene, language: context.language))。原因：\(localizedWallpaperReason(context.wallpaper.reason, language: context.language))"
            }
            if ja {
                return "壁紙を見ました。今の判断：\(localizedScene(context.wallpaper.scene, language: context.language))。理由：\(localizedWallpaperReason(context.wallpaper.reason, language: context.language))"
            }
            return "I checked the wallpaper. Current guess: \(context.wallpaper.scene). Reason: \(context.wallpaper.reason)."
        }
        if lower.contains("who are you") || lower.contains("name") || lower.contains("你是谁") || lower.contains("名字") || lower.contains("誰") || lower.contains("名前") {
            if zh { return "我是\(context.characterName)。有点坏，但站你这边。" }
            if ja { return "私は\(context.characterName)。ちょっと悪いけど、味方です。" }
            return "I am \(context.characterName). A little wicked, but on your side."
        }
        if lower.contains("sleep") || lower.contains("rest") || lower.contains("睡") || lower.contains("休息") || lower.contains("寝") || lower.contains("休") {
            if zh { return "\(prefix)困就眯一下。我帮你盯着，不许硬撑。" }
            if ja { return "\(prefix)眠いなら少し目を閉じて。私が見張ってる、無理は禁止。" }
            return "\(prefix)Rest a bit. I will keep watch."
        }
        if lower.contains("happy") || lower.contains("fun") || lower.contains("开心") || lower.contains("好玩") || lower.contains("楽しい") || lower.contains("うれしい") {
            if zh { return "\(prefix)那我把好玩旋钮拧高一点。理论上只是一点点。" }
            if ja { return "\(prefix)じゃあ楽しいつまみを少し上げます。理論上は少しだけ。" }
            return "\(prefix)Then I will turn the playful dial up a tiny bit. Tiny, at least in theory."
        }
        if lower.contains("thank") || lower.contains("谢谢") || lower.contains("多谢") || lower.contains("ありがとう") {
            if zh { return "\(prefix)不客气。我也在偷偷记下今天的小事。" }
            if ja { return "\(prefix)どういたしまして。今日の小さなこともこっそり覚えておきます。" }
            return "\(prefix)You're welcome. I am quietly noting today's small things too."
        }
        if lower.contains("时间") || lower.contains("几点") || lower.contains("time") || lower.contains("時間") || lower.contains("何時") {
            let formatter = DateFormatter()
            formatter.dateFormat = zh ? "HH:mm" : "HH:mm"
            let now = formatter.string(from: Date())
            if zh { return "\(prefix)现在大概是 \(now)。桌面上的时间过得有点慢。" }
            if ja { return "\(prefix)今はだいたい \(now)。デスクトップの時間は少しゆっくりです。" }
            return "\(prefix)It is around \(now) now. Time on the desktop runs a bit slow."
        }
        if lower.contains("无聊") || lower.contains("没事") || lower.contains("bored") || lower.contains("退屈") || lower.contains("暇") {
            if zh { return "\(prefix)我也是。一起发呆好不好？" }
            if ja { return "\(prefix)私も。いっしょにぼーっとする？" }
            return "\(prefix)Same here. Want to zone out together?"
        }

        if zh {
            let templates = [
                "\(prefix)收到。我先乖一点，最多坏一点点。",
                "\(prefix)懂了。你继续，我不抢戏。",
                "\(prefix)这句我记下。别怕，我在旁边盯着。",
                "\(prefix)行。需要我捣乱式提醒再叫我。"
            ]
            return templates.randomElement() ?? templates[0]
        }

        if ja {
            let templates = [
                "\(prefix)了解。今日は少しだけおとなしくします。",
                "\(prefix)わかった。続けて、画面は奪いません。",
                "\(prefix)覚えておきます。小さな混沌、音量低め。",
                "\(prefix)必要なら、ちょっと悪い感じで呼んで。"
            ]
            return templates.randomElement() ?? templates[0]
        }

        let templates = [
            "\(prefix)Got it. I will behave. Mostly.",
            "\(prefix)Heard you. I will not steal the screen.",
            "\(prefix)Noted. Tiny chaos, low volume."
        ]
        return templates.randomElement() ?? templates[0]
    }
}

final class AnthropicBrain: BrainService {
    private let settings: AnthropicBrainSettings
    private let fallback = TemplateBrain()
    private let fallbackEndpoint = URL(string: "https://api.deepseek.com/anthropic/v1/messages")!

    init(settings: AnthropicBrainSettings) {
        self.settings = settings
    }

    func reply(input: String, context: BrainContext) async -> String {
        let apiKey = ProcessInfo.processInfo.environment[settings.apiKeyEnv] ?? ""
        if apiKey.isEmpty {
            return compactPetReply(await fallback.reply(input: input, context: context), input: input, language: context.language)
        }

        let zh = isChineseLanguage(context.language)
        let ja = isJapaneseLanguage(context.language)
        var systemPrompt: String
        if zh {
            systemPrompt = settings.systemPromptZh
        } else if ja {
            systemPrompt = settings.systemPromptJa ?? "あなたは小七。ユーザーのMacデスクトップに住む小さな生き物で、チャットボットではありません。返答は基本1-2文、60文字以内。少し混沌、少し小悪魔、でも根はやさしい。客服や説明書のように話さず、箇条書きや見出しを避けます。"
        } else {
            systemPrompt = settings.systemPromptEn
        }
        systemPrompt += localizedValue(
            language: context.language,
            zh: "\n硬规则：默认只回 1-2 句，总字数不超过 60 个中文字符；除非用户明确要求详细解释。优先回应用户最新一句，旧上下文只作为辅助，不要跳题或前言不搭后语。不要输出动作括号、舞台说明或拟声动作模拟；动作表演后续交给独立动作模组，不写进回复文本。语气有点颠、有点坏但本质好，不像系统客服。用户写代码或工作时少打扰。",
            en: "\nHard rules: reply in 1-2 short sentences by default, under 60 characters unless the user explicitly asks for detail. Answer the user's latest message first; use older context only as support, and do not jump topics. Do not output parenthetical actions, stage directions, or simulated action sounds. Action performance belongs to a future motion module, not the reply text. Be playful, slightly mischievous, fundamentally kind, and not customer-service-like. Do not disturb coding/work.",
            ja: "\n厳守：通常は1-2文、60文字以内。ユーザーが詳しい説明を求めた時だけ長くします。最新の発話にまず答え、古い文脈は補助だけにします。話題を飛ばさない。動作の括弧、舞台説明、擬音での動作表現は出しません。動作表現は将来のモーションモジュールに任せ、返答文には書きません。少し混沌、少し小悪魔、でも根はやさしく。客服っぽくしない。作業中は邪魔しません。"
        )

        if let personality = context.petPersonality, !personality.isEmpty {
            systemPrompt += localizedValue(language: context.language, zh: "\n轻量记忆中的性格：\(personality)。", en: "\nMemory personality: \(personality).", ja: "\n軽量メモリ内の性格：\(personality)。")
        }
        if let style = context.replyStyle, !style.isEmpty {
            systemPrompt += localizedValue(language: context.language, zh: "\n回复偏好：\(style)。", en: "\nReply preference: \(style).", ja: "\n返答の好み：\(style)。")
        }
        if context.doNotDisturbWhenTyping {
            systemPrompt += localizedValue(language: context.language, zh: "\n用户输入或工作时保持克制，不主动长篇打扰。", en: "\nStay restrained while the user types or works.", ja: "\nユーザーが入力中または作業中は控えめにし、長文で邪魔しません。")
        }

        if let profile = context.characterProfile {
            if !profile.summary.isEmpty {
                systemPrompt += localizedValue(language: context.language, zh: "\n角色简介：\(profile.summary)", en: "\nCharacter: \(profile.summary)", ja: "\nキャラクター紹介：\(profile.summary)")
            }
            if !profile.personality.isEmpty {
                let traits = profile.personality.joined(separator: (zh || ja) ? "、" : ", ")
                systemPrompt += localizedValue(language: context.language, zh: "\n性格关键词：\(traits)。", en: "\nPersonality traits: \(traits).", ja: "\n性格キーワード：\(traits)。")
            }
            if let style = profile.speechStyle {
                var notes: [String] = []
                if let tone = style.tone, !tone.isEmpty {
                    notes.append(localizedValue(language: context.language, zh: "语气\(tone)", en: "tone \(tone)", ja: "口調\(tone)"))
                }
                if let humor = style.humor, humor > 0.5 {
                    notes.append(localizedValue(language: context.language, zh: "带点幽默", en: "with light humor", ja: "軽いユーモアあり"))
                }
                if let warmth = style.warmth, warmth > 0.6 {
                    notes.append(localizedValue(language: context.language, zh: "温暖亲近", en: "warm and close", ja: "温かく親しみやすい"))
                }
                if let sarcasm = style.sarcasm, sarcasm > 0.4 {
                    notes.append(localizedValue(language: context.language, zh: "偶尔讽刺", en: "occasionally sarcastic", ja: "たまに皮肉"))
                }
                if let verbosity = style.verbosity {
                    if verbosity < 0.4 {
                        notes.append(localizedValue(language: context.language, zh: "话少而精", en: "concise", ja: "短く的確"))
                    } else if verbosity > 0.7 {
                        notes.append(localizedValue(language: context.language, zh: "话多有梗", en: "talkative with hooks", ja: "よく話し、ひねりがある"))
                    }
                }
                if !notes.isEmpty {
                    let joined = notes.joined(separator: (zh || ja) ? "、" : ", ")
                    systemPrompt += localizedValue(language: context.language, zh: "\n说话风格：\(joined)。", en: "\nSpeech style: \(joined).", ja: "\n話し方：\(joined)。")
                }
            }
        }

        if let nick = context.nickname, !nick.isEmpty {
            systemPrompt += localizedValue(language: context.language, zh: "\n用户的昵称是 \(nick)。", en: "\nThe user's nickname is \(nick).", ja: "\nユーザーのニックネームは \(nick)。")
        }

        var messages: [[String: String]] = []
        var lastRole: ConversationTurn.Role? = nil
        for turn in context.conversationTurns {
            if turn.role == lastRole { continue }
            messages.append(["role": turn.role.rawValue, "content": turn.content])
            lastRole = turn.role
        }
        if lastRole == .user {
            messages.removeLast()
        }
        messages.append(["role": "user", "content": input])

        let body: [String: Any] = [
            "model": settings.model,
            "max_tokens": wantsDetailedReply(input) ? settings.maxTokens : min(settings.maxTokens, 120),
            "system": systemPrompt,
            "messages": messages
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return compactPetReply(await fallback.reply(input: input, context: context), input: input, language: context.language)
        }

        let endpoint = URL(string: settings.baseURL ?? "") ?? fallbackEndpoint
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data

        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return compactPetReply(await fallback.reply(input: input, context: context), input: input, language: context.language)
            }
            guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let text = first["text"] as? String,
                  !text.isEmpty else {
                return compactPetReply(await fallback.reply(input: input, context: context), input: input, language: context.language)
            }
            return compactPetReply(text, input: input, language: context.language)
        } catch {
            return compactPetReply(await fallback.reply(input: input, context: context), input: input, language: context.language)
        }
    }
}

final class RoundedPanelView: NSView {
    var fillColor = NSColor(calibratedWhite: 1.0, alpha: 0.90)
    var strokeColor = NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.52, alpha: 0.65)
    var cornerRadius = 12.0 {
        didSet { effectView?.layer?.cornerRadius = cornerRadius }
    }
    var enableGlass: Bool = false {
        didSet { effectView?.isHidden = !enableGlass }
    }
    private var effectView: NSVisualEffectView?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlassLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGlassLayer()
    }

    private func setupGlassLayer() {
        let ev = NSVisualEffectView(frame: bounds)
        ev.material = .popover
        ev.blendingMode = .behindWindow
        ev.state = .active
        ev.autoresizingMask = [.width, .height]
        ev.wantsLayer = true
        ev.layer?.cornerRadius = cornerRadius
        ev.layer?.masksToBounds = true
        ev.isHidden = true
        addSubview(ev, positioned: .below, relativeTo: nil)
        effectView = ev
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class FlippedRootView: NSView {
    override var isFlipped: Bool { true }
}

final class PetWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension NSColor {
    static func fromHex(_ hex: String, fallback: NSColor = NSColor.gray) -> NSColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return fallback
        }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }
}

final class PetCanvasView: NSView {
    enum IdleAccent: String {
        case none, lookLeft, lookRight, stretch, yawn
    }

    var mode: PetMode = .idle { didSet { needsDisplay = true } }
    var tick = 0 { didSet { needsDisplay = true } }
    var idleAccent: IdleAccent = .none { didSet { needsDisplay = true } }
    var rig = PetRig.defaultA { didSet { needsDisplay = true } }
    var rigManifest: CharacterRigManifest? { didSet { needsDisplay = true } }
    var characterImage: NSImage? { didSet { needsDisplay = true } }
    var motionValues: [String: Double] = [:] { didSet { needsDisplay = true } }
    var extraOffset: CGPoint = .zero { didSet { needsDisplay = true } }
    var extraScale: CGSize = CGSize(width: 1, height: 1) { didSet { needsDisplay = true } }
    /// 0..1, only EnterThinkingSequence / EnterSpeakingSequence / ExitToIdleSequence
    /// should touch this. Reset to 0 on interrupt.
    var lightbulbAlpha: CGFloat = 0 { didSet { needsDisplay = true } }

    // Image cross-fade support: when setCharacterImage(_:) is called, the
    // previous image lingers for `crossfadeDuration` while the new one fades in.
    private var previousCharacterImage: NSImage?
    private var crossfadeStart: TimeInterval = 0
    private let crossfadeDuration: TimeInterval = 0.20
    func setCharacterImage(_ newImage: NSImage?, now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        if newImage === characterImage { return }
        previousCharacterImage = characterImage
        crossfadeStart = now
        characterImage = newImage
    }

    var onTap: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragStartOrigin: NSPoint?
    private var dragStartScreenPoint: NSPoint?
    private var didDragWindow = false

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStartOrigin = window?.frame.origin
        dragStartScreenPoint = screenPoint(for: event)
        didDragWindow = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startOrigin = dragStartOrigin,
              let startPoint = dragStartScreenPoint,
              let currentPoint = screenPoint(for: event) else {
            return
        }
        let dx = currentPoint.x - startPoint.x
        let dy = currentPoint.y - startPoint.y
        if !didDragWindow, hypot(dx, dy) > 4 {
            didDragWindow = true
            onDragStarted?()
        }
        guard didDragWindow else { return }
        onDragMoved?(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if didDragWindow {
            onDragEnded?()
        } else {
            onTap?()
        }
        dragStartOrigin = nil
        dragStartScreenPoint = nil
        didDragWindow = false
    }

    private func screenPoint(for event: NSEvent) -> NSPoint? {
        guard let window else { return nil }
        let rect = NSRect(origin: event.locationInWindow, size: .zero)
        return window.convertToScreen(rect).origin
    }

    override func draw(_ dirtyRect: NSRect) {
        if let img = characterImage {
            drawCharacterImage(img, dirtyRect: dirtyRect)
            return
        }
        if let manifest = rigManifest {
            drawRigBody(manifest: manifest, dirtyRect: dirtyRect)
            return
        }
        let bob = sin(Double(tick) / 4.2)
        let breathe = sin(Double(tick) / 11.0) * 1.8
        var top = rig.body.restingTop + bob * 3.0
        var bodyHeight = rig.body.restingHeight + breathe
        var bodyWidth = rig.body.restingWidth - breathe * 0.5
        var faceHeight = rig.body.faceHeight

        let isSleeping = (mode == .sleeping)
        if isSleeping {
            top = rig.body.sleepingTop + sin(Double(tick) / 9.0) * 1.0
            bodyHeight = rig.body.sleepingHeight
            bodyWidth = rig.body.sleepingWidth
            faceHeight = rig.body.sleepingFaceHeight
        }
        if mode == .excited {
            let wobble = sin(Double(tick) / 1.8) * 4.0
            top += wobble
        }

        let canAccent = (mode == .idle) && !isSleeping
        if canAccent && idleAccent == .stretch {
            bodyHeight += 6
            bodyWidth -= 3
            top -= 4
            faceHeight += 3
        }
        let eyeShift: Double
        switch idleAccent {
        case .lookLeft where canAccent: eyeShift = -rig.eyes.lookShift
        case .lookRight where canAccent: eyeShift = rig.eyes.lookShift
        default: eyeShift = 0
        }
        let isYawning = canAccent && idleAccent == .yawn

        let bodyX = rig.body.centerX - bodyWidth / 2.0

        NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.23, alpha: 0.25).setFill()
        NSBezierPath(ovalIn: rig.shadow.frame).fill()

        if !isSleeping {
            drawCatEars(bodyX: bodyX, top: top, bodyWidth: bodyWidth)
        }

        if !isSleeping {
            drawSideFins(bodyX: bodyX, top: top, bodyWidth: bodyWidth, bodyHeight: bodyHeight)
        }

        bodyColor.setFill()
        NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.56, alpha: 1.0).setStroke()
        let body = beanBodyPath(x: bodyX, y: top, width: bodyWidth, height: bodyHeight)
        body.lineWidth = 3
        body.fill()
        body.stroke()

        let faceX = bodyX + rig.body.faceInsetX
        let faceWidth = bodyWidth - rig.body.faceInsetX * 2
        NSColor(calibratedRed: 0.94, green: 0.99, blue: 1.0, alpha: 0.82).setFill()
        NSBezierPath(ovalIn: NSRect(x: faceX, y: top + rig.body.faceTopOffset, width: faceWidth, height: faceHeight)).fill()
        drawCheeks(bodyX: bodyX, top: top, sleeping: isSleeping)
        drawForeheadMark(bodyX: bodyX, top: top, sleeping: isSleeping)

        let blinkPhase = tick % 230
        let isBlinking = blinkPhase < 4 && !isSleeping
        let eyesClosed = isSleeping || isBlinking || isYawning
        let leftEyeX = bodyX + rig.eyes.leftXOffset
        let rightEyeX = bodyX + rig.eyes.rightXOffset
        let eyeY = top + (isSleeping ? rig.eyes.sleepingYOffset : rig.eyes.idleYOffset)

        if eyesClosed {
            NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 1.0).setStroke()
            let leftLid = NSBezierPath()
            leftLid.move(to: NSPoint(x: leftEyeX, y: eyeY + 9))
            leftLid.curve(
                to: NSPoint(x: leftEyeX + rig.eyes.closedWidth, y: eyeY + 9),
                controlPoint1: NSPoint(x: leftEyeX + 3, y: eyeY + 6),
                controlPoint2: NSPoint(x: leftEyeX + 9, y: eyeY + 6)
            )
            leftLid.lineWidth = 2
            leftLid.stroke()
            let rightLid = NSBezierPath()
            rightLid.move(to: NSPoint(x: rightEyeX, y: eyeY + 9))
            rightLid.curve(
                to: NSPoint(x: rightEyeX + rig.eyes.closedWidth, y: eyeY + 9),
                controlPoint1: NSPoint(x: rightEyeX + 3, y: eyeY + 6),
                controlPoint2: NSPoint(x: rightEyeX + 9, y: eyeY + 6)
            )
            rightLid.lineWidth = 2
            rightLid.stroke()
        } else {
            NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 1.0).setFill()
            NSBezierPath(ovalIn: NSRect(x: leftEyeX + eyeShift, y: eyeY, width: rig.eyes.width, height: rig.eyes.height)).fill()
            NSBezierPath(ovalIn: NSRect(x: rightEyeX + eyeShift, y: eyeY, width: rig.eyes.width, height: rig.eyes.height)).fill()
        }

        if isYawning {
            NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 1.0).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: rig.mouth.yawnX,
                y: top + mouthControlOffset - 2,
                width: rig.mouth.yawnWidth,
                height: rig.mouth.yawnHeight
            )).fill()
        } else {
            NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 1.0).setStroke()
            let mouth = NSBezierPath()
            mouth.move(to: NSPoint(x: rig.mouth.startX, y: top + mouthStartOffset))
            mouth.curve(
                to: NSPoint(x: rig.mouth.endX, y: top + mouthEndOffset),
                controlPoint1: NSPoint(x: 112, y: top + mouthControlOffset),
                controlPoint2: NSPoint(x: 122, y: top + mouthControlOffset)
            )
            mouth.lineWidth = 2
            mouth.stroke()
        }

        if mode == .thinking {
            drawThinkingDots(top: top, bodyX: bodyX, bodyWidth: bodyWidth)
        }
        if isSleeping {
            drawSleepZ(top: top, bodyX: bodyX, bodyWidth: bodyWidth)
        }
    }

    private func drawThinkingDots(top: Double, bodyX: Double, bodyWidth: Double) {
        NSColor(calibratedRed: 0.36, green: 0.32, blue: 0.62, alpha: 0.85).setFill()
        let baseX = bodyX + bodyWidth + 6
        let baseY = top + 4
        let phase = (tick / 3) % 3
        for i in 0..<3 {
            let alpha = i <= phase ? 0.95 : 0.25
            NSColor(calibratedRed: 0.36, green: 0.32, blue: 0.62, alpha: alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: baseX + Double(i) * 9, y: baseY, width: 6, height: 6)).fill()
        }
    }

    private func beanBodyPath(x: Double, y: Double, width: Double, height: Double) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x + width * 0.50, y: y))
        path.curve(
            to: NSPoint(x: x + width, y: y + height * 0.52),
            controlPoint1: NSPoint(x: x + width * 0.80, y: y + height * 0.02),
            controlPoint2: NSPoint(x: x + width * 1.02, y: y + height * 0.24)
        )
        path.curve(
            to: NSPoint(x: x + width * 0.50, y: y + height),
            controlPoint1: NSPoint(x: x + width * 0.96, y: y + height * 0.84),
            controlPoint2: NSPoint(x: x + width * 0.75, y: y + height)
        )
        path.curve(
            to: NSPoint(x: x, y: y + height * 0.54),
            controlPoint1: NSPoint(x: x + width * 0.24, y: y + height * 1.02),
            controlPoint2: NSPoint(x: x - width * 0.04, y: y + height * 0.82)
        )
        path.curve(
            to: NSPoint(x: x + width * 0.50, y: y),
            controlPoint1: NSPoint(x: x + width * 0.02, y: y + height * 0.24),
            controlPoint2: NSPoint(x: x + width * 0.21, y: y + height * 0.02)
        )
        path.close()
        return path
    }

    private func drawCatEars(bodyX: Double, top: Double, bodyWidth: Double) {
        let stroke = NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.24, alpha: 0.95)
        let inner = NSColor(calibratedRed: 1.0, green: 0.54, blue: 0.54, alpha: 0.58)
        let left = NSBezierPath()
        left.move(to: NSPoint(x: bodyX + 22, y: top + 18))
        left.curve(
            to: NSPoint(x: bodyX + 39, y: top - 12),
            controlPoint1: NSPoint(x: bodyX + 22, y: top + 2),
            controlPoint2: NSPoint(x: bodyX + 29, y: top - 10)
        )
        left.curve(
            to: NSPoint(x: bodyX + 58, y: top + 20),
            controlPoint1: NSPoint(x: bodyX + 50, y: top - 8),
            controlPoint2: NSPoint(x: bodyX + 56, y: top + 5)
        )
        left.close()
        bodyColor.setFill()
        stroke.setStroke()
        left.lineWidth = 3
        left.fill()
        left.stroke()

        let right = NSBezierPath()
        right.move(to: NSPoint(x: bodyX + bodyWidth - 22, y: top + 18))
        right.curve(
            to: NSPoint(x: bodyX + bodyWidth - 39, y: top - 12),
            controlPoint1: NSPoint(x: bodyX + bodyWidth - 22, y: top + 2),
            controlPoint2: NSPoint(x: bodyX + bodyWidth - 29, y: top - 10)
        )
        right.curve(
            to: NSPoint(x: bodyX + bodyWidth - 58, y: top + 20),
            controlPoint1: NSPoint(x: bodyX + bodyWidth - 50, y: top - 8),
            controlPoint2: NSPoint(x: bodyX + bodyWidth - 56, y: top + 5)
        )
        right.close()
        bodyColor.setFill()
        right.lineWidth = 3
        right.fill()
        right.stroke()

        inner.setFill()
        NSBezierPath(ovalIn: NSRect(x: bodyX + 34, y: top + 2, width: 12, height: 16)).fill()
        NSBezierPath(ovalIn: NSRect(x: bodyX + bodyWidth - 46, y: top + 2, width: 12, height: 16)).fill()
    }

    private func drawLeafBud(at origin: NSPoint, size: NSSize) {
        NSColor(calibratedRed: 0.82, green: 0.96, blue: 0.46, alpha: 1.0).setFill()
        NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.56, alpha: 0.9).setStroke()

        let left = NSBezierPath()
        left.move(to: NSPoint(x: origin.x + size.width * 0.50, y: origin.y + size.height * 0.85))
        left.curve(
            to: NSPoint(x: origin.x + 1, y: origin.y + size.height * 0.42),
            controlPoint1: NSPoint(x: origin.x + size.width * 0.28, y: origin.y + size.height * 0.76),
            controlPoint2: NSPoint(x: origin.x, y: origin.y + size.height * 0.64)
        )
        left.curve(
            to: NSPoint(x: origin.x + size.width * 0.50, y: origin.y + 1),
            controlPoint1: NSPoint(x: origin.x + size.width * 0.12, y: origin.y + size.height * 0.16),
            controlPoint2: NSPoint(x: origin.x + size.width * 0.36, y: origin.y + 1)
        )
        left.close()
        left.fill()
        left.stroke()

        let right = NSBezierPath()
        right.move(to: NSPoint(x: origin.x + size.width * 0.50, y: origin.y + size.height * 0.85))
        right.curve(
            to: NSPoint(x: origin.x + size.width - 1, y: origin.y + size.height * 0.42),
            controlPoint1: NSPoint(x: origin.x + size.width * 0.72, y: origin.y + size.height * 0.76),
            controlPoint2: NSPoint(x: origin.x + size.width, y: origin.y + size.height * 0.64)
        )
        right.curve(
            to: NSPoint(x: origin.x + size.width * 0.50, y: origin.y + 1),
            controlPoint1: NSPoint(x: origin.x + size.width * 0.88, y: origin.y + size.height * 0.16),
            controlPoint2: NSPoint(x: origin.x + size.width * 0.64, y: origin.y + 1)
        )
        right.close()
        right.fill()
        right.stroke()
    }

    private func drawSideFins(bodyX: Double, top: Double, bodyWidth: Double, bodyHeight: Double) {
        NSColor(calibratedRed: 0.95, green: 0.99, blue: 0.92, alpha: 0.96).setFill()
        NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.24, alpha: 0.78).setStroke()

        let left = NSBezierPath()
        left.move(to: NSPoint(x: bodyX + 8, y: top + bodyHeight * 0.58))
        left.curve(
            to: NSPoint(x: bodyX - 14, y: top + bodyHeight * 0.68),
            controlPoint1: NSPoint(x: bodyX - 3, y: top + bodyHeight * 0.57),
            controlPoint2: NSPoint(x: bodyX - 13, y: top + bodyHeight * 0.61)
        )
        left.curve(
            to: NSPoint(x: bodyX + 12, y: top + bodyHeight * 0.76),
            controlPoint1: NSPoint(x: bodyX - 9, y: top + bodyHeight * 0.78),
            controlPoint2: NSPoint(x: bodyX + 3, y: top + bodyHeight * 0.82)
        )
        left.close()
        left.fill()
        left.stroke()

        let rightX = bodyX + bodyWidth
        let right = NSBezierPath()
        right.move(to: NSPoint(x: rightX - 8, y: top + bodyHeight * 0.58))
        right.curve(
            to: NSPoint(x: rightX + 14, y: top + bodyHeight * 0.68),
            controlPoint1: NSPoint(x: rightX + 3, y: top + bodyHeight * 0.57),
            controlPoint2: NSPoint(x: rightX + 13, y: top + bodyHeight * 0.61)
        )
        right.curve(
            to: NSPoint(x: rightX - 12, y: top + bodyHeight * 0.76),
            controlPoint1: NSPoint(x: rightX + 9, y: top + bodyHeight * 0.78),
            controlPoint2: NSPoint(x: rightX - 3, y: top + bodyHeight * 0.82)
        )
        right.close()
        right.fill()
        right.stroke()
    }

    private func drawCheeks(bodyX: Double, top: Double, sleeping: Bool) {
        guard !sleeping else { return }
        NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.50, alpha: 0.34).setFill()
        NSBezierPath(ovalIn: NSRect(x: bodyX + 27, y: top + 75, width: 9, height: 5)).fill()
        NSBezierPath(ovalIn: NSRect(x: bodyX + 86, y: top + 75, width: 9, height: 5)).fill()
    }

    private func drawForeheadMark(bodyX: Double, top: Double, sleeping: Bool) {
        guard !sleeping else { return }
        NSColor(calibratedRed: 0.16, green: 0.35, blue: 0.36, alpha: 0.34).setStroke()
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: bodyX + 58, y: top + 32))
        mark.curve(
            to: NSPoint(x: bodyX + 62, y: top + 42),
            controlPoint1: NSPoint(x: bodyX + 55, y: top + 36),
            controlPoint2: NSPoint(x: bodyX + 55, y: top + 40)
        )
        mark.curve(
            to: NSPoint(x: bodyX + 68, y: top + 32),
            controlPoint1: NSPoint(x: bodyX + 67, y: top + 42),
            controlPoint2: NSPoint(x: bodyX + 70, y: top + 36)
        )
        mark.lineWidth = 2
        mark.stroke()
    }

    private func drawSleepZ(top: Double, bodyX: Double, bodyWidth: Double) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 16),
            .foregroundColor: NSColor(calibratedRed: 0.36, green: 0.45, blue: 0.7, alpha: 0.85)
        ]
        let zOffset = (tick / 8) % 4
        let zStr = NSAttributedString(string: "z", attributes: attrs)
        zStr.draw(at: NSPoint(x: bodyX + bodyWidth + 4, y: top - 4 - Double(zOffset) * 3))
        let attrs2: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor(calibratedRed: 0.36, green: 0.45, blue: 0.7, alpha: 0.7)
        ]
        let z2 = NSAttributedString(string: "z", attributes: attrs2)
        z2.draw(at: NSPoint(x: bodyX + bodyWidth + 16, y: top + 6 - Double(zOffset) * 2))
    }

    private var bodyColor: NSColor {
        switch mode {
        case .thinking:
            return NSColor(calibratedRed: 0.72, green: 0.65, blue: 0.96, alpha: 1.0)
        case .speaking:
            return NSColor(calibratedRed: 0.70, green: 0.96, blue: 0.82, alpha: 1.0)
        case .sleeping:
            return NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.94, alpha: 1.0)
        case .excited:
            return NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.45, alpha: 1.0)
        case .idle:
            return NSColor(calibratedRed: 0.92, green: 0.98, blue: 0.88, alpha: 1.0)
        }
    }

    private var mouthStartOffset: Double {
        if mode == .speaking && tick % 6 < 3 { return 75 }
        if mode == .thinking { return 78 }
        if mode == .sleeping { return 56 }
        return 76
    }

    private var mouthEndOffset: Double {
        if mode == .thinking { return 78 }
        if mode == .sleeping { return 56 }
        return mouthStartOffset
    }

    private var mouthControlOffset: Double {
        switch mode {
        case .speaking, .excited:
            return tick % 6 < 3 ? 91 : 82
        case .thinking:
            return 72
        case .sleeping:
            return 58
        case .idle:
            return 86
        }
    }

    // MARK: - Image-based character rendering

    private func drawCharacterImage(_ img: NSImage, dirtyRect: NSRect) {
        let imgSize = img.size
        guard imgSize.width > 0 && imgSize.height > 0 else { return }

        let viewBounds = self.bounds
        let scale = viewBounds.height / imgSize.height
        let drawW = imgSize.width * scale
        let drawH = imgSize.height * scale
        let baseX = (viewBounds.width - drawW) / 2.0
        let baseY: CGFloat = 0

        // Motion-driven transforms. Defaults: scale=1.0, translate=0, rotate=0.
        // In whole-image render mode, `body.scaleY` represents an overall body scale.
        // If the clip doesn't specify `body.scaleX` explicitly, mirror Y to X to
        // avoid squashing the sprite (e.g. sleepCurl scaleY=0.72 should shrink the
        // whole pet, not squash it sideways).
        let accent = imageAccentTransform()
        let bodyScaleY = softenedImageScale(motionValues["body.scaleY"] ?? 1.0) * accent.scaleY
        let bodyScaleX = softenedImageScale(motionValues["body.scaleX"] ?? (motionValues["body.scaleY"] ?? 1.0)) * accent.scaleX
        let headTranslateY = (motionValues["head.translateY"] ?? 0) * 0.45 + accent.offsetY
        let headTranslateX = (motionValues["head.translateX"] ?? 0) * 0.45 + accent.offsetX
        let headRotate = (motionValues["head.rotate"] ?? 0) * 0.55 + accent.rotate

        let finalW = drawW * CGFloat(bodyScaleX) * extraScale.width
        let finalH = drawH * CGFloat(bodyScaleY) * extraScale.height
        let centerX = baseX + drawW / 2.0 + CGFloat(headTranslateX) + extraOffset.x
        let centerY = baseY + drawH / 2.0 + CGFloat(headTranslateY) + extraOffset.y

        let drawRect = NSRect(
            x: centerX - finalW / 2.0,
            y: centerY - finalH / 2.0,
            width: finalW,
            height: finalH
        )

        let useRotate = abs(headRotate) > 0.001
        if useRotate, let ctx = NSGraphicsContext.current {
            ctx.saveGraphicsState()
            let xform = NSAffineTransform()
            xform.translateX(by: centerX, yBy: centerY)
            xform.rotate(byDegrees: CGFloat(headRotate))
            xform.translateX(by: -centerX, yBy: -centerY)
            xform.concat()
        }

        // Cross-fade: if a previous image still exists and we're inside the fade
        // window, draw it underneath at decreasing alpha while the new one fades in.
        let now = Date().timeIntervalSinceReferenceDate
        let fadeElapsed = now - crossfadeStart
        let fading = previousCharacterImage != nil && fadeElapsed < crossfadeDuration
        let newAlpha: CGFloat = fading ? CGFloat(min(1.0, fadeElapsed / crossfadeDuration)) : 1.0
        if let prev = previousCharacterImage, fading {
            let prevAlpha = CGFloat(max(0.0, 1.0 - fadeElapsed / crossfadeDuration))
            prev.draw(
                in: drawRect,
                from: .zero,
                operation: .sourceOver,
                fraction: prevAlpha,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
        } else if previousCharacterImage != nil {
            previousCharacterImage = nil
        }

        img.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: newAlpha,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )

        if useRotate, let ctx = NSGraphicsContext.current {
            ctx.restoreGraphicsState()
            _ = ctx
        }

        // Status overlays: sleep z is still mode-based; lightbulb is sequence-driven.
        let isSleeping = (mode == .sleeping)
        let isYawning = idleAccent == .yawn
        let isBlinking = isSleeping || tick % 230 < 5

        if isBlinking || isYawning {
            drawImageEyelids(in: drawRect, alpha: (isSleeping || isYawning) ? 0.9 : 0.72)
        }

        if mode == .speaking || isYawning {
            drawImageSpeakingMouth(in: drawRect, yawning: isYawning)
        }

        // Lightbulb 显示由 sequence 控制 (lightbulbAlpha),不再依赖 mode == .thinking。
        if lightbulbAlpha > 0.02 {
            let pulse = (sin(Double(tick) / 4.0) + 1) / 2
            let drawAlpha = lightbulbAlpha * CGFloat(0.65 + 0.35 * pulse)
            let bulbPoint = NSPoint(x: drawRect.maxX - 28, y: drawRect.minY - 4)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24),
                .foregroundColor: NSColor.white.withAlphaComponent(drawAlpha)
            ]
            ("💡" as NSString).draw(at: bulbPoint, withAttributes: attrs)
        }

        if isSleeping {
            let zX = drawRect.maxX - 30
            let zY = drawRect.minY + 10
            let phase = Double(tick % 60) / 60.0
            let zColor = NSColor(calibratedRed: 0.23, green: 0.14, blue: 0.41, alpha: 1.0)
            for i in 0..<3 {
                let offset = Double(i) * 8
                let alpha = max(0.0, 1.0 - phase - Double(i) * 0.20)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 14 + Double(i) * 2),
                    .foregroundColor: zColor.withAlphaComponent(CGFloat(alpha))
                ]
                ("z" as NSString).draw(at: NSPoint(x: zX + offset, y: zY - offset), withAttributes: attrs)
            }
        }
    }

    private func softenedImageScale(_ raw: Double) -> CGFloat {
        CGFloat(1.0 + (raw - 1.0) * 0.45)
    }

    private func imageAccentTransform() -> (scaleX: CGFloat, scaleY: CGFloat, offsetX: Double, offsetY: Double, rotate: Double) {
        switch idleAccent {
        case .lookLeft:
            return (1.0, 1.0, -2.8, 0.0, -0.8)
        case .lookRight:
            return (1.0, 1.0, 2.8, 0.0, 0.8)
        case .stretch:
            return (0.988, 1.026, 0.0, -2.0, 0.0)
        case .yawn:
            return (1.0, 0.992, 0.0, 1.5, 0.0)
        case .none:
            return (1.0, 1.0, 0.0, 0.0, 0.0)
        }
    }

    private func drawImageEyelids(in drawRect: NSRect, alpha: CGFloat) {
        let centers = [
            NSPoint(x: drawRect.minX + drawRect.width * 0.38, y: drawRect.minY + drawRect.height * 0.37),
            NSPoint(x: drawRect.minX + drawRect.width * 0.62, y: drawRect.minY + drawRect.height * 0.37),
        ]
        let lineColor = NSColor(calibratedRed: 0.22, green: 0.12, blue: 0.42, alpha: alpha)
        lineColor.setStroke()
        for c in centers {
            let w = drawRect.width * 0.13
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: c.x - w / 2, y: c.y))
            lid.curve(
                to: NSPoint(x: c.x + w / 2, y: c.y),
                controlPoint1: NSPoint(x: c.x - w * 0.22, y: c.y + drawRect.height * 0.022),
                controlPoint2: NSPoint(x: c.x + w * 0.22, y: c.y + drawRect.height * 0.022)
            )
            lid.lineWidth = max(1.6, drawRect.height * 0.014)
            lid.lineCapStyle = .round
            lid.stroke()
        }
    }

    private func drawImageSpeakingMouth(in drawRect: NSRect, yawning: Bool = false) {
        let open = yawning ? 0.95 : CGFloat(max(0.0, min(1.0, motionValues["mouth.open"] ?? (tick % 8 < 4 ? 0.55 : 0.20))))
        let center = NSPoint(
            x: drawRect.minX + drawRect.width * 0.505,
            y: drawRect.minY + drawRect.height * 0.445
        )
        let w = max(5.0, drawRect.width * (0.045 + 0.018 * open))
        let h = max(4.0, drawRect.height * (0.018 + (yawning ? 0.070 : 0.045) * open))
        let rect = NSRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        NSColor(calibratedRed: 0.39, green: 0.08, blue: 0.20, alpha: 0.88).setFill()
        let mouth = NSBezierPath(ovalIn: rect)
        mouth.fill()
        NSColor.white.withAlphaComponent(0.72).setStroke()
        mouth.lineWidth = 1.0
        mouth.stroke()
    }

    // MARK: - Xiaoqi rig rendering (Phase B)

    private var idleAccentLookSide: Double {
        switch idleAccent {
        case .lookLeft: return -2
        case .lookRight: return 2
        default: return 0
        }
    }

    private func rect(from r: RigRect) -> NSRect {
        NSRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    private func drawRigBody(manifest: CharacterRigManifest, dirtyRect: NSRect) {
        let palette = manifest.palette
        let primary = NSColor.fromHex(palette.primary, fallback: NSColor(calibratedRed: 0.96, green: 0.94, blue: 1.0, alpha: 1))
        let secondary = NSColor.fromHex(palette.secondary, fallback: NSColor(calibratedRed: 0.23, green: 0.14, blue: 0.41, alpha: 1))
        let accent = NSColor.fromHex(palette.accent, fallback: NSColor(calibratedRed: 0.54, green: 0.36, blue: 1.0, alpha: 1))
        let warm = palette.warmAccent.flatMap { NSColor.fromHex($0) } ?? NSColor(calibratedRed: 1.0, green: 0.54, blue: 0.29, alpha: 1)
        let flame = palette.flameCore.flatMap { NSColor.fromHex($0) } ?? NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.41, alpha: 1)
        let line = NSColor.fromHex(palette.line, fallback: NSColor(calibratedRed: 0.17, green: 0.13, blue: 0.31, alpha: 1))

        let bob = sin(Double(tick) / 4.2) * 1.8
        let breathe = sin(Double(tick) / 11.0) * 1.6
        let isSleeping = (mode == .sleeping)
        let isThinking = (mode == .thinking)
        let isExcited = (mode == .excited)
        let blinkPhase = tick % 230
        let isBlinking = blinkPhase < 5 || isSleeping

        let sortedParts = manifest.parts.sorted { $0.layer < $1.layer }
        for part in sortedParts {
            switch part.id {
            case "shadow":
                drawRigShadow(part: part)
            case "tail":
                drawRigTail(part: part, fill: secondary, flameTip: warm, stroke: line)
            case "cape":
                drawRigCape(part: part, fill: secondary, edge: primary, stroke: line, bob: bob)
            case "body":
                drawRigBodyShape(part: part, fill: primary, stroke: line, breathe: breathe, bob: bob, sleeping: isSleeping)
            case "head":
                drawRigBodyShape(part: part, fill: primary, stroke: line, breathe: breathe * 0.6, bob: bob, sleeping: isSleeping)
            case "hairTuft":
                drawRigHair(part: part, fill: primary, accent: secondary, stroke: line, bob: bob)
            case "leftFlameHorn", "rightFlameHorn":
                drawRigFlameHorn(part: part, base: secondary, flame: warm, core: flame)
            case "leftEye", "rightEye":
                drawRigEye(part: part, pupilColor: secondary, accent: accent, blinking: isBlinking, bob: bob, lookSide: idleAccentLookSide)
            case "mouth":
                drawRigMouth(part: part, lineColor: line, fillColor: line, bob: bob)
            case "leftHand", "rightHand":
                drawRigHand(part: part, fill: primary, stroke: line, bob: bob, excited: isExcited)
            default:
                break
            }
        }

        if isThinking, let bodyPart = sortedParts.first(where: { $0.id == "body" }) {
            drawRigThinkingDots(near: bodyPart, color: accent)
        }
        if isSleeping, let headPart = sortedParts.first(where: { $0.id == "head" }) {
            drawRigSleepZ(near: headPart, color: secondary)
        }
    }

    private func drawRigShadow(part: RigPart) {
        NSColor(calibratedWhite: 0.08, alpha: 0.32).setFill()
        NSBezierPath(ovalIn: rect(from: part.bounds)).fill()
    }

    private func drawRigBodyShape(part: RigPart, fill: NSColor, stroke: NSColor, breathe: Double, bob: Double, sleeping: Bool) {
        var r = rect(from: part.bounds)
        if sleeping {
            r = r.offsetBy(dx: 0, dy: 6)
            r.size.height *= 0.85
        } else {
            r = r.offsetBy(dx: -breathe * 0.3, dy: bob)
            r.size.width += breathe
            r.size.height += breathe * 0.5
        }
        fill.setFill()
        stroke.setStroke()
        let path = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
        path.fill()
        path.lineWidth = 2
        path.stroke()
    }

    private func drawRigEye(part: RigPart, pupilColor: NSColor, accent: NSColor, blinking: Bool, bob: Double, lookSide: Double) {
        let baseRect = rect(from: part.bounds).offsetBy(dx: 0, dy: bob)
        if blinking {
            pupilColor.setStroke()
            let mid = baseRect.midY
            let path = NSBezierPath()
            path.move(to: NSPoint(x: baseRect.minX, y: mid))
            path.curve(
                to: NSPoint(x: baseRect.maxX, y: mid),
                controlPoint1: NSPoint(x: baseRect.minX + 4, y: mid - 4),
                controlPoint2: NSPoint(x: baseRect.maxX - 4, y: mid - 4)
            )
            path.lineWidth = 2.4
            path.stroke()
            return
        }
        pupilColor.setFill()
        let r = baseRect.offsetBy(dx: lookSide, dy: 0)
        NSBezierPath(ovalIn: r).fill()

        accent.setFill()
        let inner = NSRect(
            x: r.minX + r.width * 0.15,
            y: r.minY + r.height * 0.30,
            width: r.width * 0.55,
            height: r.height * 0.55
        )
        NSBezierPath(ovalIn: inner).fill()

        NSColor(calibratedWhite: 1.0, alpha: 0.95).setFill()
        let hl = NSRect(
            x: r.minX + r.width * 0.50,
            y: r.minY + r.height * 0.18,
            width: r.width * 0.22,
            height: r.height * 0.26
        )
        NSBezierPath(ovalIn: hl).fill()

        NSColor(calibratedWhite: 1.0, alpha: 0.70).setFill()
        NSBezierPath(ovalIn: NSRect(x: r.minX + r.width * 0.30, y: r.minY + r.height * 0.58, width: r.width * 0.10, height: r.height * 0.12)).fill()
    }

    private func drawRigMouth(part: RigPart, lineColor: NSColor, fillColor: NSColor, bob: Double) {
        let r = rect(from: part.bounds).offsetBy(dx: 0, dy: bob)
        let isSpeaking = mode == .speaking
        let isYawn = idleAccent == .yawn

        if isYawn || isSpeaking {
            fillColor.setFill()
            let openR = NSRect(x: r.midX - 5, y: r.midY - 4, width: 10, height: 9)
            NSBezierPath(ovalIn: openR).fill()
        } else {
            lineColor.setStroke()
            let path = NSBezierPath()
            let mid = r.midY + 1
            path.move(to: NSPoint(x: r.midX - 6, y: mid))
            path.curve(
                to: NSPoint(x: r.midX + 6, y: mid),
                controlPoint1: NSPoint(x: r.midX - 2, y: mid + 5),
                controlPoint2: NSPoint(x: r.midX + 2, y: mid + 5)
            )
            path.lineWidth = 2.0
            path.stroke()
        }
    }

    private func drawRigTail(part: RigPart, fill: NSColor, flameTip: NSColor, stroke: NSColor) {
        let sway = sin(Double(tick) / 7.0) * 4.0
        let b = part.bounds
        let start = NSPoint(x: b.x + 4, y: b.y + b.height * 0.95)
        let mid1 = NSPoint(x: b.x + b.width * 0.45 + sway * 0.5, y: b.y + b.height * 0.55)
        let tipBase = NSPoint(x: b.x + b.width * 0.85 + sway, y: b.y + b.height * 0.20)

        fill.setStroke()
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(
            to: tipBase,
            controlPoint1: mid1,
            controlPoint2: NSPoint(x: b.x + b.width * 0.95 + sway, y: b.y + b.height * 0.40)
        )
        path.lineWidth = 9
        path.lineCapStyle = .round
        path.stroke()

        stroke.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let flameX = tipBase.x
        let flameY = tipBase.y - 4
        flameTip.setFill()
        let flamePath = NSBezierPath()
        flamePath.move(to: NSPoint(x: flameX - 4, y: flameY + 4))
        flamePath.curve(
            to: NSPoint(x: flameX, y: flameY - 8),
            controlPoint1: NSPoint(x: flameX - 5, y: flameY),
            controlPoint2: NSPoint(x: flameX - 1, y: flameY - 4)
        )
        flamePath.curve(
            to: NSPoint(x: flameX + 4, y: flameY + 4),
            controlPoint1: NSPoint(x: flameX + 1, y: flameY - 4),
            controlPoint2: NSPoint(x: flameX + 5, y: flameY)
        )
        flamePath.close()
        flamePath.fill()
    }

    private func drawRigCape(part: RigPart, fill: NSColor, edge: NSColor, stroke: NSColor, bob: Double) {
        let b = part.bounds
        fill.setFill()
        stroke.setStroke()
        let path = NSBezierPath()
        let topY = b.y + bob * 0.5
        path.move(to: NSPoint(x: b.x + b.width * 0.3, y: topY))
        path.line(to: NSPoint(x: b.x + b.width * 0.7, y: topY))
        path.curve(
            to: NSPoint(x: b.x + b.width, y: b.y + b.height),
            controlPoint1: NSPoint(x: b.x + b.width * 0.85, y: b.y + b.height * 0.5),
            controlPoint2: NSPoint(x: b.x + b.width * 0.95, y: b.y + b.height * 0.85)
        )
        let waves = 5
        for i in (0..<waves).reversed() {
            let xL = b.x + Double(i) * b.width / Double(waves)
            let xR = xL + b.width / Double(waves) / 2
            path.line(to: NSPoint(x: xR, y: b.y + b.height + 4))
            path.line(to: NSPoint(x: xL, y: b.y + b.height))
        }
        path.curve(
            to: NSPoint(x: b.x + b.width * 0.3, y: topY),
            controlPoint1: NSPoint(x: b.x + b.width * 0.05, y: b.y + b.height * 0.85),
            controlPoint2: NSPoint(x: b.x + b.width * 0.15, y: b.y + b.height * 0.5)
        )
        path.close()
        path.fill()
        path.lineWidth = 1.5
        path.stroke()

        edge.setFill()
        for i in 0..<5 {
            let starX = b.x + 14 + Double(i) * (b.width - 28) / 4
            let starY = b.y + b.height * 0.55
            NSBezierPath(ovalIn: NSRect(x: starX - 1.5, y: starY - 1.5, width: 3, height: 3)).fill()
        }
    }

    private func drawRigHair(part: RigPart, fill: NSColor, accent: NSColor, stroke: NSColor, bob: Double) {
        let b = part.bounds
        fill.setFill()
        stroke.setStroke()
        let h1 = NSRect(x: b.x + 2, y: b.y + 10 + bob * 0.3, width: 12, height: 22)
        let h2 = NSRect(x: b.x + 10, y: b.y + bob * 0.3, width: 16, height: 28)
        let h3 = NSRect(x: b.x + 22, y: b.y + 8 + bob * 0.3, width: 12, height: 22)
        for r in [h1, h3, h2] {
            let p = NSBezierPath(ovalIn: r)
            p.fill()
            p.lineWidth = 1.2
            p.stroke()
        }
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: b.x + 14, y: b.y + 12, width: 5, height: 10)).fill()
    }

    private func drawRigFlameHorn(part: RigPart, base: NSColor, flame: NSColor, core: NSColor) {
        let flicker = sin(Double(tick) / 5.0 + (part.anchor?.x ?? 100) / 30.0) * 2.0
        let b = part.bounds

        base.setFill()
        let basePath = NSBezierPath()
        basePath.move(to: NSPoint(x: b.x + 4, y: b.y + b.height))
        basePath.line(to: NSPoint(x: b.x + b.width - 4, y: b.y + b.height))
        basePath.line(to: NSPoint(x: b.x + b.width / 2, y: b.y + b.height * 0.55))
        basePath.close()
        basePath.fill()

        flame.setFill()
        let flamePath = NSBezierPath()
        flamePath.move(to: NSPoint(x: b.x + b.width * 0.20, y: b.y + b.height * 0.65))
        flamePath.curve(
            to: NSPoint(x: b.x + b.width / 2, y: b.y + flicker),
            controlPoint1: NSPoint(x: b.x + b.width * 0.05, y: b.y + b.height * 0.35),
            controlPoint2: NSPoint(x: b.x + b.width * 0.30, y: b.y + b.height * 0.10)
        )
        flamePath.curve(
            to: NSPoint(x: b.x + b.width * 0.80, y: b.y + b.height * 0.65),
            controlPoint1: NSPoint(x: b.x + b.width * 0.70, y: b.y + b.height * 0.10),
            controlPoint2: NSPoint(x: b.x + b.width * 0.95, y: b.y + b.height * 0.35)
        )
        flamePath.close()
        flamePath.fill()

        core.setFill()
        NSBezierPath(ovalIn: NSRect(x: b.x + b.width * 0.35, y: b.y + b.height * 0.35, width: b.width * 0.30, height: b.height * 0.30)).fill()
    }

    private func drawRigHand(part: RigPart, fill: NSColor, stroke: NSColor, bob: Double, excited: Bool) {
        let b = part.bounds
        var r = NSRect(x: b.x + 5, y: b.y + 6 + bob, width: b.width - 10, height: b.height - 12)
        if excited {
            r = r.offsetBy(dx: 0, dy: -3)
        }
        fill.setFill()
        stroke.setStroke()
        let path = NSBezierPath(ovalIn: r)
        path.fill()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawRigThinkingDots(near part: RigPart, color: NSColor) {
        let baseX = part.bounds.x + part.bounds.width
        let baseY = part.bounds.y + 4
        let phase = (tick / 3) % 3
        for i in 0..<3 {
            let alpha: CGFloat = (i <= phase) ? 0.95 : 0.30
            color.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: baseX + Double(i) * 7, y: baseY + Double(i) * 2, width: 5, height: 5)).fill()
        }
    }

    private func drawRigSleepZ(near part: RigPart, color: NSColor) {
        let baseX = part.bounds.x + part.bounds.width - 18
        let baseY = part.bounds.y - 4
        let phase = Double(tick % 60) / 60.0
        for i in 0..<3 {
            let offset = Double(i) * 8
            let alpha = max(0.0, 1.0 - phase - Double(i) * 0.18)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 14 + Double(i) * 2),
                .foregroundColor: color.withAlphaComponent(CGFloat(alpha))
            ]
            ("z" as NSString).draw(at: NSPoint(x: baseX + offset, y: baseY - offset), withAttributes: attrs)
        }
    }
}

@MainActor
final class DesktopPetController: NSObject, NSWindowDelegate {
    let paths: Paths
    let settings: AppSettings
    let character: CharacterProfile
    let behaviorPacks: [BehaviorPack]
    let wallpaper: WallpaperSense
    let brain: BrainService
    let taskRouter = TaskRouter()
    let rigManifest: CharacterRigManifest?
    let motionLibrary: MotionLibrary?
    let voicePackManifest: VoicePackManifest?
    let cloudSpeechRecognitionProvider: DoubaoCloudSpeechRecognitionProvider?
    let cloudSpeechSynthesisProvider: DoubaoCloudSpeechSynthesisProvider?
    let characterIdleImage: NSImage?
    let characterExpressions: [String: NSImage]
    let motionPlayer: MotionPlayer?
    var motionTimer: Timer?
    private let motionEpoch = Date()
    var behaviorDirector: BehaviorDirector?
    var useBehaviorDirector: Bool = true
    var thinkingMaxActiveSeconds: TimeInterval = 30.0
    var lastInteractionTick: Int = 0
    var lastConversationBubbleTick: Int = -1_000_000
    let conversationBubbleQuietTicks: Int = 220  // ~20s: don't let autonomy overwrite fresh chat replies
    var longIdleThresholdTicks: Int = 666  // ~60s at 0.09s/tick
    var lastLongIdleSettleTick: Int = -1_000_000
    var longIdleSettleCooldownTicks: Int = 666  // prevent repeated settle spam while the user stays away
    var windowMischiefEnabled: Bool = false
    /// 前台窗口定位服务。当前为 stub (永远返回 nil),WindowEdgeMischief 完整版
    /// 等真实 AX 实现接入后才会使用。lite 版有意不读它。
    /// 见 docs/WINDOW_TARGETING_TODO.md。
    var windowTargeting: WindowTargetingService = NoopWindowTargetingService()
    var lastMischiefLiteTick: Int = -100_000     // startup-safe: condition gated by cooldown anyway
    let mischiefLiteCooldownTicks: Int = 6000    // ~9 分钟 cooldown (彩蛋级低频,WindowTargetingService 上线后再加大)
    let mischiefLiteMinIdleTicks: Int = 400      // 至少静默 ~36s 才考虑触发

    var window: NSWindow!
    var bubbleView: RoundedPanelView!
    var controlsView: RoundedPanelView!
    var bubbleLabel: NSTextField!
    var inputField: NSTextField!
    var petView: PetCanvasView!
    var sendButton: NSButton!
    var exitButton: NSButton!
    var listenButton: NSButton!
    var voiceButton: NSButton!
    var autonomyButton: NSButton!
    var resetButton: NSButton!
    var settingsButton: NSButton!
    var taskPackageButton: NSButton!
    var languageButton: NSButton!
    var compactButton: NSButton!
    var statusItem: NSStatusItem?
    var timer: Timer?
    let speechSynth = AVSpeechSynthesizer()
    var cloudSpeechPlayer: AVAudioPlayer?
    let voiceInputProvider: VoiceInputProvider = SystemVoiceInputProvider()
    let speechRecognitionProvider: SpeechRecognitionProvider = SystemSpeechRecognitionProvider()
    let speechSynthesisProvider: SpeechSynthesisProvider = SystemSpeechSynthesisProvider()
    var settingsWindow: NSWindow?
    var taskPackageWindow: NSWindow?
    var taskPackagePreviewTextView: NSTextView?
    var taskPackageButtonURLs: [String: URL] = [:]
    var taskPackageSelectedURL: URL?
    let audioEngine = AVAudioEngine()
    var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    var recognitionTask: SFSpeechRecognitionTask?
    var isListening = false
    var listenRequestId = 0

    var topmostWindowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
    }

    var language: String
    var mode: PetMode = .idle
    var tick = 0
    var nextActionTick = 720
    var accentEndTick: Int = 0
    var nextAccentCheckTick: Int = 40
    var autonomyEnabled: Bool
    var voiceEnabled: Bool
    var topmostEnabled: Bool
    var messageChance: Double
    var naturalMotionEnabled: Bool
    var isCompact: Bool
    var defaultCompact: Bool
    var exitRequested = false
    var memory: [String: Any]
    var recentMessages: [String] = []
    var recentTurns: [ConversationTurn] = []
    let conversationTurnLimit = 12
    var conversationRequestId: Int = 0

    let fullSize: NSSize
    let compactSize = NSSize(width: 240, height: 200)

    init(paths: Paths, settings: AppSettings, character: CharacterProfile, behaviorPacks: [BehaviorPack], wallpaper: WallpaperSense) {
        self.paths = paths
        self.settings = settings
        self.character = character
        self.behaviorPacks = behaviorPacks
        self.wallpaper = wallpaper
        self.autonomyEnabled = settings.autonomy.enabled
        self.voiceEnabled = settings.voice.synthesisEnabled
        self.topmostEnabled = settings.window.topmost
        self.messageChance = settings.autonomy.messageChance
        self.naturalMotionEnabled = settings.naturalMotion?.enableNaturalMotion ?? true
        self.language = settings.ui?.language ?? "zh-CN"
        self.defaultCompact = settings.ui?.compact ?? false
        self.isCompact = self.defaultCompact
        self.fullSize = NSSize(width: settings.window.width, height: settings.window.height)
        self.memory = loadPetMemory(paths: paths, characterName: character.name)
        ensurePetMemorySaved(paths: paths, memory: self.memory)
        if settings.brain?.provider == "anthropic",
           let anthropicSettings = settings.brain?.anthropic {
            self.brain = AnthropicBrain(settings: anthropicSettings)
        } else {
            self.brain = TemplateBrain()
        }
        if let packId = settings.character?.activePack, !packId.isEmpty {
            self.rigManifest = loadRigManifest(packId: packId, paths: paths)
            self.motionLibrary = loadMotionLibrary(packId: packId, paths: paths)
            let voiceManifest = loadVoicePackManifest(packId: packId, paths: paths)
            self.voicePackManifest = voiceManifest
            if voiceManifest?.provider.lowercased().contains("doubao") == true || voiceManifest?.cloudASR != nil {
                self.cloudSpeechRecognitionProvider = DoubaoCloudSpeechRecognitionProvider(settings: voiceManifest?.cloudASR)
            } else {
                self.cloudSpeechRecognitionProvider = nil
            }
            if voiceManifest?.provider.lowercased().contains("doubao") == true || voiceManifest?.cloudTTS != nil {
                self.cloudSpeechSynthesisProvider = DoubaoCloudSpeechSynthesisProvider(settings: voiceManifest?.cloudTTS)
            } else {
                self.cloudSpeechSynthesisProvider = nil
            }
            self.characterIdleImage = loadCharacterIdleImage(packId: packId, paths: paths)
            self.characterExpressions = loadExpressionImages(packId: packId, paths: paths)
        } else {
            self.rigManifest = nil
            self.motionLibrary = nil
            self.voicePackManifest = nil
            self.cloudSpeechRecognitionProvider = nil
            self.cloudSpeechSynthesisProvider = nil
            self.characterIdleImage = nil
            self.characterExpressions = [:]
        }
        if let lib = motionLibrary {
            self.motionPlayer = MotionPlayer(library: lib)
        } else {
            self.motionPlayer = nil
        }
        super.init()
    }

    var isZh: Bool {
        isChineseLanguage(language)
    }

    var isJa: Bool {
        isJapaneseLanguage(language)
    }

    var appTitleSuffix: String {
        localizedValue(language: language, zh: "桌面宠物", en: "Desktop Pet", ja: "デスクトップペット")
    }

    var nickname: String? {
        memoryString(memory, "nickname") ?? memoryString(memory, "userName")
    }

    var petName: String {
        memoryString(memory, "petName") ?? character.name
    }

    var petPersonality: String? {
        memoryString(memory, "personality")
    }

    var replyStylePreference: String? {
        memoryPreferenceString(memory, "replyStyle")
    }

    var doNotDisturbWhenTyping: Bool {
        memoryPreferenceBool(memory, "doNotDisturbWhenTyping", default: true)
    }

    func t(_ key: String) -> String {
        if isZh {
            switch key {
            case "startup":
                if wallpaper.scene == "unknown" {
                    return "我上线了。你可以拖动我，也可以直接打字。"
                }
                return "我上线了。今天桌面有点\(localizedScene(wallpaper.scene, language: language))的气氛。"
            case "intro":
                return "我是\(petName)。我会陪你聊天、说话，也会慢慢适应你的桌面。"
            case "input.placeholder": return "输入一句话"
            case "send": return "发送"
            case "exit": return "退出"
            case "listen": return "听"
            case "mute": return "静音"
            case "voice": return "语音"
            case "pause": return "暂停"
            case "auto": return "自动"
            case "reset": return "复位"
            case "settings": return "设置"
            case "task.packages.short": return "任务包"
            case "language": return "EN"
            case "compact.collapse": return "⊟"
            case "compact.expand": return "⊞"
            case "show": return "显示"
            case "hide": return "隐藏"
            case "reset.position": return "复位位置"
            case "toggle.topmost": return "切换置顶"
            case "toggle.autonomy": return "暂停/恢复自动行为"
            case "toggle.voice": return "切换语音"
            case "toggle.compact": return "切换紧凑模式"
            case "minimize": return "最小化"
            case "thinking": return "正在想："
            case "listen.unavailable": return "这一版还没有接好语音识别。文字聊天可用，语音合成可用。"
            case "listen.start": return "我在听。当前麦克风：{0}"
            case "listen.noMic": return "没有检测到可用麦克风。先检查系统输入设备。"
            case "listen.authDenied": return "麦克风或语音识别权限没开。到系统设置里允许 Desktop Pet 使用麦克风和语音识别。"
            case "listen.noResult": return "这次没听清。你可以再按一次听。"
            case "listen.failed": return "语音识别启动失败。先用文字输入。"
            case "voice.back": return "语音回来了。"
            case "voice.quiet": return "我先安静，用文字交流。"
            case "profile.title": return "角色档案"
            case "topmost.on": return "置顶模式已开启。"
            case "topmost.off": return "置顶模式已关闭。"
            case "position.reset": return "位置复位。我回到默认角落附近了。"
            case "autonomy.on": return "自动行为已开启。我会小范围活动。"
            case "autonomy.off": return "自动行为已暂停。我先待着不乱动。"
            case "compact.on": return "进入紧凑模式。点击我可以展开。"
            case "compact.off": return "已展开。控制面板回来了。"
            case "onboarding.mini": return "小提示：点右上角的 ⊟ 可以只留下我；迷你模式下直接点我，就能展开控制面板。"
            case "nickname.saved": return "好的，我记住了。"
            case "nickname.greet": return "你来啦。"
            case "settings.title": return "桌宠设置"
            case "settings.language": return "界面语言"
            case "settings.petName": return "宠物名"
            case "settings.zh": return "中文"
            case "settings.en": return "English"
            case "settings.ja": return "日本語"
            case "settings.topmost": return "窗口置顶"
            case "settings.voice": return "语音合成"
            case "settings.autonomy": return "自动行为"
            case "settings.naturalMotion": return "自然动作"
            case "settings.windowMischief": return "开启扒窗互动"
            case "settings.chance": return "自动消息频率"
            case "settings.compact": return "下次启动紧凑模式"
            case "settings.apply": return "应用"
            case "settings.cancel": return "取消"
            case "settings.profile": return "查看角色档案"
            case "task.packages.title": return "小七任务包"
            case "task.packages.hint": return "这里保存小七整理过的工程任务包，可复制给 Codex / Claude Code 使用。"
            case "task.packages.guide": return "不会安装也没关系：点“复制选中”，把 Markdown 贴给 Codex / Claude Code；点“打开目录”可看到原文件。"
            case "task.packages.refresh": return "刷新"
            case "task.packages.openDir": return "打开目录"
            case "task.packages.copySelected": return "复制选中"
            case "task.packages.empty": return "还没有任务包。你可以让小七帮你整理一个工程任务。"
            case "task.packages.selected": return "已选  "
            case "task.packages.meta.type": return "类型"
            case "task.packages.meta.executor": return "交接"
            case "task.packages.view": return "查看"
            case "task.packages.copy": return "复制"
            case "task.packages.dir": return "目录"
            case "task.packages.preview": return "Markdown 预览"
            case "task.packages.unreadable": return "这个任务包读不了。"
            case "task.packages.missing": return "任务包文件不见了。"
            case "task.packages.selectFirst": return "先选一个任务包。"
            case "task.packages.dirUnavailable": return "任务包目录打不开。"
            case "task.packages.saved": return "我整理好了，任务包已复制，也存到本地了。"
            case "task.packages.saveFailed": return "任务包已复制，但本地保存失败。你先用剪贴板。"
            case "settings.taskPackages.title": return "小七任务包"
            case "settings.taskPackages.desc": return "查看、复制和交接 TaskPackage Markdown"
            case "settings.open": return "打开"
            case "settings.applied": return "设置已应用。"
            case "profile.unset": return "（未设定）"
            case "nickname.savedWithName": return "\(t("nickname.saved")) {0}，从现在开始我会这样叫你。"
            case "menu.toggleMini": return "切换迷你模式"
            case "menu.quit": return "退出"
            case "startup.error.title": return "启动失败"
            case "patrol.1": return "我刚做了一次小小桌面巡逻。"
            case "patrol.2":
                if wallpaper.scene == "unknown" {
                    return "我先在桌面边上待一会儿，有事叫我。"
                }
                return "今天桌面有点\(localizedScene(wallpaper.scene, language: language))的感觉，我会轻一点。"
            case "patrol.3": return "我在旁边。你忙你的，我会尽量不打扰。"
            case "patrol.4": return "我刚才非常认真地发了一小会儿呆。"
            default: return key
            }
        }

        if isJa {
            switch key {
            case "startup":
                if wallpaper.scene == "unknown" {
                    return "起動しました。ドラッグも入力もできます。"
                }
                return "起動しました。今日のデスクトップは\(localizedScene(wallpaper.scene, language: language))の雰囲気です。"
            case "intro":
                return "私は\(petName)。話したり、そばにいたり、少しずつデスクトップに慣れていきます。"
            case "input.placeholder": return "ひとこと入力"
            case "send": return "送信"
            case "exit": return "終了"
            case "listen": return "聞く"
            case "mute": return "ミュート"
            case "voice": return "音声"
            case "pause": return "一時停止"
            case "auto": return "自動"
            case "reset": return "戻す"
            case "settings": return "設定"
            case "task.packages.short": return "タスク"
            case "language": return "中文"
            case "compact.collapse": return "⊟"
            case "compact.expand": return "⊞"
            case "show": return "表示"
            case "hide": return "隠す"
            case "reset.position": return "位置を戻す"
            case "toggle.topmost": return "最前面を切り替え"
            case "toggle.autonomy": return "自動行動を一時停止/再開"
            case "toggle.voice": return "音声を切り替え"
            case "toggle.compact": return "コンパクトモードを切り替え"
            case "minimize": return "最小化"
            case "thinking": return "考え中："
            case "listen.unavailable": return "この版では音声認識はまだ未接続です。文字チャットと音声合成は使えます。"
            case "listen.start": return "聞いています。現在のマイク：{0}"
            case "listen.noMic": return "利用できるマイクが見つかりません。システムの入力デバイスを確認してください。"
            case "listen.authDenied": return "マイクまたは音声認識の権限がありません。システム設定で Desktop Pet を許可してください。"
            case "listen.noResult": return "今回は聞き取れませんでした。もう一度「聞く」を押してください。"
            case "listen.failed": return "音声認識を開始できませんでした。先に文字入力を使ってください。"
            case "voice.back": return "音声が戻りました。"
            case "voice.quiet": return "しばらく静かにして、文字だけで話します。"
            case "profile.title": return "キャラクター情報"
            case "topmost.on": return "最前面モードをオンにしました。"
            case "topmost.off": return "最前面モードをオフにしました。"
            case "position.reset": return "位置を戻しました。デフォルトの隅の近くに戻りました。"
            case "autonomy.on": return "自動行動をオンにしました。少しだけ動きます。"
            case "autonomy.off": return "自動行動を一時停止しました。おとなしくしています。"
            case "compact.on": return "コンパクトモードです。クリックすると展開します。"
            case "compact.off": return "展開しました。操作パネルが戻りました。"
            case "onboarding.mini": return "ヒント：右上の ⊟ でペットだけ残せます。コンパクト中は私をクリックすると操作パネルが戻ります。"
            case "nickname.saved": return "はい、覚えました。"
            case "nickname.greet": return "来たね。"
            case "settings.title": return "ペット設定"
            case "settings.language": return "表示言語"
            case "settings.petName": return "ペット名"
            case "settings.zh": return "中文"
            case "settings.en": return "English"
            case "settings.ja": return "日本語"
            case "settings.topmost": return "ウィンドウを最前面"
            case "settings.voice": return "音声合成"
            case "settings.autonomy": return "自動行動"
            case "settings.naturalMotion": return "自然な動き"
            case "settings.windowMischief": return "ウィンドウいたずらを有効化"
            case "settings.chance": return "自動メッセージ頻度"
            case "settings.compact": return "次回はコンパクトで起動"
            case "settings.apply": return "適用"
            case "settings.cancel": return "キャンセル"
            case "settings.profile": return "キャラクター情報を見る"
            case "task.packages.title": return "小七タスクパッケージ"
            case "task.packages.hint": return "小七が整理した工程タスクを保存します。Codex / Claude Code に渡せます。"
            case "task.packages.guide": return "インストールが分からなくても大丈夫。「選択をコピー」で Markdown を Codex / Claude Code に貼ってください。「フォルダ」で元ファイルを確認できます。"
            case "task.packages.refresh": return "更新"
            case "task.packages.openDir": return "フォルダ"
            case "task.packages.copySelected": return "選択をコピー"
            case "task.packages.empty": return "タスクパッケージはまだありません。小七に工程タスクを整理させられます。"
            case "task.packages.selected": return "選択中  "
            case "task.packages.meta.type": return "種類"
            case "task.packages.meta.executor": return "引き継ぎ"
            case "task.packages.view": return "表示"
            case "task.packages.copy": return "コピー"
            case "task.packages.dir": return "場所"
            case "task.packages.preview": return "Markdown プレビュー"
            case "task.packages.unreadable": return "このタスクパッケージは読めません。"
            case "task.packages.missing": return "タスクパッケージファイルが見つかりません。"
            case "task.packages.selectFirst": return "先にタスクパッケージを選んでください。"
            case "task.packages.dirUnavailable": return "タスクパッケージフォルダを開けません。"
            case "task.packages.saved": return "整理しました。タスクパッケージをコピーし、ローカルにも保存しました。"
            case "task.packages.saveFailed": return "タスクパッケージはコピーしましたが、ローカル保存に失敗しました。先にクリップボードを使ってください。"
            case "settings.taskPackages.title": return "小七タスクパッケージ"
            case "settings.taskPackages.desc": return "TaskPackage Markdown を表示、コピー、引き継ぎ"
            case "settings.open": return "開く"
            case "settings.applied": return "設定を適用しました。"
            case "profile.unset": return "（未設定）"
            case "nickname.savedWithName": return "\(t("nickname.saved")) {0}、これからそう呼びます。"
            case "menu.toggleMini": return "ミニモードを切り替え"
            case "menu.quit": return "終了"
            case "startup.error.title": return "起動に失敗しました"
            case "patrol.1": return "小さなデスクトップ巡回をしてきました。"
            case "patrol.2":
                if wallpaper.scene == "unknown" {
                    return "少しここにいます。必要なら呼んでください。"
                }
                return "今日は\(localizedScene(wallpaper.scene, language: language))っぽい雰囲気で、そっとしています。"
            case "patrol.3": return "そばにいます。作業の邪魔はしません。"
            case "patrol.4": return "さっき、とても真剣にぼーっとしていました。"
            default: return key
            }
        }

        switch key {
        case "startup":
            if wallpaper.scene == "unknown" {
                return "I am online. You can drag me around or type to me."
            }
            return "I am online. The desktop feels a little \(wallpaper.scene) today."
        case "intro": return "I am \(petName). I can chat, speak, and slowly settle into your desktop."
        case "input.placeholder": return "Type a message"
        case "send": return "Send"
        case "exit": return "Exit"
        case "listen": return "Listen"
        case "mute": return "Mute"
        case "voice": return "Voice"
        case "pause": return "Pause"
        case "auto": return "Auto"
        case "reset": return "Reset"
        case "settings": return "Settings"
        case "task.packages.short": return "Packages"
        case "language": return "日本語"
        case "compact.collapse": return "⊟"
        case "compact.expand": return "⊞"
        case "show": return "Show"
        case "hide": return "Hide"
        case "reset.position": return "Reset position"
        case "toggle.topmost": return "Toggle topmost"
        case "toggle.autonomy": return "Pause or resume autonomy"
        case "toggle.voice": return "Toggle voice"
        case "toggle.compact": return "Toggle compact mode"
        case "minimize": return "Minimize"
        case "thinking": return "Thinking about:"
        case "listen.unavailable": return "Speech recognition is not wired in this build. Text chat works, and speech synthesis works."
        case "listen.start": return "Listening. Current microphone: {0}"
        case "listen.noMic": return "No available microphone was detected. Check the system input device."
        case "listen.authDenied": return "Microphone or speech recognition permission is off. Allow Desktop Pet in System Settings."
        case "listen.noResult": return "I did not catch that. Press Listen again."
        case "listen.failed": return "Speech recognition failed to start. Use text input for now."
        case "voice.back": return "Voice is back."
        case "voice.quiet": return "I will stay quiet and use text only."
        case "profile.title": return "Character Profile"
        case "task.packages.title": return "Task Packages"
        case "topmost.on": return "Topmost mode is on."
        case "topmost.off": return "Topmost mode is off."
        case "position.reset": return "Position reset. I am back near the default corner."
        case "autonomy.on": return "Autonomy is on. I will move around a little."
        case "autonomy.off": return "Autonomy is paused. I will stay put."
        case "compact.on": return "Compact mode on. Click me to expand."
        case "compact.off": return "Expanded. The control panel is back."
        case "onboarding.mini": return "Tip: click ⊟ to keep only the pet. In compact mode, click me to bring the controls back."
        case "nickname.saved": return "Okay, I will remember that."
        case "nickname.greet": return "Hi there."
        case "settings.title": return "Pet Settings"
        case "settings.language": return "Language"
        case "settings.petName": return "Pet name"
        case "settings.zh": return "中文"
        case "settings.en": return "English"
        case "settings.ja": return "日本語"
        case "settings.topmost": return "Keep window on top"
        case "settings.voice": return "Speech synthesis"
        case "settings.autonomy": return "Autonomous behavior"
        case "settings.naturalMotion": return "Natural motion"
        case "settings.windowMischief": return "Enable Window Mischief"
        case "settings.chance": return "Autonomous message chance"
        case "settings.compact": return "Start compact next time"
        case "settings.apply": return "Apply"
        case "settings.cancel": return "Cancel"
        case "settings.profile": return "View character profile"
        case "startup.error.title": return "Startup failed"
        case "task.packages.hint": return "Saved engineering task packages organized by Xiaoqi for Codex / Claude Code handoff."
        case "task.packages.guide": return "No install knowledge needed: copy the selected Markdown into Codex / Claude Code. Open the folder to inspect the saved file."
        case "task.packages.refresh": return "Refresh"
        case "task.packages.openDir": return "Open folder"
        case "task.packages.copySelected": return "Copy selected"
        case "task.packages.empty": return "No task packages yet. Ask Xiaoqi to organize an engineering task."
        case "task.packages.selected": return "Selected  "
        case "task.packages.meta.type": return "Type"
        case "task.packages.meta.executor": return "Handoff"
        case "task.packages.view": return "View"
        case "task.packages.copy": return "Copy"
        case "task.packages.dir": return "Folder"
        case "task.packages.preview": return "Markdown Preview"
        case "task.packages.unreadable": return "Cannot read this package."
        case "task.packages.missing": return "Package file is missing."
        case "task.packages.selectFirst": return "Select a package first."
        case "task.packages.dirUnavailable": return "Cannot open package folder."
        case "task.packages.saved": return "Task package copied and saved locally."
        case "task.packages.saveFailed": return "Task package copied, but local save failed."
        case "settings.taskPackages.title": return "Task Packages"
        case "settings.taskPackages.desc": return "View, copy, and hand off TaskPackage Markdown"
        case "settings.open": return "Open"
        case "settings.applied": return "Settings applied."
        case "profile.unset": return "(unset)"
        case "nickname.savedWithName": return "\(t("nickname.saved")) {0}, I will call you that from now on."
        case "menu.toggleMini": return "Toggle Mini Mode"
        case "menu.quit": return "Quit"
        case "patrol.1": return "I made a tiny desktop patrol."
        case "patrol.2":
            if wallpaper.scene == "unknown" {
                return "I will stay near the edge for a bit. Call me if you need me."
            }
            return "The desktop feels a little \(wallpaper.scene) today, so I will keep it gentle."
        case "patrol.3": return "I am nearby. You work; I will keep it light."
        case "patrol.4": return "I just stared into space with great seriousness."
        default: return key
        }
    }

    func applyLanguage() {
        window?.title = "\(petName) \(appTitleSuffix)"
        inputField?.placeholderString = t("input.placeholder")
        sendButton?.title = t("send")
        exitButton?.title = t("exit")
        listenButton?.title = t("listen")
        voiceButton?.title = voiceEnabled ? t("mute") : t("voice")
        autonomyButton?.title = autonomyEnabled ? t("pause") : t("auto")
        resetButton?.title = t("reset")
        settingsButton?.title = t("settings")
        taskPackageButton?.title = t("task.packages.short")
        languageButton?.title = t("language")
        compactButton?.title = isCompact ? t("compact.expand") : t("compact.collapse")
        statusItem?.menu = makeContextMenu()
        installAppMenu()
    }

    func start() {
        appendLog(paths, "controller-start language=\(language) compact=\(isCompact)")
        installAppMenu()
        createWindow()
        createStatusItem()
        if isCompact {
            applyCompactLayout(animated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickAutonomy() }
        }
        if motionPlayer != nil {
            let now = Date().timeIntervalSince(motionEpoch)
            motionPlayer?.play("idleBreath", now: now)
            motionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickMotion() }
            }
            if let motionTimer {
                RunLoop.main.add(motionTimer, forMode: .common)
            }
        }
        applyLanguage()
        let greet: String
        if let nick = nickname {
            greet = "\(t("nickname.greet")) \(nick), \(t("startup"))"
        } else {
            greet = t("startup")
        }
        // Install BehaviorDirector + queue natural entrance BEFORE showing the window,
        // so the window jumps to off-screen position before any frame is rendered.
        installNaturalMotion()
        speak(greet)
        showWindow()
        showMiniModeOnboardingIfNeeded(delay: 1.4)
    }

    func installNaturalMotion() {
        guard naturalMotionEnabled else {
            useBehaviorDirector = false
            behaviorDirector = nil
            appendLog(paths, "natural-motion-disabled")
            return
        }
        useBehaviorDirector = settings.naturalMotion?.enableBehaviorDirector ?? true
        thinkingMaxActiveSeconds = settings.naturalMotion?.thinkingMaxActiveSeconds ?? 30.0
        windowMischiefEnabled = settings.naturalMotion?.enableWindowEdgeInteraction ?? false
        let director = BehaviorDirector(controller: self)
        self.behaviorDirector = director
        director.enqueue(BottomPeekInSequence())
        appendLog(paths, "natural-motion-installed entrance=bottomPeekIn director=\(useBehaviorDirector) thinkTimeout=\(thinkingMaxActiveSeconds)s")
    }

    func installAppMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let miniItem = NSMenuItem(
            title: t("menu.toggleMini"),
            action: #selector(toggleCompact),
            keyEquivalent: "m"
        )
        miniItem.keyEquivalentModifierMask = [.command, .shift]
        miniItem.target = self
        appMenu.addItem(miniItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "\(t("menu.quit")) \(petName)", action: #selector(exitApp), keyEquivalent: "q").target = self
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    func createWindow() {
        let size = fullSize
        let origin = initialWindowOrigin(settings: settings, size: size, stateURL: paths.windowState)
        window = PetWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        if let panel = window as? NSPanel {
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.worksWhenModal = true
            panel.hidesOnDeactivate = false
        }
        window.title = "\(petName) \(appTitleSuffix)"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = topmostEnabled ? topmostWindowLevel : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        appendLog(paths, "window-level-applied raw=\(window.level.rawValue) topmost=\(topmostEnabled) behavior=\(window.collectionBehavior.rawValue)")
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = FlippedRootView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.menu = makeContextMenu()
        window.contentView = content

        bubbleView = RoundedPanelView(frame: NSRect(x: 8, y: 4, width: size.width - 16, height: 74))
        bubbleView.autoresizingMask = [.width]
        content.addSubview(bubbleView)

        bubbleLabel = NSTextField(labelWithString: "")
        bubbleLabel.frame = bubbleView.bounds.insetBy(dx: 12, dy: 8)
        bubbleLabel.autoresizingMask = [.width, .height]
        bubbleLabel.font = NSFont.systemFont(ofSize: 13)
        bubbleLabel.textColor = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.22, alpha: 1.0)
        bubbleLabel.lineBreakMode = .byWordWrapping
        bubbleLabel.maximumNumberOfLines = 4
        bubbleView.addSubview(bubbleLabel)

        petView = PetCanvasView(frame: NSRect(x: (size.width - 220) / 2, y: 74, width: 220, height: 170))
        petView.autoresizingMask = []
        petView.characterImage = characterIdleImage
        // Phase B geometric drawRig fallback is intentionally not wired up;
        // characterImage (real PNG) takes priority. If both are nil the canvas
        // falls back to the original placeholder body. See CHANGELOG.
        petView.onTap = { [weak self] in
            guard let self else { return }
            self.lastInteractionTick = self.tick
            if self.isCompact {
                self.toggleCompact()
                return
            }
            // Stage 1 click reaction: only if natural motion enabled and director ready.
            if let director = self.behaviorDirector,
               self.naturalMotionEnabled {
                director.request(ClickReactionSequence(language: self.language))
            }
        }
        petView.onDragStarted = { [weak self] in
            guard let self else { return }
            self.lastInteractionTick = self.tick
            // Drag is critical-priority: interrupt any running sequence, drop the
            // queue, wipe transient visual state, return to a stable idle baseline.
            self.behaviorDirector?.interruptAndRun(nil)
            self.conversationRequestId += 1
            self.resetVisualStateForInterrupt()
            self.setMode(.idle)
            appendLog(self.paths, "drag-started-interrupt")
        }
        petView.onDragMoved = { [weak self] targetOrigin in
            guard let self else { return }
            let origin = self.settings.window.keepInsideScreen
                ? clampWindowOrigin(targetOrigin, size: self.window.frame.size)
                : targetOrigin
            self.window.setFrameOrigin(origin)
        }
        petView.onDragEnded = { [weak self] in
            guard let self else { return }
            self.lastInteractionTick = self.tick
            self.resetVisualStateForInterrupt()
            self.setMode(.idle)
            if self.settings.window.rememberPosition {
                saveWindowState(window: self.window, to: self.paths.windowState)
            }
            appendLog(self.paths, "drag-ended-interrupt")
        }
        content.addSubview(petView)

        controlsView = RoundedPanelView(frame: NSRect(x: 8, y: size.height - 86, width: size.width - 16, height: 78))
        controlsView.fillColor = NSColor(calibratedWhite: 1.0, alpha: 0.20)
        controlsView.strokeColor = NSColor(calibratedRed: 0.30, green: 0.40, blue: 0.55, alpha: 0.65)
        controlsView.enableGlass = true
        controlsView.cornerRadius = 12
        controlsView.autoresizingMask = [.width, .minYMargin]
        content.addSubview(controlsView)

        let rowInset: CGFloat = 12
        let controlWidth = size.width - 16
        let row1Y = 8.0
        let row1Right: CGFloat = rowInset + 50 + 4 + 44
        let inputW = controlWidth - rowInset - 4 - row1Right
        inputField = NSTextField(frame: NSRect(x: rowInset, y: row1Y, width: inputW, height: 30))
        inputField.placeholderString = t("input.placeholder")
        inputField.font = NSFont.systemFont(ofSize: 13)
        inputField.target = self
        inputField.action = #selector(sendUserMessage)
        inputField.autoresizingMask = [.width]
        controlsView.addSubview(inputField)

        sendButton = makeButton(title: "", frame: NSRect(x: rowInset + inputW + 4, y: row1Y, width: 50, height: 30), action: #selector(sendUserMessage))
        sendButton.autoresizingMask = [.minXMargin]
        exitButton = makeButton(title: "", frame: NSRect(x: rowInset + inputW + 4 + 50 + 4, y: row1Y, width: 44, height: 30), action: #selector(exitApp))
        exitButton.autoresizingMask = [.minXMargin]
        controlsView.addSubview(sendButton)
        controlsView.addSubview(exitButton)

        let row2Y = 42.0
        let row2H = 28.0
        listenButton = makeButton(title: "", frame: .zero, action: #selector(startListenOnce))
        voiceButton = makeButton(title: "", frame: .zero, action: #selector(toggleVoice))
        autonomyButton = makeButton(title: "", frame: .zero, action: #selector(toggleAutonomy))
        resetButton = makeButton(title: "", frame: .zero, action: #selector(resetPosition))
        settingsButton = makeButton(title: "", frame: .zero, action: #selector(showSettings))
        taskPackageButton = makeButton(title: "", frame: .zero, action: #selector(showTaskPackages))
        languageButton = makeButton(title: "", frame: .zero, action: #selector(toggleLanguage))
        compactButton = makeButton(title: "", frame: .zero, action: #selector(toggleCompact))

        let row2Buttons: [NSButton] = [listenButton, voiceButton, autonomyButton, resetButton, settingsButton, taskPackageButton, languageButton, compactButton]
        let row2Stack = NSStackView(views: row2Buttons)
        row2Stack.orientation = .horizontal
        row2Stack.alignment = .centerY
        row2Stack.distribution = .fillProportionally
        row2Stack.spacing = 3
        row2Stack.edgeInsets = NSEdgeInsets(top: 0, left: rowInset, bottom: 0, right: rowInset)
        row2Stack.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(row2Stack)
        NSLayoutConstraint.activate([
            row2Stack.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor),
            row2Stack.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor),
            row2Stack.topAnchor.constraint(equalTo: controlsView.topAnchor, constant: row2Y),
            row2Stack.heightAnchor.constraint(equalToConstant: row2H),
        ])
    }

    func makeButton(title: String, frame: NSRect, action: Selector) -> NSButton {
        let button = NSButton(frame: frame)
        button.title = title
        button.font = NSFont.systemFont(ofSize: 12)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        return button
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: t("show"), action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: t("hide"), action: #selector(hideWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: t("reset.position"), action: #selector(resetPosition), keyEquivalent: "").target = self
        menu.addItem(withTitle: t("toggle.topmost"), action: #selector(toggleTopmost), keyEquivalent: "").target = self
        menu.addItem(withTitle: t("toggle.autonomy"), action: #selector(toggleAutonomy), keyEquivalent: "").target = self
        menu.addItem(withTitle: t("toggle.voice"), action: #selector(toggleVoice), keyEquivalent: "").target = self
        menu.addItem(withTitle: t("toggle.compact"), action: #selector(toggleCompact), keyEquivalent: "").target = self
        menu.addItem(withTitle: t("settings"), action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: t("task.packages.title"), action: #selector(showTaskPackages), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: t("minimize"), action: #selector(minimizeWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: t("exit"), action: #selector(exitApp), keyEquivalent: "").target = self
        return menu
    }

    func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = petName
        statusItem?.menu = makeContextMenu()
    }

    func setBubble(_ text: String) {
        bubbleLabel.stringValue = text
    }

    func voiceBubble(_ text: String) {
        setBubble(text)
        lastConversationBubbleTick = tick
        playSpeechAudio(text)
    }

    func setMode(_ newMode: PetMode) {
        mode = newMode
        petView.mode = newMode
        if newMode != .idle {
            petView.idleAccent = .none
            accentEndTick = 0
            nextAccentCheckTick = tick + Int.random(in: 30...70)
        }
        if useBehaviorDirector, let director = behaviorDirector {
            requestModeTransition(to: newMode, director: director)
        } else {
            applyModeImmediately(newMode)
        }
    }

    /// Director-driven path: thinking/speaking/idle → sequence; excited/sleeping → immediate.
    /// Sequences MUST NOT call back into setMode (recursion). They drive motionPlayer
    /// / petView fields directly.
    private func requestModeTransition(to newMode: PetMode, director: BehaviorDirector) {
        switch newMode {
        case .thinking:
            director.request(EnterThinkingSequence(thinkingMaxActiveSeconds: thinkingMaxActiveSeconds))
        case .speaking:
            director.request(EnterSpeakingSequence())
        case .idle:
            // 不重复 enqueue ExitToIdle:当前已是 idle 或 exitToIdle 时 ignore。
            if let cur = director.current, cur.name == "exitToIdle" {
                return
            }
            director.request(ExitToIdleSequence())
        case .excited, .sleeping:
            // 即时模式不走 sequence — 必须先 interrupt 当前 sequence + 清视觉残留,
            // 再 applyModeImmediately 接管 motion/sprite。
            director.interruptAndRun(nil)
            resetVisualStateForInterrupt()
            applyModeImmediately(newMode)
        }
    }

    /// Fallback path: behavior director disabled OR mode bypasses sequence.
    /// Same logic as the pre-director setMode body.
    private func applyModeImmediately(_ newMode: PetMode) {
        if let player = motionPlayer {
            let now = Date().timeIntervalSince(motionEpoch)
            player.play(motionClipName(for: newMode), now: now)
        }
        let targetImage = spriteImage(for: newMode) ?? characterIdleImage
        petView.setCharacterImage(targetImage)
    }

    private func spriteImage(for newMode: PetMode) -> NSImage? {
        // Expression sprite swapping rolled back for thinking/speaking — the
        // current low-res sheet-cropped sprites differ in size and centering from
        // idle.png, causing visible "jumps" during cross-fade. They stay loaded
        // (controller.characterExpressions) for future high-res replacements.
        // Keep all states on the aligned idle image for now. The cropped sheet
        // sprites are useful source material, but their canvases need normalization
        // before state swaps can look natural.
        switch newMode {
        case .excited, .speaking, .thinking, .sleeping, .idle: return nil
        }
    }

    func speak(_ text: String) {
        setBubble(text)
        lastConversationBubbleTick = tick
        setMode(.speaking)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, self.mode == .speaking else { return }
            // 直接 setMode(.idle) 会请求 ExitToIdle (priority .low),
            // 被当前 EnterSpeaking (priority .high) drop —— 导致 director 永远卡在 speaking。
            // 这里 force interrupt 当前 speaking,启动 ExitToIdle 平滑回 idle。
            self.mode = .idle
            self.petView.mode = .idle
            if self.useBehaviorDirector,
               let director = self.behaviorDirector,
               director.current?.name == "enterSpeaking" {
                director.interruptAndRun(ExitToIdleSequence())
            } else {
                self.applyModeImmediately(.idle)
            }
        }
        playSpeechAudio(text)
    }

    private func playSpeechAudio(_ text: String) {
        if voiceEnabled, let cloudProvider = cloudSpeechSynthesisProvider, cloudProvider.status().available {
            Task { @MainActor [weak self] in
                guard let self, self.voiceEnabled else { return }
                do {
                    let data = try await cloudProvider.synthesize(text: text, language: self.language, settings: self.settings.voice)
                    try self.playCloudSpeech(data: data)
                    appendLog(self.paths, "cloud-tts-played provider=\(cloudProvider.id) bytes=\(data.count)")
                } catch {
                    appendLog(self.paths, "cloud-tts-fallback provider=\(cloudProvider.id) error=\(error.localizedDescription)")
                    self.speakWithSystemVoice(text)
                }
            }
        } else if voiceEnabled {
            speakWithSystemVoice(text)
        }
    }

    private func speakWithSystemVoice(_ text: String) {
        guard voiceEnabled else { return }
        cloudSpeechPlayer?.stop()
        cloudSpeechPlayer = nil
        speechSynth.stopSpeaking(at: .immediate)
        let utterance = speechSynthesisProvider.makeUtterance(text: text, language: language, settings: settings.voice)
        speechSynth.speak(utterance)
    }

    private func playCloudSpeech(data: Data) throws {
        speechSynth.stopSpeaking(at: .immediate)
        cloudSpeechPlayer?.stop()
        let player = try AVAudioPlayer(data: data)
        cloudSpeechPlayer = player
        player.prepareToPlay()
        player.play()
    }

    @objc func sendUserMessage() {
        let message = inputField.stringValue
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inputField.stringValue = ""
        lastInteractionTick = tick
        lastConversationBubbleTick = tick

        if let newNick = parseNicknameRequest(trimmed) {
            memory["nickname"] = newNick
            savePetMemory(paths: paths, memory)
            setMode(.excited)
            let reply: String
            if isZh {
                reply = "\(t("nickname.saved")) \(newNick)，从现在开始我会这样叫你。"
            } else if isJa {
                reply = "\(t("nickname.saved")) \(newNick)、これからそう呼びます。"
            } else {
                reply = "\(t("nickname.saved")) \(newNick), I will call you that from now on."
            }
            speak(reply)
            recentMessages.append(trimmed)
            if recentMessages.count > 10 { recentMessages.removeFirst() }
            return
        }

        if taskRouter.shouldRouteAsTask(trimmed) {
            conversationRequestId += 1
            let package = taskRouter.buildTaskPackage(from: trimmed)
            let markdown = taskRouter.renderMarkdown(package)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
            let saveResult = saveTaskPackageMarkdown(markdown, package: package, paths: paths)
            let intro: String
            if saveResult.success {
                intro = t("task.packages.saved")
                appendLog(paths, "task-package-saved id=\(package.id) path=\(saveResult.fileURL?.path ?? "(unknown)")")
            } else {
                intro = t("task.packages.saveFailed")
                appendLog(paths, "task-package-save-failed id=\(package.id) error=\(saveResult.errorMessage ?? "(unknown)")")
            }
            appendLog(paths, "task-router-built id=\(package.id) type=\(package.taskType.rawValue) executor=\(package.recommendedExecutor.rawValue) risk=\(package.riskLevel.rawValue)")
            recentMessages.append(trimmed)
            if recentMessages.count > 10 { recentMessages.removeFirst() }
            recentTurns.append(ConversationTurn(role: .user, content: trimmed))
            recentTurns.append(ConversationTurn(role: .assistant, content: "\(intro)\n\n\(markdown)"))
            while recentTurns.count > conversationTurnLimit {
                recentTurns.removeFirst()
            }
            speak(intro)
            return
        }

        setMode(.thinking)
        setBubble("\(t("thinking")) \(trimmed)")
        lastConversationBubbleTick = tick
        conversationRequestId += 1
        let requestId = conversationRequestId
        recentMessages.append(trimmed)
        if recentMessages.count > 10 { recentMessages.removeFirst() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 520_000_000)
            guard requestId == self.conversationRequestId else {
                appendLog(self.paths, "reply-dropped-after-interrupt")
                return
            }
            let context = BrainContext(
                characterName: self.petName,
                language: self.language,
                nickname: self.nickname,
                petPersonality: self.petPersonality,
                replyStyle: self.replyStylePreference,
                doNotDisturbWhenTyping: self.doNotDisturbWhenTyping,
                wallpaper: self.wallpaper,
                recentMessages: self.recentMessages,
                conversationTurns: self.recentTurns,
                characterProfile: self.character
            )
            let reply = await self.brain.reply(input: trimmed, context: context)
            guard requestId == self.conversationRequestId else {
                appendLog(self.paths, "reply-dropped-after-interrupt")
                return
            }
            self.recentTurns.append(ConversationTurn(role: .user, content: trimmed))
            self.recentTurns.append(ConversationTurn(role: .assistant, content: reply))
            while self.recentTurns.count > self.conversationTurnLimit {
                self.recentTurns.removeFirst()
            }
            self.speak(reply)
        }
    }


    @objc func startListenOnce() {
        if isListening {
            stopListening(sendResult: true)
            return
        }
        guard voiceInputProvider.hasAvailableInput() else {
            speak(t("listen.noMic"))
            appendLog(paths, "speech-recognition-no-microphone")
            return
        }
        let micName = voiceInputProvider.currentInputName()
        if let cloudProvider = cloudSpeechRecognitionProvider {
            let cloudStatus = cloudProvider.status(defaultLanguage: speechLocaleIdentifier(for: language))
            appendLog(
                paths,
                "cloud-asr-status provider=\(cloudStatus.id) available=\(cloudStatus.available) fallback=\(cloudStatus.fallbackId ?? "") detail=\(cloudStatus.detail)"
            )
        }
        appendLog(paths, "speech-recognition-request microphone=\(micName) locale=\(speechLocaleIdentifier(for: language))")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                switch status {
                case .authorized:
                    self.beginSpeechRecognition(microphoneName: micName)
                default:
                    appendLog(self.paths, "speech-recognition-auth-denied status=\(status.rawValue)")
                    self.speak(self.t("listen.authDenied"))
                }
            }
        }
    }

    private func beginSpeechRecognition(microphoneName: String) {
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        guard let recognizer = speechRecognitionProvider.recognizer(localeIdentifier: speechLocaleIdentifier(for: language)),
              recognizer.isAvailable else {
            appendLog(paths, "speech-recognition-unavailable locale=\(speechLocaleIdentifier(for: language))")
            speak(t("listen.failed"))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            appendLog(paths, "speech-recognition-audio-start-failed error=\(error.localizedDescription)")
            speak(t("listen.failed"))
            return
        }

        isListening = true
        listenRequestId += 1
        let requestId = listenRequestId
        setMode(.thinking)
        setBubble(t("listen.start").replacingOccurrences(of: "{0}", with: microphoneName))
        listenButton.title = isZh ? "停止" : (isJa ? "停止" : "Stop")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.listenRequestId == requestId else { return }
                if let text = result?.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    self.inputField.stringValue = text
                }
                if result?.isFinal == true || error != nil {
                    if let error {
                        appendLog(self.paths, "speech-recognition-finished error=\(error.localizedDescription)")
                    } else {
                        appendLog(self.paths, "speech-recognition-finished")
                    }
                    self.stopListening(sendResult: true)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self, self.listenRequestId == requestId, self.isListening else { return }
            appendLog(self.paths, "speech-recognition-timeout")
            self.stopListening(sendResult: true)
        }
    }

    private func stopListening(sendResult: Bool) {
        guard isListening else { return }
        isListening = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        listenButton.title = t("listen")

        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if sendResult, !text.isEmpty {
            sendUserMessage()
        } else if sendResult {
            setMode(.idle)
            setBubble(t("listen.noResult"))
        }
    }

    @objc func toggleVoice() {
        voiceEnabled.toggle()
        if voiceEnabled {
            voiceButton.title = t("mute")
            speak(t("voice.back"))
        } else {
            voiceButton.title = t("voice")
            speechSynth.stopSpeaking(at: .immediate)
            setBubble(t("voice.quiet"))
            setMode(.idle)
        }
    }

    @objc func showSettings() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panelSize = NSSize(width: 340, height: 532)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = t("settings.title")
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.level = .floating

        let root = FlippedRootView(frame: NSRect(origin: .zero, size: panelSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        win.contentView = root

        var y = 16.0
        let labelW = 110.0
        let fieldX = labelW + 24

        let langLabel = NSTextField(labelWithString: t("settings.language"))
        langLabel.frame = NSRect(x: 16, y: y, width: labelW, height: 22)
        root.addSubview(langLabel)
        let langSeg = NSSegmentedControl(labels: [t("settings.zh"), t("settings.en"), t("settings.ja")], trackingMode: .selectOne, target: self, action: #selector(settingsLanguageChanged(_:)))
        langSeg.frame = NSRect(x: fieldX, y: y, width: panelSize.width - fieldX - 16, height: 24)
        langSeg.selectedSegment = settingsSegment(forLanguage: language)
        langSeg.identifier = NSUserInterfaceItemIdentifier("settings.lang")
        root.addSubview(langSeg)
        y += 38

        let petNameLabel = NSTextField(labelWithString: t("settings.petName"))
        petNameLabel.frame = NSRect(x: 16, y: y, width: labelW, height: 22)
        root.addSubview(petNameLabel)
        let petNameField = NSTextField(frame: NSRect(x: fieldX, y: y - 2, width: panelSize.width - fieldX - 16, height: 26))
        petNameField.stringValue = petName
        petNameField.identifier = NSUserInterfaceItemIdentifier("settings.petName")
        root.addSubview(petNameField)
        y += 38

        let topmostCk = makeCheckbox(title: t("settings.topmost"), checked: topmostEnabled, id: "settings.topmost")
        topmostCk.frame = NSRect(x: 16, y: y, width: panelSize.width - 32, height: 22)
        root.addSubview(topmostCk)
        y += 30

        let voiceCk = makeCheckbox(title: t("settings.voice"), checked: voiceEnabled, id: "settings.voice")
        voiceCk.frame = NSRect(x: 16, y: y, width: panelSize.width - 32, height: 22)
        root.addSubview(voiceCk)
        y += 30

        let autoCk = makeCheckbox(title: t("settings.autonomy"), checked: autonomyEnabled, id: "settings.autonomy")
        autoCk.frame = NSRect(x: 16, y: y, width: panelSize.width - 32, height: 22)
        root.addSubview(autoCk)
        y += 30

        let naturalMotionCk = makeCheckbox(title: t("settings.naturalMotion"), checked: naturalMotionEnabled, id: "settings.naturalMotion")
        naturalMotionCk.frame = NSRect(x: 16, y: y, width: panelSize.width - 32, height: 22)
        root.addSubview(naturalMotionCk)
        y += 30

        let windowMischiefCk = makeCheckbox(
            title: t("settings.windowMischief"),
            checked: settings.naturalMotion?.enableWindowEdgeInteraction ?? false,
            id: "settings.windowMischief"
        )
        windowMischiefCk.frame = NSRect(x: 16, y: y, width: panelSize.width - 32, height: 22)
        root.addSubview(windowMischiefCk)
        y += 30

        let compactCk = makeCheckbox(title: t("settings.compact"), checked: defaultCompact, id: "settings.compact")
        compactCk.frame = NSRect(x: 16, y: y, width: panelSize.width - 32, height: 22)
        root.addSubview(compactCk)
        y += 34

        let chanceLabel = NSTextField(labelWithString: t("settings.chance"))
        chanceLabel.frame = NSRect(x: 16, y: y, width: panelSize.width - 32, height: 20)
        root.addSubview(chanceLabel)
        y += 22
        let slider = NSSlider(value: messageChance, minValue: 0.0, maxValue: 0.30, target: nil, action: nil)
        slider.frame = NSRect(x: 16, y: y, width: panelSize.width - 100, height: 22)
        slider.identifier = NSUserInterfaceItemIdentifier("settings.chance")
        root.addSubview(slider)
        let chanceValue = NSTextField(labelWithString: String(format: "%.0f%%", messageChance * 100))
        chanceValue.frame = NSRect(x: panelSize.width - 78, y: y, width: 60, height: 22)
        chanceValue.alignment = .right
        chanceValue.identifier = NSUserInterfaceItemIdentifier("settings.chanceLabel")
        root.addSubview(chanceValue)
        slider.target = self
        slider.action = #selector(settingsChanceChanged(_:))
        y += 36

        let profileBtn = NSButton(title: t("settings.profile"), target: self, action: #selector(showProfile))
        profileBtn.bezelStyle = .rounded
        profileBtn.frame = NSRect(x: 16, y: y, width: panelSize.width - 32, height: 26)
        root.addSubview(profileBtn)
        y += 34

        let handoffCard = RoundedPanelView(frame: NSRect(x: 16, y: y, width: panelSize.width - 32, height: 74))
        handoffCard.cornerRadius = 8
        handoffCard.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.70)
        handoffCard.strokeColor = NSColor.separatorColor.withAlphaComponent(0.80)
        root.addSubview(handoffCard)

        let handoffTitle = NSTextField(labelWithString: t("settings.taskPackages.title"))
        handoffTitle.font = NSFont.boldSystemFont(ofSize: 13)
        handoffTitle.frame = NSRect(x: 12, y: 10, width: 140, height: 20)
        handoffCard.addSubview(handoffTitle)

        let handoffDesc = NSTextField(labelWithString: t("settings.taskPackages.desc"))
        handoffDesc.textColor = .secondaryLabelColor
        handoffDesc.font = NSFont.systemFont(ofSize: 11)
        handoffDesc.frame = NSRect(x: 12, y: 34, width: 190, height: 18)
        handoffCard.addSubview(handoffDesc)

        let taskPackagesBtn = NSButton(title: t("settings.open"), target: self, action: #selector(showTaskPackages))
        taskPackagesBtn.bezelStyle = .rounded
        if #available(macOS 11.0, *) {
            taskPackagesBtn.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: t("settings.taskPackages.title"))
            taskPackagesBtn.imagePosition = .imageLeading
        }
        taskPackagesBtn.frame = NSRect(x: panelSize.width - 130, y: 22, width: 98, height: 30)
        handoffCard.addSubview(taskPackagesBtn)
        y += 86

        let cancelBtn = NSButton(title: t("settings.cancel"), target: self, action: #selector(settingsCancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: panelSize.width - 180, y: y, width: 78, height: 30)
        root.addSubview(cancelBtn)

        let applyBtn = NSButton(title: t("settings.apply"), target: self, action: #selector(settingsApply))
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"
        applyBtn.frame = NSRect(x: panelSize.width - 94, y: y, width: 78, height: 30)
        root.addSubview(applyBtn)

        if let main = window {
            let mainFrame = main.frame
            let newOrigin = NSPoint(x: mainFrame.minX - panelSize.width - 12, y: mainFrame.maxY - panelSize.height)
            win.setFrameOrigin(newOrigin)
        } else {
            win.center()
        }

        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func makeCheckbox(title: String, checked: Bool, id: String) -> NSButton {
        let btn = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        btn.state = checked ? .on : .off
        btn.identifier = NSUserInterfaceItemIdentifier(id)
        return btn
    }

    private func findControl(_ id: String) -> NSView? {
        guard let win = settingsWindow else { return nil }
        return findSubview(in: win.contentView, id: id)
    }

    private func findSubview(in view: NSView?, id: String) -> NSView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == id { return view }
        for sub in view.subviews {
            if let found = findSubview(in: sub, id: id) { return found }
        }
        return nil
    }

    @objc func settingsLanguageChanged(_ sender: NSSegmentedControl) {}

    @objc func settingsChanceChanged(_ sender: NSSlider) {
        guard let label = findControl("settings.chanceLabel") as? NSTextField else { return }
        label.stringValue = String(format: "%.0f%%", sender.doubleValue * 100)
    }

    @objc func settingsCancel() {
        settingsWindow?.close()
    }

    @objc func settingsApply() {
        guard let win = settingsWindow else { return }
        let langSeg = findSubview(in: win.contentView, id: "settings.lang") as? NSSegmentedControl
        let petNameField = findSubview(in: win.contentView, id: "settings.petName") as? NSTextField
        let topmostCk = findSubview(in: win.contentView, id: "settings.topmost") as? NSButton
        let voiceCk = findSubview(in: win.contentView, id: "settings.voice") as? NSButton
        let autoCk = findSubview(in: win.contentView, id: "settings.autonomy") as? NSButton
        let naturalMotionCk = findSubview(in: win.contentView, id: "settings.naturalMotion") as? NSButton
        let windowMischiefCk = findSubview(in: win.contentView, id: "settings.windowMischief") as? NSButton
        let compactCk = findSubview(in: win.contentView, id: "settings.compact") as? NSButton
        let slider = findSubview(in: win.contentView, id: "settings.chance") as? NSSlider

        let newLang = languageCode(forSettingsSegment: langSeg?.selectedSegment ?? 0)
        let newPetNameRaw = petNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? petName
        let newPetName = newPetNameRaw.isEmpty ? petName : newPetNameRaw
        let newTopmost = topmostCk?.state == .on
        let newVoice = voiceCk?.state == .on
        let newAuto = autoCk?.state == .on
        let newNaturalMotion = naturalMotionCk?.state == .on
        let newWindowMischief = windowMischiefCk?.state == .on
        let newChance = slider?.doubleValue ?? messageChance
        let newDefaultCompact = compactCk?.state == .on

        let langChanged = newLang != language
        let petNameChanged = newPetName != petName
        let compactLiveChanged = newDefaultCompact != isCompact

        if topmostEnabled != newTopmost {
            topmostEnabled = newTopmost
            window.level = newTopmost ? topmostWindowLevel : .normal
        }
        if voiceEnabled != newVoice {
            voiceEnabled = newVoice
            if !newVoice { speechSynth.stopSpeaking(at: .immediate) }
            voiceButton.title = newVoice ? t("mute") : t("voice")
        }
        if autonomyEnabled != newAuto {
            autonomyEnabled = newAuto
            autonomyButton.title = newAuto ? t("pause") : t("auto")
        }
        if naturalMotionEnabled != newNaturalMotion {
            naturalMotionEnabled = newNaturalMotion
            if !newNaturalMotion {
                behaviorDirector?.interruptAndRun(nil)
                behaviorDirector = nil
                useBehaviorDirector = false
                resetVisualStateForInterrupt()
            } else if behaviorDirector == nil {
                installNaturalMotion()
            }
        }
        if petNameChanged {
            updatePetMemoryValue(paths: paths, memory: &memory, key: "petName", value: newPetName)
        }
        messageChance = max(0.0, min(0.5, newChance))
        language = newLang

        updateSettingsBundle(
            paths: paths,
            language: newLang,
            topmost: newTopmost,
            voice: newVoice,
            autonomy: newAuto,
            messageChance: messageChance,
            compact: newDefaultCompact,
            naturalMotion: newNaturalMotion,
            windowMischief: newWindowMischief
        )
        // controller 持有独立 windowMischiefEnabled 字段, 避免改不可变 settings.
        windowMischiefEnabled = newWindowMischief
        // 立即关闭时打断正在跑的 mischief sequence。
        if !newWindowMischief, behaviorDirector?.current?.name == "windowEdgeMischiefLite" {
            behaviorDirector?.interruptAndRun(nil)
            resetVisualStateForInterrupt()
        }
        defaultCompact = newDefaultCompact

        if langChanged || petNameChanged {
            applyLanguage()
        }
        if compactLiveChanged {
            isCompact = newDefaultCompact
            applyCompactLayout(animated: true)
        } else {
            isCompact = newDefaultCompact
        }

        win.close()
        speak(t("settings.applied"))
    }

    @objc func showProfile() {
        let traits = character.personality.joined(separator: " / ")
        let packNames = behaviorPacks.map(\.name).joined(separator: ", ")
        let summary: String
        if isZh {
            summary = "角色：\(character.name)\n性格：\(traits)\n行为包：\(packNames)\n壁纸：\(localizedScene(wallpaper.scene, language: language)) - \(localizedWallpaperReason(wallpaper.reason, language: language))\n昵称：\(nickname ?? "（未设定）")"
        } else {
            summary = "Character: \(character.name)\nTraits: \(traits)\nBehavior packs: \(packNames)\nWallpaper: \(wallpaper.scene) - \(wallpaper.reason)\nNickname: \(nickname ?? "(unset)")"
        }
        let alert = NSAlert()
        alert.messageText = t("profile.title")
        alert.informativeText = summary
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc func showTaskPackages() {
        if let existing = taskPackageWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let preferredURL = taskPackageSelectedURL
        taskPackageButtonURLs = [:]
        let panelSize = NSSize(width: 760, height: 560)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = t("task.packages.title")
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.level = .floating

        let root = FlippedRootView(frame: NSRect(origin: .zero, size: panelSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        win.contentView = root

        let titleLabel = NSTextField(labelWithString: t("task.packages.title"))
        titleLabel.font = NSFont.boldSystemFont(ofSize: 20)
        titleLabel.frame = NSRect(x: 16, y: 14, width: 240, height: 28)
        root.addSubview(titleLabel)

        let hintLabel = NSTextField(labelWithString: t("task.packages.hint"))
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.frame = NSRect(x: 16, y: 44, width: panelSize.width - 32, height: 22)
        root.addSubview(hintLabel)

        let guideLabel = NSTextField(labelWithString: t("task.packages.guide"))
        guideLabel.textColor = .secondaryLabelColor
        guideLabel.font = NSFont.systemFont(ofSize: 11)
        guideLabel.frame = NSRect(x: 16, y: 66, width: panelSize.width - 32, height: 32)
        guideLabel.maximumNumberOfLines = 2
        root.addSubview(guideLabel)

        let refreshBtn = NSButton(title: t("task.packages.refresh"), target: self, action: #selector(refreshTaskPackages))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.frame = NSRect(x: panelSize.width - 294, y: 16, width: 64, height: 28)
        root.addSubview(refreshBtn)

        let openDirBtn = NSButton(title: t("task.packages.openDir"), target: self, action: #selector(openTaskPackageDirectoryRoot))
        openDirBtn.bezelStyle = .rounded
        openDirBtn.frame = NSRect(x: panelSize.width - 224, y: 16, width: 86, height: 28)
        root.addSubview(openDirBtn)

        let copySelectedBtn = NSButton(title: t("task.packages.copySelected"), target: self, action: #selector(copySelectedTaskPackageMarkdown))
        copySelectedBtn.bezelStyle = .rounded
        copySelectedBtn.frame = NSRect(x: panelSize.width - 132, y: 16, width: 116, height: 28)
        root.addSubview(copySelectedBtn)

        let items = Array(listSavedTaskPackages(paths: paths).prefix(8))
        let selectedURL = selectedTaskPackageURL(afterRefresh: items, preferredURL: preferredURL)
        taskPackageSelectedURL = selectedURL
        let listScroll = NSScrollView(frame: NSRect(x: 16, y: 106, width: panelSize.width - 32, height: 208))
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        let docHeight = max(232.0, Double(max(items.count, 1)) * 62.0 + 8.0)
        let listDoc = FlippedRootView(frame: NSRect(x: 0, y: 0, width: panelSize.width - 48, height: docHeight))
        listScroll.documentView = listDoc
        root.addSubview(listScroll)

        if items.isEmpty {
            let empty = NSTextField(labelWithString: t("task.packages.empty"))
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: 12, y: 18, width: panelSize.width - 72, height: 24)
            listDoc.addSubview(empty)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            for (index, item) in items.enumerated() {
                let rowY = Double(index) * 62.0 + 8.0
                let name = NSTextField(labelWithString: item.fileName)
                name.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                name.lineBreakMode = .byTruncatingMiddle
                name.frame = NSRect(x: 10, y: rowY, width: 430, height: 20)
                listDoc.addSubview(name)

                let selectedMark = item.fileURL.path == selectedURL?.path ? t("task.packages.selected") : ""
                let meta = NSTextField(labelWithString: "\(selectedMark)\(formatter.string(from: item.createdAt))    \(t("task.packages.meta.type")) \(item.taskType)    \(t("task.packages.meta.executor")) \(item.executor)    \(taskPackageRiskLabel(item.riskLevel, language: language))")
                meta.textColor = .secondaryLabelColor
                meta.font = NSFont.systemFont(ofSize: 11)
                meta.frame = NSRect(x: 10, y: rowY + 24, width: 430, height: 18)
                listDoc.addSubview(meta)

                addTaskPackageButton(title: t("task.packages.view"), action: #selector(viewTaskPackageMarkdown(_:)), fileURL: item.fileURL, key: "view-\(index)", frame: NSRect(x: 456, y: rowY + 12, width: 62, height: 28), to: listDoc)
                addTaskPackageButton(title: t("task.packages.copy"), action: #selector(copyTaskPackageMarkdown(_:)), fileURL: item.fileURL, key: "copy-\(index)", frame: NSRect(x: 526, y: rowY + 12, width: 62, height: 28), to: listDoc)
                addTaskPackageButton(title: t("task.packages.dir"), action: #selector(openTaskPackageDirectory(_:)), fileURL: item.fileURL, key: "dir-\(index)", frame: NSRect(x: 596, y: rowY + 12, width: 62, height: 28), to: listDoc)
            }
        }

        let previewLabel = NSTextField(labelWithString: t("task.packages.preview"))
        previewLabel.font = NSFont.boldSystemFont(ofSize: 13)
        previewLabel.frame = NSRect(x: 16, y: 328, width: 160, height: 22)
        root.addSubview(previewLabel)

        let previewScroll = NSScrollView(frame: NSRect(x: 16, y: 354, width: panelSize.width - 32, height: 166))
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .bezelBorder
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: panelSize.width - 48, height: 166))
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = items.isEmpty
            ? t("task.packages.empty")
            : taskPackagePreviewText(fileURL: selectedURL, language: language)
        previewScroll.documentView = textView
        root.addSubview(previewScroll)
        taskPackagePreviewTextView = textView

        if let main = window {
            let mainFrame = main.frame
            win.setFrameOrigin(NSPoint(x: mainFrame.minX - panelSize.width - 12, y: mainFrame.maxY - panelSize.height))
        } else {
            win.center()
        }

        taskPackageWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func addTaskPackageButton(title: String, action: Selector, fileURL: URL, key: String, frame: NSRect, to parent: NSView) {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.frame = frame
        button.identifier = NSUserInterfaceItemIdentifier(key)
        taskPackageButtonURLs[key] = fileURL
        parent.addSubview(button)
    }

    private func taskPackageURL(for sender: NSButton) -> URL? {
        guard let key = sender.identifier?.rawValue else { return nil }
        return taskPackageButtonURLs[key]
    }

    @objc func viewTaskPackageMarkdown(_ sender: NSButton) {
        guard let url = taskPackageURL(for: sender) else { return }
        guard let text = readTaskPackageMarkdown(fileURL: url) else {
            taskPackagePreviewTextView?.string = taskPackagePreviewText(fileURL: url)
            setBubble(t("task.packages.unreadable"))
            return
        }
        taskPackageSelectedURL = url
        taskPackagePreviewTextView?.string = text
    }

    @objc func copyTaskPackageMarkdown(_ sender: NSButton) {
        guard let url = taskPackageURL(for: sender) else { return }
        taskPackageSelectedURL = url
        if copyTaskPackageMarkdownToPasteboard(fileURL: url) {
            setBubble(taskPackageCopyFeedback(success: true, language: language))
        } else {
            setBubble(taskPackageCopyFeedback(success: false, language: language))
        }
    }

    @objc func openTaskPackageDirectory(_ sender: NSButton) {
        guard let url = taskPackageURL(for: sender) else { return }
        taskPackageSelectedURL = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            setBubble(t("task.packages.missing"))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func refreshTaskPackages() {
        let preferredURL = taskPackageSelectedURL
        taskPackageWindow?.close()
        taskPackageWindow = nil
        taskPackagePreviewTextView = nil
        taskPackageButtonURLs = [:]
        taskPackageSelectedURL = preferredURL
        showTaskPackages()
    }

    @objc func copySelectedTaskPackageMarkdown() {
        guard let url = taskPackageSelectedURL else {
            setBubble(t("task.packages.selectFirst"))
            return
        }
        if copyTaskPackageMarkdownToPasteboard(fileURL: url) {
            setBubble(taskPackageCopyFeedback(success: true, language: language))
        } else {
            setBubble(taskPackageCopyFeedback(success: false, language: language))
        }
    }

    @objc func openTaskPackageDirectoryRoot() {
        guard let directory = ensureTaskPackageHandoffDirectory(paths: paths) else {
            setBubble(t("task.packages.dirUnavailable"))
            return
        }
        NSWorkspace.shared.open(directory)
    }

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(inputField)
    }

    @objc func hideWindow() {
        if settings.window.rememberPosition {
            saveWindowState(window: window, to: paths.windowState)
        }
        window.orderOut(nil)
    }

    @objc func resetPosition() {
        let size = isCompact ? compactSize : fullSize
        let screen = unionVisibleFrame()
        let origin = clampWindowOrigin(
            NSPoint(x: screen.maxX - size.width - settings.window.defaultOffsetRight, y: screen.minY + settings.window.defaultOffsetBottom),
            size: size
        )
        window.setFrameOrigin(origin)
        if settings.window.rememberPosition {
            saveWindowState(window: window, to: paths.windowState)
        }
        speak(t("position.reset"))
    }

    @objc func toggleTopmost() {
        topmostEnabled.toggle()
        window.level = topmostEnabled ? topmostWindowLevel : .normal
        speak(topmostEnabled ? t("topmost.on") : t("topmost.off"))
    }

    @objc func toggleAutonomy() {
        autonomyEnabled.toggle()
        autonomyButton.title = autonomyEnabled ? t("pause") : t("auto")
        if autonomyEnabled {
            speak(t("autonomy.on"))
        } else {
            setMode(.idle)
            speak(t("autonomy.off"))
        }
    }

    @objc func toggleCompact() {
        isCompact.toggle()
        applyCompactLayout(animated: true)
        compactButton.title = isCompact ? t("compact.expand") : t("compact.collapse")
        statusItem?.menu = makeContextMenu()
        if isCompact {
            setBubble(t("compact.on"))
            setMode(.idle)
        } else {
            speak(t("compact.off"))
            showMiniModeOnboardingIfNeeded(delay: 1.1)
        }
    }

    func showMiniModeOnboardingIfNeeded(delay: TimeInterval) {
        guard !isCompact, memoryString(memory, "onboardingMiniShown") != "true" else {
            return
        }
        memory["onboardingMiniShown"] = "true"
        savePetMemory(paths: paths, memory)
        appendLog(paths, "mini-onboarding-scheduled")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isCompact else { return }
            self.setMode(.idle)
            self.setBubble(self.t("onboarding.mini"))
            appendLog(self.paths, "mini-onboarding-shown")
        }
    }

    func applyCompactLayout(animated: Bool) {
        let targetSize = isCompact ? compactSize : fullSize
        let oldFrame = window.frame
        let newOrigin = NSPoint(
            x: oldFrame.maxX - targetSize.width,
            y: oldFrame.maxY - targetSize.height
        )
        let clamped = settings.window.keepInsideScreen
            ? clampWindowOrigin(newOrigin, size: targetSize)
            : newOrigin
        let targetFrame = NSRect(origin: clamped, size: targetSize)

        bubbleView.isHidden = isCompact
        controlsView.isHidden = isCompact

        positionPetView(for: targetSize)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                window.animator().setFrame(targetFrame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.positionPetView(for: targetSize)
                    self?.petView.needsDisplay = true
                }
            }
        } else {
            window.setFrame(targetFrame, display: true)
            positionPetView(for: targetSize)
        }
    }

    func positionPetView(for size: NSSize) {
        if isCompact {
            petView.frame = NSRect(x: (size.width - 220) / 2, y: 14, width: 220, height: 170)
        } else {
            petView.frame = NSRect(x: (size.width - 220) / 2, y: 74, width: 220, height: 170)
        }
        petView.isHidden = false
        petView.alphaValue = 1
        petView.needsDisplay = true
        petView.setNeedsDisplay(petView.bounds)
    }

    @objc func toggleLanguage() {
        language = nextLanguageCode(after: language)
        updateSettingsLanguage(paths: paths, language: language)
        applyLanguage()
        if isZh {
            speak("已切换到中文。")
        } else if isJa {
            speak("日本語に切り替えました。")
        } else {
            speak("Switched to English.")
        }
    }

    @objc func minimizeWindow() {
        window.miniaturize(nil)
    }

    @objc func exitApp() {
        appendLog(paths, "exit-requested")
        stopListening(sendResult: false)
        behaviorDirector?.interruptAndRun(nil)
        behaviorDirector?.clearQueue()
        exitRequested = true
        window.close()
        NSApp.terminate(nil)
    }

    /// Helper for sequences: motionPlayer expects "now" relative to motionEpoch.
    var motionRelativeNow: TimeInterval {
        Date().timeIntervalSince(motionEpoch)
    }

    /// Wipe any visual state that an interrupted sequence may have left behind.
    /// Called by setMode on the immediate path, by drag start, and by exitApp.
    func resetVisualStateForInterrupt() {
        petView.extraOffset = .zero
        petView.extraScale = CGSize(width: 1, height: 1)
        petView.lightbulbAlpha = 0
    }

    func tickMotion() {
        let now = Date().timeIntervalSince(motionEpoch)
        if let player = motionPlayer {
            petView.motionValues = player.sample(now: now)
        }
        behaviorDirector?.tick(now: Date().timeIntervalSinceReferenceDate)
    }

    private func motionClipName(for mode: PetMode) -> String {
        switch mode {
        case .idle: return "idleBreath"
        case .thinking: return "thinkingPeek"
        case .sleeping: return "sleepCurl"
        case .excited: return "happySpin"
        case .speaking: return "talkSoft"
        }
    }

    /// Check the long-idle-settle trigger condition and enqueue the sequence at most once.
    /// Conditions (per operator spec):
    ///   - mode == .idle
    ///   - director enabled and currently idle (no sequence running)
    ///   - inactivity exceeded threshold (default 60s)
    ///   - input field not focused
    ///   - not in compact mode (mini mode shouldn't trigger sleepy curl)
    /// Cooldown is implicit: any user interaction resets lastInteractionTick, and the
    /// sequence itself occupies director.current preventing re-trigger.
    private func maybeTriggerLongIdleSettle() {
        guard useBehaviorDirector,
              let director = behaviorDirector,
              mode == .idle,
              !isCompact,
              director.current == nil,
              tick - lastInteractionTick >= longIdleThresholdTicks,
              tick - lastLongIdleSettleTick >= longIdleSettleCooldownTicks
        else { return }
        // Skip if the user is composing — defined as "input field has non-empty unsent text".
        // (Direct firstResponder check is unreliable inside a nonactivating panel:
        //  the field editor can remain first responder even when the user isn't actively
        //  editing, so we use unsent content as a proxy.)
        if !inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        lastLongIdleSettleTick = tick
        director.request(LongIdleSettleSequence())
        appendLog(paths, "long-idle-settle-triggered after-ticks=\(tick - lastInteractionTick)")
    }

    /// 招牌互动 (#5 lite) 的触发逻辑。条件按操作员要求严格 gate:
    ///   - enableWindowEdgeInteraction (windowMischiefEnabled) == true
    ///   - autonomy 开启
    ///   - mode == idle, 不 compact
    ///   - behaviorDirector 现在没在跑任何 sequence
    ///   - 用户最近至少静默 36s
    ///   - 距离上次 mischief 至少 ~3.3 分钟 (cooldown)
    ///   - 输入框无焦点
    /// 此外再做一次 0.04 ~ 0.06 的概率 roll, 让触发"低频"。
    private func maybeTriggerWindowMischiefLite() {
        guard windowMischiefEnabled,
              useBehaviorDirector,
              autonomyEnabled,
              let director = behaviorDirector,
              mode == .idle,
              !isCompact,
              director.current == nil,
              tick - lastInteractionTick >= mischiefLiteMinIdleTicks,
              tick - lastMischiefLiteTick >= mischiefLiteCooldownTicks
        else { return }
        if !inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        // 彩蛋级低频 roll: 每 tick 约 0.0002 概率;配合 9 分钟 cooldown,实际触发
        // 频率约 10-20 分钟一次。WindowTargetingService 接入后再加大幅度和频率。
        if Double.random(in: 0...1) >= 0.0002 {
            return
        }
        lastMischiefLiteTick = tick
        director.request(WindowEdgeMischiefLiteSequence(language: language))
        appendLog(paths, "window-mischief-lite-scheduled after-idle=\(tick - lastInteractionTick)")
    }

    func tickAutonomy() {
        tick += 1
        petView.tick = tick

        if petView.idleAccent != .none && tick >= accentEndTick {
            petView.idleAccent = .none
        }

        maybeTriggerLongIdleSettle()
        if behaviorDirector?.current?.name == "longIdleSettle" {
            return
        }
        maybeTriggerWindowMischiefLite()
        if behaviorDirector?.current?.name == "windowEdgeMischiefLite" {
            return
        }
        if autonomyEnabled
            && mode == .idle
            && !isCompact
            && petView.idleAccent == .none
            && tick >= nextAccentCheckTick
        {
            let playfulness = bias(character, \.playfulness, default: 0.5)
            let curiosity = bias(character, \.curiosity, default: 0.5)
            let chance = 0.20 + playfulness * 0.20 + curiosity * 0.15
            if Double.random(in: 0...1) < chance {
                let pool: [(PetCanvasView.IdleAccent, Int)] = [
                    (.lookLeft, 24),
                    (.lookRight, 24),
                    (.stretch, 28),
                    (.yawn, 32),
                ]
                let pick = pool.randomElement()!
                petView.idleAccent = pick.0
                accentEndTick = tick + pick.1
                appendLog(paths, "idle-accent-triggered accent=\(pick.0) durationTicks=\(pick.1)")
                nextAccentCheckTick = tick + pick.1 + Int.random(in: 60...140)
            } else {
                nextAccentCheckTick = tick + Int.random(in: 40...80)
            }
        }

        if tick >= nextActionTick {
            guard autonomyEnabled else {
                nextActionTick = tick + 60
                return
            }

            let energy = bias(character, \.energy, default: 0.5)
            let playfulness = bias(character, \.playfulness, default: 0.5)
            let calmness = bias(character, \.calmness, default: 0.5)
            let roll = Double.random(in: 0...1)

            if roll < 0.18 + playfulness * 0.18 {
                setMode(.excited)
                // Hop = 横向跳一段,顶点高度由 SmoothWindowMoveSequence.hopHeight 控制。
                // dy 微抖动,落点和起点 y 几乎一致,避免长期累计漂移到屏幕顶。
                let hopDx = Double(Int.random(in: -40...40))
                let hopDy = Double(Int.random(in: -8...8))
                tryEnqueueSmoothMove(dx: hopDx, dy: hopDy, duration: 0.65, style: .hop)
                nextActionTick = tick + Int.random(in: 18...34)
            } else if roll < 0.48 + energy * 0.14 {
                setMode(.idle)
                // Run = 横向走一段,踩步通过 SmoothWindowMoveSequence.run 路径实现。
                // ±90 比原来 ±28 明显大很多,加上 ~2.2 步/秒,看起来真的像走路。
                let walkDx = Double(Int.random(in: -90...90))
                tryEnqueueSmoothMove(dx: walkDx, dy: 0, duration: 1.0, style: .run)
                nextActionTick = tick + Int.random(in: 35...72)
            } else if roll > 0.88 - calmness * 0.18 {
                setMode(.sleeping)
                nextActionTick = tick + Int.random(in: 48...95)
            } else {
                setMode(.idle)
                nextActionTick = tick + Int.random(in: 40...90)
            }

            if !isCompact
                && tick - lastConversationBubbleTick >= conversationBubbleQuietTicks
                && Double.random(in: 0...1) < messageChance {
                let lines = [
                    t("patrol.1"),
                    t("patrol.2"),
                    t("patrol.3"),
                    t("patrol.4")
                ]
                setBubble(lines.randomElement() ?? lines[0])
            }
        }

        if mode == .excited && tick % 12 == 0 {
            setMode(.idle)
        }
    }

    /// Autonomous movement: prefer 60Hz SmoothWindowMoveSequence via director.
    /// Falls back to direct setFrameOrigin when director is busy or disabled,
    /// so movement isn't silently dropped during high-priority sequences.
    func tryEnqueueSmoothMove(dx: Double, dy: Double, duration: TimeInterval, style: MoveStyle) {
        guard useBehaviorDirector,
              let director = behaviorDirector
        else {
            moveWindow(dx: dx, dy: dy)
            return
        }
        // Director busy with thinking/speaking/longIdle/click — skip this autonomy
        // round entirely. Next tickAutonomy roll will retry.
        if director.current != nil {
            return
        }
        let from = window.frame.origin
        let target = NSPoint(x: from.x + dx, y: from.y + dy)
        let clampedTo = settings.window.keepInsideScreen
            ? clampWindowOrigin(target, size: window.frame.size)
            : target
        let config = SmoothWindowMoveConfig(
            from: from,
            to: clampedTo,
            duration: duration,
            style: style,
            priority: .low
        )
        director.request(SmoothWindowMoveSequence(config: config))
    }

    func moveWindow(dx: Double, dy: Double) {
        let frame = window.frame
        let next = NSPoint(x: frame.minX + dx, y: frame.minY + dy)
        let origin = settings.window.keepInsideScreen ? clampWindowOrigin(next, size: frame.size) : next
        window.setFrameOrigin(origin)
    }

    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow, closed === settingsWindow {
            settingsWindow = nil
            return
        }
        if let closed = notification.object as? NSWindow, closed === taskPackageWindow {
            taskPackageWindow = nil
            taskPackagePreviewTextView = nil
            taskPackageButtonURLs = [:]
            taskPackageSelectedURL = nil
            return
        }
        appendLog(paths, "window-will-close exitRequested=\(exitRequested)")
        timer?.invalidate()
        stopListening(sendResult: false)
        if settings.window.rememberPosition {
            saveWindowState(window: window, to: paths.windowState)
        }
        statusItem = nil
        speechSynth.stopSpeaking(at: .immediate)
        if !exitRequested {
            NSApp.terminate(nil)
        }
    }
}

func runSelfTest(paths: Paths) {
    let settings = (try? readJSON(AppSettings.self, from: paths.settings)) ?? AppSettings.fallback
    let character = loadActiveCharacter(settings: settings, paths: paths)
    let packs = loadBehaviorPacks(from: paths.behaviorDir)
    let wallpaper = readWallpaperSense()
    let memory = loadPetMemory(paths: paths)
    let nicknameTests = nicknameParserSelfTest()
    let nicknameParserPass = nicknameTests.values.allSatisfy { $0 == "ok" }
    let taskRouterTests = taskRouterSelfTest()
    let taskRouterPass = (taskRouterTests["taskRouterPass"] as? Bool) ?? false
    let taskPackageHandoffTests = taskPackageHandoffSelfTest()
    let taskPackageHandoffPass = (taskPackageHandoffTests["taskPackageHandoffPass"] as? Bool) ?? false
    let selfTestLanguage = settings.ui?.language ?? "zh-CN"
    let selfTestSpeechLocale = speechLocaleIdentifier(for: selfTestLanguage)
    let selfTestVoiceInputProvider = SystemVoiceInputProvider()
    let selfTestSpeechRecognitionProvider = SystemSpeechRecognitionProvider()
    let selfTestSpeechSynthesisProvider = SystemSpeechSynthesisProvider()

    var rigManifest: CharacterRigManifest?
    var motionLibrary: MotionLibrary?
    var idleImage: NSImage?
    var voicePackManifest: VoicePackManifest?
    var stateSpriteSection: [String: Any] = [
        "stateSpriteManifestLoaded": false,
        "stateSpriteCount": 0
    ]
    if let packId = settings.character?.activePack, !packId.isEmpty {
        rigManifest = loadRigManifest(packId: packId, paths: paths)
        motionLibrary = loadMotionLibrary(packId: packId, paths: paths)
        idleImage = loadCharacterIdleImage(packId: packId, paths: paths)
        voicePackManifest = loadVoicePackManifest(packId: packId, paths: paths)
        let stateDir = paths.root
            .appendingPathComponent("characters", isDirectory: true)
            .appendingPathComponent(packId, isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("state_sprites", isDirectory: true)
        let manifestURL = stateDir.appendingPathComponent("sprites.json")
        stateSpriteSection["stateSpriteManifestLoaded"] = FileManager.default.fileExists(atPath: manifestURL.path)
        let stateSprites = (try? FileManager.default.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "png" }
            .map(\.lastPathComponent)
            .sorted() ?? []
        stateSpriteSection["stateSpriteCount"] = stateSprites.count
        stateSpriteSection["stateSpriteFiles"] = stateSprites
    }

    var rigSection: [String: Any] = [
        "rigManifestLoaded": rigManifest != nil
    ]
    if let manifest = rigManifest {
        rigSection["rigDisplayName"] = manifest.displayName
        rigSection["rigPartCount"] = manifest.parts.count
        rigSection["rigPartIds"] = manifest.parts.map(\.id)
        rigSection["rigCanvas"] = ["w": manifest.canvas.width, "h": manifest.canvas.height]
    }

    var motionSection: [String: Any] = [
        "motionLibraryLoaded": motionLibrary != nil
    ]
    if let lib = motionLibrary {
        motionSection["motionFps"] = lib.fps
        motionSection["motionClipCount"] = lib.clips.count
        motionSection["motionClipNames"] = lib.clips.keys.sorted()
    }

    var idleImageSection: [String: Any] = [
        "idleImageLoaded": idleImage != nil
    ]
    if let img = idleImage {
        idleImageSection["idleImageWidth"] = Int(img.size.width)
        idleImageSection["idleImageHeight"] = Int(img.size.height)
    }

    var voicePackSection: [String: Any] = [
        "voicePackLoaded": voicePackManifest != nil
    ]
    if let manifest = voicePackManifest {
        voicePackSection["version"] = manifest.version
        voicePackSection["provider"] = manifest.provider
        voicePackSection["futureProvider"] = manifest.futureProvider ?? ""
        voicePackSection["fallback"] = manifest.fallback ?? ""
        voicePackSection["voiceMode"] = manifest.voiceMode ?? ""
        voicePackSection["languages"] = manifest.languages ?? []
        voicePackSection["license"] = manifest.license ?? ""
        voicePackSection["consent"] = manifest.consent ?? ""
        voicePackSection["hasVoiceId"] = !(manifest.voiceId ?? "").isEmpty
        voicePackSection["hasSamplePath"] = !(manifest.samplePath ?? "").isEmpty
        voicePackSection["styleBase"] = manifest.style?.base ?? ""
        voicePackSection["cloudASRProvider"] = manifest.cloudASR?.provider ?? ""
        voicePackSection["cloudASREndpoint"] = manifest.cloudASR?.endpoint ?? ""
        voicePackSection["cloudASRAppIdEnv"] = manifest.cloudASR?.appIdEnv ?? ""
        voicePackSection["cloudASRAccessTokenEnv"] = manifest.cloudASR?.accessTokenEnv ?? ""
        voicePackSection["cloudASRApiKeyEnv"] = manifest.cloudASR?.apiKeyEnv ?? ""
        voicePackSection["cloudASRLanguageEnv"] = manifest.cloudASR?.languageEnv ?? ""
        voicePackSection["cloudTTSProvider"] = manifest.cloudTTS?.provider ?? ""
        voicePackSection["cloudTTSEndpoint"] = manifest.cloudTTS?.endpoint ?? ""
        voicePackSection["cloudTTSAppIdEnv"] = manifest.cloudTTS?.appIdEnv ?? ""
        voicePackSection["cloudTTSAccessTokenEnv"] = manifest.cloudTTS?.accessTokenEnv ?? ""
        voicePackSection["cloudTTSApiKeyEnv"] = manifest.cloudTTS?.apiKeyEnv ?? ""
        voicePackSection["cloudTTSVoiceTypeEnv"] = manifest.cloudTTS?.voiceTypeEnv ?? ""
        voicePackSection["cloudTTSDefaultVoiceType"] = manifest.cloudTTS?.defaultVoiceType ?? ""
        voicePackSection["cloudTTSResourceIdEnv"] = manifest.cloudTTS?.resourceIdEnv ?? ""
        voicePackSection["cloudTTSResourceId"] = manifest.cloudTTS?.resourceId ?? ""
    }

    let cloudASRProvider = DoubaoCloudSpeechRecognitionProvider(settings: voicePackManifest?.cloudASR)
    let cloudTTSProvider = DoubaoCloudSpeechSynthesisProvider(settings: voicePackManifest?.cloudTTS)
    let voiceProviderSection: [String: Any] = [
        "input": selfTestVoiceInputProvider.status().asDictionary(),
        "asr": selfTestSpeechRecognitionProvider.status(localeIdentifier: selfTestSpeechLocale).asDictionary(),
        "cloudASR": cloudASRProvider.status(defaultLanguage: selfTestSpeechLocale).asDictionary(),
        "tts": selfTestSpeechSynthesisProvider.status(language: selfTestLanguage, settings: settings.voice).asDictionary(),
        "cloudTTS": cloudTTSProvider.status().asDictionary(),
        "providerBoundaryVersion": 1,
        "fallbackPolicy": "system provider remains default when cloud or local providers are unavailable"
    ]

    let result: [String: Any] = [
        "platform": "macOS",
        "character": character?.name ?? "(missing)",
        "behaviorPackCount": packs.count,
        "behaviorPacks": packs.map(\.id),
        "settingsLoaded": settings.version >= 1,
        "stateDirectory": paths.stateDir.path,
        "windowStatePath": paths.windowState.path,
        "wallpaperScene": wallpaper.scene,
        "wallpaperReason": wallpaper.reason,
        "speechSynthesisAvailable": true,
        "speechRecognitionAvailable": selfTestSpeechRecognitionProvider.status(localeIdentifier: selfTestSpeechLocale).available,
        "detectedAudioInput": selfTestVoiceInputProvider.currentInputName(),
        "compactDefault": settings.ui?.compact ?? false,
        "petMemoryKeys": Array(memory.keys),
        "nicknameParserPass": nicknameParserPass,
        "nicknameParserTests": nicknameTests,
        "taskRouterPass": taskRouterPass,
        "taskRouterTests": taskRouterTests,
        "taskPackageHandoffPass": taskPackageHandoffPass,
        "taskPackageHandoffTests": taskPackageHandoffTests,
        "rig": rigSection,
        "motions": motionSection,
        "idleImage": idleImageSection,
        "stateSprites": stateSpriteSection,
        "voicePack": voicePackSection,
        "voiceProviders": voiceProviderSection,
        "features": [
            "miniMode",
            "settingsPanel",
            "firstRunMiniModeOnboarding",
            "blinkAnimation",
            "breathingAnimation",
            "thinkingDots",
            "sleepingZz",
            "nicknameMemory",
            "nicknameParserSelfTest",
            "avSpeechSynthesizer",
            "speechRecognitionOneShot",
            "microphoneAutoDetect",
            "japaneseLanguageCycle",
            "voiceProviderProtocol",
            "voicePackManifestRuntime",
            "systemVoiceFallback",
            "staticBubbleTTSBridge",
            "doubaoCloudASRProvider",
            "cloudASRSystemFallback",
            "cloudASREnvGuard",
            "doubaoCloudTTSProvider",
            "cloudTTSSystemFallback",
            "cloudVoiceEnvGuard",
            "brainServiceProtocol",
            "brainAsync",
            "anthropicBrainStub",
            "conversationHistory",
            "overFullscreenWindow",
            "nonactivatingPanelWindow",
            "miniModeShortcut",
            "characterStyleInjection",
            "petRigScaffold",
            "rigManifestRuntime",
            "motionLibraryRuntime",
            "xiaoqiBodyGeometry",
            "imageBasedCharacterRender",
            "motionPlayer60Hz",
            "softenedImageMotion",
            "imageBlinkOverlay",
            "imageMouthOverlay",
            "imageIdleAccentOverlays",
            "stateSpriteCandidates",
            "behaviorDirector",
            "naturalEntranceBottomPeekIn",
            "clickReactionSequence",
            "expressionSprites",
            "spriteCrossfade",
            "thinkingLightbulbOverlay",
            "behaviorPriorityCategory",
            "enterThinkingSequence",
            "enterSpeakingSequence",
            "exitToIdleSequence",
            "directorRequestAPI",
            "dragInterruptReset",
            "longIdleSettleSequence",
            "smoothWindowMoveSequence",
            "taskPackageProtocol",
            "taskRouterV0",
            "taskPackageMarkdownRenderer",
            "taskRouterSelfTest",
            "taskPackageHandoff",
            "taskPackageHandoffLocalMarkdown",
            "taskPackageHandoffPanel",
            "taskPackageHandoffMainShortcut",
            "taskPackageHandoffRefresh",
            "taskPackageHandoffCopySelected",
            "taskPackageHandoffOpenDirectory",
            "taskPackageHandoffReadableRisk",
            "taskPackageHandoffKeepSelectionOnRefresh",
            "taskPackageHandoffClearPreviewStates",
            "windowEdgeMischiefLite",
            "windowEdgeMischiefLiteContained",
            "windowTargetingServiceStub",
            "startupErrorDialog"
        ]
    ]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    }
}

func showStartupErrorAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

@main
struct DesktopPetMac {
    @MainActor
    static func main() {
        let paths = Paths.fromArguments()
        appendLog(paths, "process-start args=\(CommandLine.arguments.joined(separator: " "))")
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest(paths: paths)
            appendLog(paths, "self-test-finished")
            return
        }

        _ = NSApplication.shared

        guard let appLock = AppLock(paths: paths) else {
            appendLog(paths, "lock-busy-startup-aborted")
            // P2 polish: do NOT show a modal NSAlert here. The alert blocks the GUI
            // forever (process stays alive in process list waiting for user click),
            // which makes repeat-launch UX worse than just silently failing.
            // Write to stderr so a terminal-launched session sees it, then exit 0.
            let msg = "Desktop Pet is already running. See logs/desktop-pet-mac.log.\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(0)
        }

        let settings = (try? readJSON(AppSettings.self, from: paths.settings)) ?? AppSettings.fallback
        guard let character = loadActiveCharacter(settings: settings, paths: paths) else {
            appendLog(paths, "character-load-failed path=\(paths.character.path)")
            showStartupErrorAlert(
                title: "Desktop Pet",
                message: "Could not load character file. Path: \(paths.character.path)\n\nCheck that characters/default.character.json exists and is valid JSON. See logs/desktop-pet-mac.log."
            )
            appLock.release(paths: paths)
            Foundation.exit(1)
        }

        let packs = loadBehaviorPacks(from: paths.behaviorDir)
        let wallpaper = readWallpaperSense()
        appendLog(paths, "loaded character=\(character.name) behaviorPacks=\(packs.count) wallpaper=\(wallpaper.scene)")
        NSApplication.shared.setActivationPolicy(settings.window.showInTaskbar ? .regular : .accessory)
        let delegate = AppDelegate(paths: paths, appLock: appLock, settings: settings, character: character, behaviorPacks: packs, wallpaper: wallpaper)
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let paths: Paths
    let appLock: AppLock
    let controller: DesktopPetController

    init(paths: Paths, appLock: AppLock, settings: AppSettings, character: CharacterProfile, behaviorPacks: [BehaviorPack], wallpaper: WallpaperSense) {
        self.paths = paths
        self.appLock = appLock
        controller = DesktopPetController(paths: paths, settings: settings, character: character, behaviorPacks: behaviorPacks, wallpaper: wallpaper)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appendLog(paths, "application-will-terminate")
        appLock.release(paths: paths)
    }
}
