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

    /// Providers whose fast model thinks unless told not to.
    var disablesThinking: Bool { [.deepseek, .zhipu, .doubao].contains(self) }

    /// Providers that cannot turn thinking off take the lowest effort instead.
    var reasoningEffort: String? {
        switch self {
        case .openai: "low"
        case .gemini: "minimal"
        default: nil
        }
    }
}

// MARK: - Settings

enum CoachSettings {
    private static var defaults: UserDefaults { .standard }

    static var provider: CoachProvider {
        get { CoachProvider(rawValue: defaults.string(forKey: "typeright.provider") ?? "") ?? .deepseek }
        set { defaults.set(newValue.rawValue, forKey: "typeright.provider") }
    }

    static func model(for provider: CoachProvider) -> String {
        let custom = defaults.string(forKey: "typeright.model.\(provider.rawValue)") ?? ""
        return custom.isEmpty ? provider.defaultModel : custom
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

    /// Seconds of no typing before the AI cards are asked for.
    static var pauseSeconds: Double {
        get { defaults.object(forKey: "typeright.pauseSeconds") as? Double ?? 0.8 }
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

    static var isAIReady: Bool {
        let provider = provider
        if provider == .custom, URL(string: provider.endpoint)?.host == nil { return false }
        return !(CoachKeychain.key(for: provider) ?? "").isEmpty && !model(for: provider).isEmpty
    }
}

// MARK: - Keychain

enum CoachKeychain {
    private static var service: String { Bundle.main.bundleIdentifier ?? "com.typeright.app" }

    static func key(for provider: CoachProvider) -> String? {
        string(account: "\(provider.rawValue)_api_key")
    }

    @discardableResult
    static func setKey(_ key: String, for provider: CoachProvider) -> Bool {
        setString(key, account: "\(provider.rawValue)_api_key")
    }

    static func string(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the item; an empty value only deletes it.
    @discardableResult
    static func setString(_ value: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
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
    case http(Int, String)
    case badResponse
    /// Through our backend: the trial or membership cannot be used now, or the backend could not be reached.
    /// `MemberError.kind` says which (used up, today's limit, offline, device token …).
    case member(MemberError)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "还没选 AI 或没填 Key"
        case let .http(code, body): "AI 服务返回 \(code)：\(body.prefix(160))"
        case .badResponse: "AI 返回的内容读不懂"
        case let .member(error): MemberText.detail(error)
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

    /// The English for `fragment` (Chinese or pinyin) as it sits in `sentence`.
    static func translate(fragment: String, in sentence: String, via route: CoachAIRoute) async throws -> CoachTranslation {
        let marked = sentence.replacingOccurrences(of: fragment, with: "⟦\(fragment)⟧", options: [], range: sentence.range(of: fragment))
        let prompt = """
        Task: translate. In the sentence below, the part inside ⟦ ⟧ is Chinese or pinyin the user could not say in English. \
        Give the English words that should replace exactly that part so the sentence reads naturally. \
        JSON: {"english": "...", "ipa": "IPA of the English words, \(CoachSettings.accent == "uk" ? "British" : "US"), with slashes", "note": "when to use it vs. close alternatives, one sentence"}
        Sentence: \(marked)
        """
        let data = try await complete(prompt, maxTokens: 300, via: route)
        guard let result = try? JSONDecoder().decode(CoachTranslation.self, from: data),
              !result.english.trimmingCharacters(in: .whitespaces).isEmpty else { throw CoachAIError.badResponse }
        return result
    }

    /// Grammar, spelling and clearly unnatural wording in one finished sentence.
    static func check(sentence: String, mayBeUnfinished: Bool = false, via route: CoachAIRoute) async throws -> CoachSentenceCheck {
        let unfinishedRule = mayBeUnfinished
            ? "The user may still be typing: never add words to complete it and do not add final punctuation. "
            : ""
        let prompt = """
        Task: check. Correct grammar, spelling and clearly unnatural (Chinglish) wording in this sentence with as few changes as possible; \
        keep the meaning, tone and punctuation style. Casual chat words (wanna, gonna, lol) are fine, \
        but the pronoun I is always a capital letter. \
        Do not change names, code, URLs or anything in quotes. \(unfinishedRule)\
        If it is fine, return {"ok": true}. Otherwise return {"ok": false, "corrected": "the whole corrected sentence", \
        "changes": [{"from": "original words", "to": "new words", "why": "reason", \
        "type": "one of spelling, article, tense, plural, preposition, chinglish, agreement, capitalization, word-choice, punctuation, other"}]}
        Sentence: \(sentence)
        """
        let data = try await complete(prompt, maxTokens: 500, via: route)
        guard let result = try? JSONDecoder().decode(CoachSentenceCheck.self, from: data) else { throw CoachAIError.badResponse }
        return result
    }

    /// Seconds one request may take; a card that comes later than this is no use to someone typing.
    static let requestTimeout: TimeInterval = 15

    /// Sends one prompt and returns the JSON the model wrote.
    static func complete(_ prompt: String, maxTokens: Int, via route: CoachAIRoute) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: requestBody(prompt, maxTokens: maxTokens, via: route))
        switch route {
        case let .own(provider):
            guard let key = CoachKeychain.key(for: provider), !key.isEmpty,
                  let url = URL(string: provider.endpoint), url.host != nil else { throw CoachAIError.notConfigured }
            var request = URLRequest(url: url, timeoutInterval: requestTimeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = body

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw CoachAIError.http(status, String(data: data, encoding: .utf8) ?? "") }
            return try content(of: data)
        case let .member(use):
            do {
                return try content(of: await MemberService.shared.chat(body, use: use, timeout: requestTimeout))
            } catch let error as MemberError {
                throw CoachAIError.member(error)
            }
        }
    }

    /// The chat/completions body. Through our backend the model and thinking are the backend's choice
    /// (deepseek-flash, thinking off), so only the prompt, the output cap and JSON mode are sent.
    static func requestBody(_ prompt: String, maxTokens: Int, via route: CoachAIRoute) -> [String: Any] {
        var body: [String: Any] = [
            "model": MemberAPI.model,
            "messages": [
                ["role": "system", "content": systemPrompt()],
                ["role": "user", "content": prompt],
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "response_format": ["type": "json_object"],
        ]
        if case let .own(provider) = route {
            body["model"] = CoachSettings.model(for: provider)
            if provider.disablesThinking { body["thinking"] = ["type": "disabled"] }
            if let effort = provider.reasoningEffort { body["reasoning_effort"] = effort }
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
