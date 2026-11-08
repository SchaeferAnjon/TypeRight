//
//  CoachNotebook.swift
//  TypeRight
//
//  Every fix the user took with Tab: the mistake book (spelling, sentence fixes) and the word
//  book (English learned from Chinese or pinyin). One JSON object per line, on this Mac only.
//

import Foundation

struct CoachNotebookEntry: Codable, Equatable {
    enum Kind: String, Codable { case spelling, translate, sentence }

    let kind: Kind
    let from: String
    let to: String
    let why: String
    let ipa: String
    let app: String
    let date: Date
}

@MainActor
final class CoachNotebook {
    static let shared = CoachNotebook()

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.typeright.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("notebook.jsonl")
    }()

    func record(_ content: CoachCardContent, app: String) {
        let entries: [CoachNotebookEntry]
        let now = Date()
        switch content {
        case let .spelling(wrong, fixes):
            entries = [CoachNotebookEntry(kind: .spelling, from: wrong, to: fixes.first ?? "", why: "", ipa: "", app: app, date: now)]
        case let .translate(source, result):
            entries = [CoachNotebookEntry(kind: .translate, from: source, to: result.english, why: result.note, ipa: result.ipa, app: app, date: now)]
        case let .sentence(_, check):
            entries = check.changes.map {
                CoachNotebookEntry(kind: .sentence, from: $0.from, to: $0.to, why: $0.why, ipa: "", app: app, date: now)
            }
        case .thinking, .failed:
            entries = []
        }
        guard !entries.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    func all() -> [CoachNotebookEntry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(CoachNotebookEntry.self, from: Data($0.utf8)) }
    }
}
