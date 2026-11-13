//
//  CoachAI.swift
//  TypeRight
//
//  The AI behind the two cards that need it: turning a Chinese or pinyin fragment into English,
//  and checking a finished sentence. Every provider is spoken to through the OpenAI-compatible
//  chat/completions API; the user's key never leaves their Mac except to the provider they chose.
//  Without a key of their own, the trial or membership sends the same request through our backend
//  (MemberService.chat), which picks the model.
//

import Foundation
import Security

enum CoachProvider: String, CaseIterable, Identifiable {
    case deepseek, zhipu, qwen, kimi, doubao, openai, gemini, claude, openrouter, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .zhipu: "智谱 GLM"
        case .qwen: "通义千问"
        case .kimi: "Kimi"
        case .doubao: "豆包"
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        case .claude: "Claude"
        case .openrouter: "OpenRouter"
        case .custom: "自定义"
        }
    }

    var blurb: String {
        switch self {
        case .deepseek: "便宜，中文好"
        case .zhipu: "国内直连，速度快"
        case .qwen: "阿里云百炼"
        case .kimi: "月之暗面"
        case .doubao: "火山方舟"
        case .openai, .gemini, .claude: "需要海外网络"
        case .openrouter: "一个 Key 用多家模型"
        case .custom: "任何 OpenAI 兼容接口"
        }
    }

    var keyPage: URL? {
        switch self {
        case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")
        case .zhipu: URL(string: "https://open.bigmodel.cn/usercenter/apikeys")
        case .qwen: URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key")
        case .kimi: URL(string: "https://platform.moonshot.cn/console/api-keys")
        case .doubao: URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .claude: URL(string: "https://platform.claude.com/settings/keys")
        case .openrouter: URL(string: "https://openrouter.ai/settings/keys")
        case .custom: nil
        }
    }

    /// Fast text models, checked 2026-11; the user can type another model name in settings.
    var defaultModel: String {
        switch self {
        case .deepseek: "deepseek-flash"
        case .zhipu: "glm-5.3-flash"
        case .qwen: "qwen-flash"
        case .kimi: "kimi-k3"
        case .doubao: "doubao-seed-1-6-flash-250828"
        case .openai: "gpt-6-luna"
        case .gemini: "gemini-3.8-flash"
        case .claude: "claude-haiku-5-5"
        case .openrouter: "openai/gpt-6-luna"
        case .custom: ""
        }
    }

    var endpoint: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/chat/completions"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        case .kimi: return "https://api.moonshot.cn/v1/chat/completions"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .claude: return "https://api.anthropic.com/v1/chat/completions"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .custom:
            var base = CoachSettings.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") {
                base.removeLast()
            }
            return base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        }
    }
}

// MARK: - Settings

enum CoachSettings {
    /// Screenshots point this at a throwaway suite, so they never show the user's own settings.
    static var defaults: UserDefaults = .standard

    static var provider: CoachProvider {
        get { CoachProvider(rawValue: defaults.string(forKey: "typeright.provider") ?? "") ?? .deepseek }
        set { defaults.set(newValue.rawValue, forKey: "typeright.provider") }
    }

    static func model(for provider: CoachProvider) -> String {
        let custom = defaults.string(forKey: "typeright.model.\(provider.rawValue)") ?? ""
        return custom.isEmpty ? provider.defaultModel : custom
    }

    /// The model name typed in settings; empty means the provider's default.
    static func typedModel(for provider: CoachProvider) -> String {
        defaults.string(forKey: "typeright.model.\(provider.rawValue)") ?? ""
    }

    static func setModel(_ model: String, for provider: CoachProvider) {
        defaults.set(model, forKey: "typeright.model.\(provider.rawValue)")
    }

    static var customBaseURL: String {
        get { defaults.string(forKey: "typeright.customBaseURL") ?? "" }
        set { defaults.set(newValue, forKey: "typeright.customBaseURL") }
    }

    /// Language of the one-sentence explanations. Defaults to Simplified Chinese.
    static var explainLanguage: String {
        get { defaults.string(forKey: "typeright.explainLanguage") ?? "简体中文" }
        set { defaults.set(newValue, forKey: "typeright.explainLanguage") }
    }

