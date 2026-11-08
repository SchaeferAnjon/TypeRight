//
//  CoachAISettingsView.swift
//  TypeRight
//
//  Settings › AI 服务商: which AI turns Chinese into English and checks sentences, and its key.
//  Spelling is checked on this Mac and needs none of this.
//

import SwiftUI

struct CoachAISettingsView: View {
    @State private var provider = CoachSettings.provider
    @State private var key = ""
    @State private var model = ""
    @State private var baseURL = CoachSettings.customBaseURL
    @State private var cardsEnabled = CoachSettings.cardsEnabled
    @State private var language = CoachSettings.explainLanguage
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, running, ok(String), failed(String)
    }

    private static let languages = ["简体中文", "繁體中文", "English", "Deutsch", "日本語", "한국어", "Français", "Español"]

    var body: some View {
        Form {
            Section {
                Toggle("边打边弹框", isOn: $cardsEnabled)
                    .onChange(of: cardsEnabled) { CoachSettings.cardsEnabled = $0 }
                Text("拼错一个词、打了中文或拼音、一句打完时，在旁边弹出改法。Tab 接受，Esc 不改。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("讲解用", selection: $language) {
                    ForEach(Self.languages, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: language) { CoachSettings.explainLanguage = $0 }
            }

            Section("AI 服务商") {
                Text("中文变英文、整句检查要用 AI；拼写在这台 Mac 上查，不用 AI。Key 存在钥匙串里，请求从你的 Mac 直接发给你选的那家。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("用哪家", selection: $provider) {
                    ForEach(CoachProvider.allCases) { p in
                        Text("\(p.displayName)　\(p.blurb)").tag(p)
                    }
                }
                .onChange(of: provider) { new in
                    CoachSettings.provider = new
                    loadFields()
                }

                if provider == .custom {
                    TextField("接口地址（…/v1）", text: $baseURL)
                        .onChange(of: baseURL) { CoachSettings.customBaseURL = $0 }
                }

                HStack {
                    SecureField("API Key", text: $key)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(saveKey)
                        .onChange(of: key) { _ in saveKey() }
                    if let page = provider.keyPage {
                        Link("去拿 Key", destination: page)
                    }
                }
                TextField("模型（留空用 \(provider.defaultModel)）", text: $model)
                    .onChange(of: model) { CoachSettings.setModel($0, for: provider) }

                HStack(spacing: 10) {
                    Button("试一下") { test() }
                        .disabled(testState == .running)
                    switch testState {
                    case .idle: EmptyView()
                    case .running: Text("正在问…").foregroundStyle(.secondary)
                    case let .ok(text): Text("连上了：\(text)").foregroundStyle(CoachPalette.fix(.light))
                    case let .failed(text): Text(text).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .font(.system(size: 12))
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadFields)
    }

    private func loadFields() {
        key = CoachKeychain.key(for: provider) ?? ""
        let saved = UserDefaults.standard.string(forKey: "typeright.model.\(provider.rawValue)") ?? ""
        model = saved
        testState = .idle
    }

    private func saveKey() {
        CoachKeychain.setKey(key, for: provider)
    }

    private func test() {
        saveKey()
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            testState = .failed("先把 Key 粘贴进来")
            return
        }
        testState = .running
        Task {
            do {
                let result = try await CoachAI.check(sentence: "I has a question.")
                testState = .ok(result.ok ? "I has a question." : result.corrected)
            } catch {
                testState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}
