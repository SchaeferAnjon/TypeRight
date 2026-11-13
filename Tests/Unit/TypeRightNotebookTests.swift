//
//  TypeRightNotebookTests.swift
//  TypeRight
//
//  The mistake and word books on disk and the "used right 3 times" count. Every notebook here
//  lives in its own temporary folder.
//

@testable import TextWarden
import XCTest

@MainActor
final class TypeRightNotebookTests: XCTestCase {
    private var folder: URL!
    private var file: URL { folder.appendingPathComponent("notebook.json") }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TypeRightNotebookTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: file)
    }

    // MARK: Item 4: reading files from other versions, and files that cannot be read

    func testOldFileWithMissingFieldsOpens() throws {
        try write(#"{"entries":[{"kind":"mistake","from":"tomorow","to":"tomorrow"}],"days":[{"day":"2026-11-10","sentences":3}]}"#)
        let notebook = CoachNotebook(fileURL: file)
        let entry = try XCTUnwrap(notebook.entries.first)
        XCTAssertEqual(entry.to, "tomorrow")
        XCTAssertEqual(entry.category, .other)
        XCTAssertEqual(entry.times, 1)
        XCTAssertEqual(entry.correctUses, 0)
        XCTAssertEqual(notebook.days.first?.sentences, 3)
        XCTAssertEqual(notebook.days.first?.clean, 0)
    }

    /// Written before typing along existed: every entry then was TypeRight's replacement.
    func testOldEntriesCountAsReplaced() throws {
        try write(#"{"entries":[{"kind":"word","from":"预约","to":"book","date":"2026-11-10T08:00:00Z"}],"days":[]}"#)
        XCTAssertEqual(CoachNotebook(fileURL: file).entries.first?.how, .replaced)
    }

    func testHowTheEnglishGotThereIsKeptAndUpdated() throws {
        let notebook = CoachNotebook(fileURL: file)
        let book = CoachCardContent.translate(source: "预约", result: CoachTranslation(english: "book", ipa: "", note: ""))
        notebook.record(book, app: "Chat", context: "", how: .typed)
        notebook.record(.spelling(wrong: "tomorow", fixes: ["tomorrow"]), app: "Chat", context: "")
        notebook.flush()
        let again = CoachNotebook(fileURL: file)
        XCTAssertEqual(again.words.first?.how, .typed)
        XCTAssertEqual(again.mistakes.first?.how, .replaced)
        again.record(book, app: "Chat", context: "", how: .replaced)
        XCTAssertEqual(again.words.first?.how, .replaced, "the same word again: the latest way counts")
        XCTAssertEqual(again.words.first?.times, 2)
    }

    func testUnknownKindOfMistakeBecomesOther() throws {
        try write(#"{"entries":[{"kind":"mistake","category":"idioms-2027","from":"a","to":"b","date":"2026-11-10T08:00:00Z"}],"days":[]}"#)
        let notebook = CoachNotebook(fileURL: file)
        XCTAssertEqual(notebook.entries.first?.category, .other)
    }

    func testUnreadableFileIsKeptAsideAndNeverOverwritten() throws {
        let broken = #"{"entries": [ this is not json"#
        try write(broken)
        let notebook = CoachNotebook(fileURL: file)
        XCTAssertTrue(notebook.entries.isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("notebook-unreadable-") }
        XCTAssertEqual(aside.count, 1)
        notebook.record(.spelling(wrong: "tomorow", fixes: ["tomorrow"]), app: "Chat", context: "see you tomorrow")
        notebook.flush()
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(aside[0]), encoding: .utf8), broken)
        XCTAssertEqual(CoachNotebook(fileURL: file).entries.first?.to, "tomorrow", "new records go to a new file")
    }

    // MARK: Item 24: writes are batched off the main thread, and the book stays bounded

    func testWritesAreBatchedAndFlushedOnRequest() throws {
        let notebook = CoachNotebook(fileURL: file)
        notebook.record(.spelling(wrong: "tomorow", fixes: ["tomorrow"]), app: "Chat", context: "")
        notebook.noteSentence(clean: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing is written right away")
        notebook.flush()
        let again = CoachNotebook(fileURL: file)
        XCTAssertEqual(again.entries.count, 1)
        XCTAssertEqual(again.days.last?.clean, 1)
    }

    func testOldestEntriesGoPastTheLimitLearnedFirst() {
        let notebook = CoachNotebook(fileURL: file, maxEntries: 2)
        notebook.record(.spelling(wrong: "aa", fixes: ["a"]), app: "", context: "")
        notebook.record(.spelling(wrong: "bb", fixes: ["b"]), app: "", context: "")
        if let first = notebook.entries.first { notebook.setMastered(first.id, true) }
        notebook.record(.spelling(wrong: "cc", fixes: ["c"]), app: "", context: "")
        XCTAssertEqual(notebook.entries.map(\.from), ["bb", "cc"])
    }

    // MARK: Item 23: what counts as using a point right

    private func entry(_ kind: NotebookEntry.Kind = .mistake, from: String, to: String, context: String = "") -> NotebookEntry {
        NotebookEntry(kind: kind, category: .other, from: from, to: to, why: "", ipa: "", context: context, app: "", date: Date())
    }

    func testCapitalizationCountsOnlyWithTheRightCase() {
        let i = entry(from: "i", to: "I")
        XCTAssertTrue(CoachNotebook.usesCorrectly(i, in: "I think so."))
        XCTAssertFalse(CoachNotebook.usesCorrectly(i, in: "i think so."))
    }

    func testAddedWordCountsOnlyBetweenTheSameNeighbours() {
        let the = entry(from: "", to: "the", context: "I went to the store.")
        XCTAssertTrue(CoachNotebook.usesCorrectly(the, in: "Then I went to the store again."))
        XCTAssertFalse(CoachNotebook.usesCorrectly(the, in: "The weather is nice."))
        let alone = entry(from: "", to: "the", context: "the")
        XCTAssertFalse(CoachNotebook.usesCorrectly(alone, in: "the cat"), "no neighbours: no automatic count")
    }

    func testReplacedWordCountsWhenTheMistakeIsGone() {
        let have = entry(from: "has", to: "have", context: "I have a question.")
        XCTAssertTrue(CoachNotebook.usesCorrectly(have, in: "We have time."))
        XCTAssertFalse(CoachNotebook.usesCorrectly(have, in: "She has what we have."))
    }

    func testWordBookCountsWhenTheUserWritesTheWord() {
        let notebook = CoachNotebook(fileURL: file)
        notebook.record(.translate(source: "预约", result: CoachTranslation(english: "book", ipa: "", note: "")), app: "", context: "")
        notebook.noteCorrectUse(in: "Can I book a table?")
        XCTAssertEqual(notebook.words.first?.correctUses, 1)
    }
}