    /// Seconds of no typing before Chinese at the end of the text, pinyin and sentences that were edited
    /// are sent to the AI (a finished sentence and Chinese followed by a space go at once).
    static var pauseSeconds: Double {
        get { defaults.object(forKey: "typeright.pauseSeconds") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "typeright.pauseSeconds") }
    }

    /// Chinese inside an English sentence turns into English by itself (a whole Chinese
    /// sentence waits for the translate shortcut).
    static var autoTranslateMixed: Bool {
        get { defaults.object(forKey: "typeright.autoTranslateMixed") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "typeright.autoTranslateMixed") }
    }

    /// Pinyin typed in English mode (`yuyue`) is offered as English too.
    static var pinyinEnabled: Bool {
        get { defaults.object(forKey: "typeright.pinyinEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "typeright.pinyinEnabled") }
    }

    /// 设置 › 通用 › 在菜单栏显示图标. TypeRight has no Dock icon, so while this is off the way
    /// back in is opening the app again (see TRMenuBarIcon).
    static var menuBarIconShown: Bool {
        get { defaults.object(forKey: "typeright.menuBarIcon") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "typeright.menuBarIcon") }
    }

    /// "us" or "uk": the IPA and the voice.
    static var accent: String {
        get { defaults.string(forKey: "typeright.accent") ?? "us" }
        set { defaults.set(newValue, forKey: "typeright.accent") }
    }

    /// The daily anonymous check-in; off until the user agrees (UsagePing.answer).
    static var anonymousReport: Bool { UsageConsent.load(from: defaults) == .yes }

    static var onboarded: Bool {
        get { defaults.bool(forKey: "typeright.onboarded") }
        set { defaults.set(newValue, forKey: "typeright.onboarded") }
    }

    static var cardsEnabled: Bool {
        get { defaults.object(forKey: "typeright.cardsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "typeright.cardsEnabled") }
    }

    /// 设置 › 快捷键 › 按 Tab: true 先跟着打 (the default: the user types the English along with the
    /// card; Tab again fills in the rest), false 直接换 (Tab writes the fix at once).
    static var tabFollows: Bool {
        get { defaults.string(forKey: "typeright.tab") != "replace" }
        set { defaults.set(newValue ? "follow" : "replace", forKey: "typeright.tab") }
    }

    /// The key held alone to list every word on the card.
    static var allWordsKey: CoachHeldKey {
        get { CoachHeldKey(rawValue: defaults.string(forKey: "typeright.allWordsKey") ?? "") ?? .option }
        set { defaults.set(newValue.rawValue, forKey: "typeright.allWordsKey") }
    }

    static var isAIReady: Bool {
        let provider = provider
        if provider == .custom, URL(string: provider.endpoint)?.host == nil { return false }
        return CoachKeyStore.shared.hasKey(provider) && !model(for: provider).isEmpty
    }
}

// MARK: - Keychain

/// What reading one keychain item gave.
enum CoachKeyRead: Equatable {
    case found(String)
    case missing
    /// The keychain could not be read (locked, access refused …): nothing is known about the item.
    case failed(OSStatus)
}

enum CoachKeychain {
    private static var service: String { Bundle.main.bundleIdentifier ?? "com.typeright.app" }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(account: String) -> CoachKeyRead {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return readResult(status: SecItemCopyMatching(query as CFDictionary, &item), data: item as? Data)
    }

    /// Keeps "there is none" apart from "it could not be read", so a failed read never empties the field.
    static func readResult(status: OSStatus, data: Data?) -> CoachKeyRead {
        switch status {
        case errSecSuccess:
            guard let data, let text = String(data: data, encoding: .utf8) else { return .failed(errSecDecode) }
            return .found(text)
        case errSecItemNotFound:
            return .missing
        default:
            return .failed(status)
        }
    }

    static func string(account: String) -> String? {
        if case let .found(text) = read(account: account) { return text }
        return nil
    }

    /// Replaces the item's value in place; an empty value deletes it. False when the keychain refused.
    @discardableResult
    static func setString(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(base(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(trimmed.utf8)
        let updated = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else {
            Logger.warning("TypeRight: keychain update failed (\(updated))", category: Logger.general)
            return false
        }
        var add = base(account)
        add[kSecValueData as String] = data
        let added = SecItemAdd(add as CFDictionary, nil)
        if added != errSecSuccess { Logger.warning("TypeRight: keychain add failed (\(added))", category: Logger.general) }
        return added == errSecSuccess
    }
}

/// The providers' keys. Whether each provider has one is kept in memory and updated on every save,
/// so pauses and the provider list never wait on the keychain. A key the provider turned down
/// (HTTP 401 / 403) stays marked until a new one is saved; the AI cards stop until then.
final class CoachKeyStore: @unchecked Sendable {
    /// Screenshots swap in a store with a made-up key, so they never read the user's keychain.
    static var shared = CoachKeyStore(read: { CoachKeychain.read(account: $0) },
                                      write: { CoachKeychain.setString($0, account: $1) })

    private let readItem: (String) -> CoachKeyRead
    private let writeItem: (String, String) -> Bool
    private let lock = NSLock()
    private var known: [CoachProvider: Bool] = [:]
    private var rejected: Set<CoachProvider> = []

    init(read: @escaping (String) -> CoachKeyRead, write: @escaping (_ value: String, _ account: String) -> Bool) {
        readItem = read
        writeItem = write
    }

    private static func account(_ provider: CoachProvider) -> String { "\(provider.rawValue)_api_key" }

    /// Reads the key from the keychain (the request and the settings page need the value itself).
    func key(for provider: CoachProvider) -> CoachKeyRead {
        let result = readItem(Self.account(provider))
        lock.withLock {
            switch result {
            case let .found(text): known[provider] = !text.isEmpty
            case .missing: known[provider] = false
            case .failed: break
            }
        }
        if case let .failed(status) = result {
            Logger.warning("TypeRight: could not read the \(provider.rawValue) key from the keychain (\(status))", category: Logger.general)
        }
        return result
    }

    func hasKey(_ provider: CoachProvider) -> Bool {
        if let cached = lock.withLock({ known[provider] }) { return cached }
        if case let .found(text) = key(for: provider) { return !text.isEmpty }
        return false
    }

    /// Saves a key (empty deletes it). False when the keychain refused; the cache then asks again next time.
    @discardableResult
    func save(_ key: String, for provider: CoachProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = writeItem(trimmed, Self.account(provider))
        lock.withLock {
            known[provider] = saved ? !trimmed.isEmpty : nil
            if saved { rejected.remove(provider) }
        }
        return saved
    }

    func isRejected(_ provider: CoachProvider) -> Bool { lock.withLock { rejected.contains(provider) } }

    func markRejected(_ provider: CoachProvider) {
        _ = lock.withLock { rejected.insert(provider) }
        Logger.warning("TypeRight: \(provider.rawValue) turned the key down; AI cards stop until a new key is saved", category: Logger.llm)
    }
}

// MARK: - Results

struct CoachTranslation: Decodable, Equatable {
    let english: String
    let ipa: String
    let note: String

    private enum CodingKeys: String, CodingKey { case english, ipa, note }

    init(english: String, ipa: String, note: String) {
        self.english = english
        self.ipa = ipa
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        english = try c.decode(String.self, forKey: .english)
        ipa = (try? c.decode(String.self, forKey: .ipa)) ?? ""
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
}

struct CoachSentenceCheck: Decodable, Equatable {
    struct Change: Decodable, Equatable {
        let from: String
        let to: String
        let why: String
        /// Kind of mistake, one of the words listed in the check prompt.
        let type: String

        private enum CodingKeys: String, CodingKey { case from, to, why, type }

        init(from: String, to: String, why: String, type: String = "other") {
            self.from = from
            self.to = to
            self.why = why
            self.type = type
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            from = (try? c.decode(String.self, forKey: .from)) ?? ""
            to = (try? c.decode(String.self, forKey: .to)) ?? ""
            why = (try? c.decode(String.self, forKey: .why)) ?? ""
            type = (try? c.decode(String.self, forKey: .type)) ?? "other"
        }
    }

    let ok: Bool
    let corrected: String
    let changes: [Change]

    private enum CodingKeys: String, CodingKey { case ok, corrected, changes }

    init(ok: Bool, corrected: String, changes: [Change]) {
        self.ok = ok
        self.corrected = corrected
        self.changes = changes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        corrected = (try? c.decode(String.self, forKey: .corrected)) ?? ""
        changes = (try? c.decode([Change].self, forKey: .changes)) ?? []
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? changes.isEmpty
    }
}

enum CoachAIError: LocalizedError {
    case notConfigured
    /// The provider answered with this HTTP status; what it wrote goes to the log only.
    case http(Int)
    case timedOut
    case offline
    case badResponse
    /// Through our backend: the trial or membership cannot be used now, or the backend could not be reached.
    /// `MemberError.kind` says which (used up, today's limit, offline, device token …).
    case member(MemberError)

    /// The provider turned the key down.
    var keyRejected: Bool {
        if case let .http(code) = self { return code == 401 || code == 403 }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured: "还没选 AI 或没填 Key。"
        case let .http(code):
            switch code {
            case 401, 403: "AI 的 Key 不对或已经失效，去设置 › AI 服务商换一个。"
            case 402: "AI 账户的余额不够了，充值后再用。"
            case 429: "AI 服务商限流了，过一会儿再试。"
            case 500 ... 599: "AI 服务商那边出错了（\(code)），过一会儿再试。"
            default: "AI 服务商没接受这次请求（\(code)）。"
            }
        case .timedOut: "AI 超过 15 秒没回，这次先跳过。"
        case .offline: "连不上网，AI 这次没回。拼写照样在本机查。"
        case .badResponse: "AI 返回的内容读不懂。"
        case let .member(error): MemberText.detail(error)
        }
    }

    /// No answer from the provider: timeout and no network get their own words, a cancelled request stays a cancellation.
    static func from(_ error: URLError) -> Error {
        switch error.code {
        case .timedOut: CoachAIError.timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed: CoachAIError.offline
        case .cancelled: CancellationError()
        default: error
        }
    }
}

// MARK: - Client

enum CoachAI {
    static func systemPrompt() -> String {
        "You help a Chinese speaker who is typing English in chat apps, email and AI prompts. "
            + "Reply with one JSON object only. Explanations are in \(CoachSettings.explainLanguage), "
            + "one short sentence each, plain words, no grammar jargon unless needed."
    }

    /// Hands each new, more complete version of the answer to the card as it arrives.
    typealias Partial<T> = @MainActor @Sendable (T) -> Void

    /// The English for `fragment` (Chinese or pinyin) as it sits in `sentence`. The English words come
    /// first in the answer, so `partial` gets them before the IPA and the note.
    static func translate(fragment: String, in sentence: String, via route: CoachAIRoute,
                          keys: CoachKeyStore = .shared, lines: @escaping CoachNet.Lines = CoachNet.lines,
                          partial: Partial<CoachTranslation>? = nil) async throws -> CoachTranslation
    {
        let marked = sentence.replacingOccurrences(of: fragment, with: "⟦\(fragment)⟧", options: [], range: sentence.range(of: fragment))
        let prompt = """
        Task: translate. In the sentence below, the part inside ⟦ ⟧ is Chinese or pinyin the user could not say in English. \
        Give the English words that should replace exactly that part so the sentence reads naturally. \
        JSON: {"english": "...", "ipa": "IPA of the English words, \(CoachSettings.accent == "uk" ? "British" : "US"), with slashes", "note": "when to use it vs. close alternatives, one sentence"}
        Sentence: \(marked)
        """
        var shown: CoachTranslation?
        let json = try await stream(prompt, maxTokens: 300, via: route, keys: keys, lines: lines) { text in
            guard let partial, let json = PartialJSON.parse(text), let now = CoachTranslation.partial(json), now != shown else { return }
            shown = now
            await partial(now)
        }
        guard let parsed = PartialJSON.parse(json), parsed.isClosed, let result = CoachTranslation.partial(parsed) else { throw CoachAIError.badResponse }
        return result
    }

    /// Grammar, spelling and clearly unnatural wording in one finished sentence. The model only lists
    /// its edits and their reasons (edits first); the corrected sentence is put together here.
    static func check(sentence: String, mayBeUnfinished: Bool = false, via route: CoachAIRoute,
                      keys: CoachKeyStore = .shared, lines: @escaping CoachNet.Lines = CoachNet.lines,
                      partial: Partial<CoachSentenceCheck>? = nil) async throws -> CoachSentenceCheck
    {
        let unfinishedRule = mayBeUnfinished
            ? "The user may still be typing: never add words to complete it and do not add final punctuation. "
            : ""
        let prompt = """
        Task: check. Correct grammar, spelling and clearly unnatural (Chinglish) wording in this sentence with as few changes as possible; \
        keep the meaning, tone and punctuation style. Casual chat words (wanna, gonna, lol) are fine, \
        but the pronoun I is always a capital letter. \
        Do not change names, code, URLs or anything in quotes. \(unfinishedRule)\
        If it is fine, return {"ok": true}. Otherwise return {"ok": false, \
        "edits": [{"from": "words copied exactly from the sentence", "to": "what replaces them"}], \
        "notes": [{"why": "reason", "type": "one of spelling, article, tense, plural, preposition, chinglish, agreement, capitalization, word-choice, punctuation, other"}]}. \
        List the edits in sentence order; "from" is never empty (to add a word, include the word next to it); one note per edit, in the same order.
        Sentence: \(sentence)
        """
        var shown: CoachSentenceCheck?
        let json = try await stream(prompt, maxTokens: 500, via: route, keys: keys, lines: lines) { text in
            guard let partial, let json = PartialJSON.parse(text),
                  let now = CoachSentenceCheck.partial(json, original: sentence), now != shown else { return }
            shown = now
            await partial(now)
        }
        guard let parsed = PartialJSON.parse(json), parsed.isClosed,
              let result = CoachSentenceCheck.partial(parsed, original: sentence) else { throw CoachAIError.badResponse }
        return result
    }

    /// Seconds one request may sit without a byte; a card that comes later than this is no use to someone typing.
    static let requestTimeout: TimeInterval = 15

    /// Sends one prompt with streaming on and calls `grew` with the model's text each time more of it
    /// arrives; returns the whole text. A reply that is not a stream (a provider that ignores
    /// `stream`) is read as one ordinary answer. A 401 or 403 from the provider marks the key as
    /// turned down (`CoachKeyStore`), which stops the AI cards until a new key is saved.
    static func stream(_ prompt: String, maxTokens: Int, via route: CoachAIRoute, keys: CoachKeyStore = .shared,
                       lines: @escaping CoachNet.Lines = CoachNet.lines, grew: (String) async -> Void = { _ in }) async throws -> String
    {
        let body = try JSONSerialization.data(withJSONObject: requestBody(prompt, maxTokens: maxTokens, via: route, stream: true))
        var timing = CoachStreamTiming(sent: CoachStreamTiming.now)
        let replyLines: AsyncThrowingStream<String, Error>
        let label: String
        switch route {
        case let .own(provider):
            label = provider.rawValue
            guard case let .found(key) = keys.key(for: provider), !key.isEmpty,
                  let url = URL(string: provider.endpoint), url.host != nil else { throw CoachAIError.notConfigured }
            var request = URLRequest(url: url, timeoutInterval: requestTimeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = body
            CoachNet.used(url)
            timing.sent = CoachStreamTiming.now
            Logger.info("⏱ request sent (\(label))", category: Logger.llm)
            let response: URLResponse
            do {
                (response, replyLines) = try await lines(request)
            } catch let error as URLError {
                Logger.warning("TypeRight: \(provider.rawValue) gave no answer: URLError \(error.code.rawValue)", category: Logger.llm)
                throw CoachAIError.from(error)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let data = await CoachNet.body(of: replyLines)
                Logger.warning("TypeRight: \(provider.rawValue) answered HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))", category: Logger.llm)
                let error = CoachAIError.http(status)
                if error.keyRejected { keys.markRejected(provider) }
                throw error
            }
        case let .member(use):
            label = "member"
            if let api = MemberAPI.current { CoachNet.used(api) }
            timing.sent = CoachStreamTiming.now
            Logger.info("⏱ request sent (\(label))", category: Logger.llm)
            do {
                replyLines = try await MemberService.shared.chat(body, use: use, timeout: requestTimeout)
            } catch let error as MemberError {
                throw CoachAIError.member(error)
            }
        }
        timing.headers = CoachStreamTiming.now

        var text = ""
        var plain = ""
        var sawEvents = false
        do {
            for try await line in replyLines {
                guard line.hasPrefix("data:") else {
                    if !sawEvents { plain += line + "\n" }
                    continue
                }
                sawEvents = true
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                if let usage = event["usage"] as? [String: Any] {
                    timing.tokensIn = usage["prompt_tokens"] as? Int
                    timing.tokensOut = usage["completion_tokens"] as? Int
                }
                guard let choices = event["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let piece = delta["content"] as? String, !piece.isEmpty else { continue }
                if timing.firstToken == nil { timing.firstToken = CoachStreamTiming.now }
                text += piece
                await grew(text)
            }
        } catch let error as URLError {
            Logger.warning("TypeRight: \(label) stream broke off: URLError \(error.code.rawValue)", category: Logger.llm)
            throw CoachAIError.from(error)
        }
        if !sawEvents {
            text = String(decoding: try content(of: Data(plain.utf8)), as: UTF8.self)
            timing.firstToken = CoachStreamTiming.now
            await grew(text)
        }
        timing.done = CoachStreamTiming.now
        Logger.info("⏱ response done (\(label)): headers \(timing.ms(timing.headers)) ms, first token \(timing.ms(timing.firstToken)) ms, done \(timing.ms(timing.done)) ms, tokens in \(timing.tokensIn.map(String.init) ?? "-") out \(timing.tokensOut.map(String.init) ?? "-")\(sawEvents ? "" : ", not streamed")", category: Logger.llm)
        return stripCodeFence(text)
    }

    /// Output room for the thinking a model cannot turn off: it counts toward the output cap.
    static let thinkingRoom = 1500

    /// The chat/completions body. Through our backend the model and thinking are the backend's choice
    /// (deepseek-flash, thinking off), so only the prompt, the output cap and JSON mode are sent.
    /// With an own key each provider gets what its documentation accepts (checked 2026-11):
    /// thinking off where it can be turned off, no `temperature` where reasoning models reject or
    /// ignore it, `max_completion_tokens` where `max_tokens` is deprecated, and no JSON mode where
    /// it is not supported (Claude answers 400 to `json_object`; Gemini does not document it).
    static func requestBody(_ prompt: String, maxTokens: Int, via route: CoachAIRoute, model: String? = nil, stream: Bool = false) -> [String: Any] {
        var body: [String: Any] = [
            "model": MemberAPI.model,
            "messages": [
                ["role": "system", "content": systemPrompt()],
                ["role": "user", "content": prompt],
            ],
        ]
        if stream { body["stream"] = true }
        let json = ["type": "json_object"]
        guard case let .own(provider) = route else {
            body["temperature"] = 0.2
            body["max_tokens"] = maxTokens
            body["response_format"] = json
            return body
        }
        let model = model ?? CoachSettings.model(for: provider)
        body["model"] = model
        switch provider {
        case .deepseek, .doubao:
            body["temperature"] = 0.2
            body["max_tokens"] = maxTokens
            body["response_format"] = json
            body["thinking"] = ["type": "disabled"]
            // Both document usage at the end of a stream; it goes into the timing line only.
            if stream { body["stream_options"] = ["include_usage": true] }
        case .zhipu:
            body["temperature"] = 0.2
            body["response_format"] = json
            if model.lowercased().hasPrefix("glm-5.3") {
                // GLM-5.3 and its flash model always think.
                body["max_tokens"] = maxTokens + thinkingRoom
            } else {
                body["max_tokens"] = maxTokens
                body["thinking"] = ["type": "disabled"]
            }
        case .qwen:
            body["temperature"] = 0.2
            body["max_tokens"] = maxTokens
            body["response_format"] = json
            body["enable_thinking"] = false
        case .kimi:
            // K3 always thinks, at the most effort unless told otherwise; its temperature is fixed.
            body["max_completion_tokens"] = maxTokens + thinkingRoom
            body["reasoning_effort"] = "low"
            body["response_format"] = json
        case .openai:
            body["max_completion_tokens"] = maxTokens + thinkingRoom
            body["reasoning_effort"] = "low"
            body["response_format"] = json
        case .gemini:
            // Gemini 3 cannot stop thinking; minimal is its lowest level.
            body["max_tokens"] = maxTokens + thinkingRoom
            body["reasoning_effort"] = "minimal"
        case .claude:
            // Claude 5 models think by default; the compatibility layer documents no way to turn it off.
            body["max_tokens"] = maxTokens + thinkingRoom
        case .openrouter:
            body["max_tokens"] = maxTokens + thinkingRoom
            body["reasoning"] = ["effort": "low"]
            body["response_format"] = json
        case .custom:
            body["temperature"] = 0.2
            body["max_tokens"] = maxTokens
            body["response_format"] = json
        }
        return body
    }

    /// The JSON inside an OpenAI-style chat reply.
    static func content(of data: Data) throws -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw CoachAIError.badResponse }
        return Data(stripCodeFence(content).utf8)
    }

    /// Some models wrap JSON in ``` fences even when asked not to.
    static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let newline = s.firstIndex(of: "\n") { s = String(s[s.index(after: newline)...]) }
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        }
        if let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"), open < close {
            s = String(s[open ... close])
        }
        return s
    }
}
