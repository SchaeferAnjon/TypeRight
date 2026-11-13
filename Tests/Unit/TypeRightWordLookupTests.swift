//
//  TypeRightWordLookupTests.swift
//  TypeRight
//
//  The word layer's dictionary: which record counts as the word's, its IPA by accent, its meanings,
//  word forms that point to their word, and a Mac without the dictionary. The records here are the
//  dictionary's own XHTML: three copied from 牛津英汉汉英词典 on 2026-11-13, the others built the same way.
//

@testable import TextWarden
import XCTest

final class TypeRightWordLookupTests: XCTestCase {
    // MARK: Records

    /// `went` as the dictionary has it: past tense, pointing to go.
    static let went = ##"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
    <html xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng"><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8" /></head><body><d:entry id="e_b-en-zh_hans0042603" d:title="went" class="entry" lang="zh-cmn-Hans" xml:lang="zh-cmn-Hans"><span class="hwg x_xh0"><span d:dhw="1" role="text" class="hw">went </span><span prxid="went_gb_-7cb8" prlexid="optra0153419.001" dialect="BrE" class="prx"><span class="gp tg_prx"> | </span><span class="gp tg_prx">BrE </span><span d:prn="UK_IPA solitary" soundFile="went#_gb_1" dialect="BrE" class="ph">wɛnt<d:prn></d:prn></span><span class="gp tg_prx">, </span></span><span prxid="went_us_-7cb1" prlexid="optra0153419.002" dialect="AmE" class="prx"><span class="gp tg_prx">AmE </span><span d:prn="UK_IPA solitary" soundFile="went#_us_1" dialect="AmE" class="ph">wɛnt<d:prn></d:prn></span><span class="gp tg_prx"> | </span></span><span class="gp tg_hwg"> </span></span><span lexid="b-en-zh_hans0042603.001" class="gramb x_xd0"><span class="x_xdh"><span d:pos="1" class="ps">past tense <d:pos></d:pos></span><span class="gp">  </span></span><span lexid="b-en-zh_hans0042603.002" class="semb x_xd1"><span d:def="1" class="xrg x_xd2"><span class="gp tg_xrg">→ </span><span class="xr"><a href="x-dictionary:r:e_b-en-zh_hans0015482:com.apple.dictionary.zh_CN-en.OCD#xpointer(//*[@id='e_DWS-001168'])" title="go">go<span class="xrlabelGroup"><span class="xrlabel"> A</span></span><span class="gp tg_xr">, </span></a></span><span class="xr"><a href="x-dictionary:r:e_b-en-zh_hans0015482:com.apple.dictionary.zh_CN-en.OCD#xpointer(//*[@id='e_DWS-001169'])" title="go"><span class="xrlabelGroup"><span class="xrlabel">B</span></span></a></span><d:def></d:def></span></span></span></d:entry></body></html>
    
    """##

    /// `has` as the dictionary has it: 3rd person singular present, pointing to have.
    static let has = ##"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
    <html xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng"><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8" /></head><body><d:entry id="e_b-en-zh_hans0016512" d:title="has" class="entry" lang="zh-cmn-Hans" xml:lang="zh-cmn-Hans"><span class="hwg x_xh0"><span d:dhw="1" role="text" class="hw">has </span><span prxid="has_gb_4c71" prlexid="optra0052903.001" dialect="BrE" class="prx"><span class="gp tg_prx"> | </span><span class="gp tg_prx">BrE </span><span d:prn="UK_IPA solitary" soundFile="has#_gb_3" dialect="BrE" class="ph">haz<d:prn></d:prn></span><span class="gp tg_prx">, </span></span><span prxid="has_us_4c7d" prlexid="optra0052903.002" dialect="AmE" class="prx"><span class="gp tg_prx">AmE </span><span d:prn="UK_IPA" soundFile="has#_us_4_rr" dialect="AmE" class="ph">hæz<d:prn></d:prn><span class="gp tg_ph">, </span></span><span d:prn="UK_IPA" soundFile="_s#1_us_3_rr" dialect="AmE" class="ph">(ə)z<d:prn></d:prn></span><span class="gp tg_prx"> | </span></span><span class="gp tg_hwg"> </span></span><span lexid="b-en-zh_hans0016512.001" class="gramb x_xd0"><span class="gr x_xdh">3rd person singular present </span><span lexid="b-en-zh_hans0016512.002" class="semb x_xd1"><span d:def="1" class="xrg x_xd2"><span class="gp tg_xrg">→ </span><span class="xr"><a href="x-dictionary:r:e_DWS-000047:com.apple.dictionary.zh_CN-en.OCD" title="have">have</a></span><d:def></d:def></span></span></span></d:entry></body></html>
    
    """##

    /// The first record a search for `Huang` finds: 肓 huāng.
    static let huang = ##"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
    <html xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng"><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8" /></head><body><d:entry id="z_b-zh_hans-en0002322" d:title="肓" class="entry" lang="zh-cmn-Hans" xml:lang="zh-cmn-Hans"><span class="hwg x_xh0"><span d:dhw="1" role="text" class="hw">肓 </span><span class="pr"><span d:prn="UK_IPA solitary" class="ph"> huānɡ <d:prn></d:prn> </span></span><span class="gp tg_hwg"> </span></span><span class="xrg"><span class="gp tg_xrg">→ </span><span class="xr"><a href="x-dictionary:r:z_DWS-005170:com.apple.dictionary.zh_CN-en.OCD" title="病入膏肓">病入膏肓 <span class="pr"><span d:prn="UK_IPA solitary" class="ph">bìnɡrùɡāohuānɡ <d:prn></d:prn></span></span></a></span></span></d:entry></body></html>
    
    """##

    /// A record laid out like the dictionary's: pronunciations by dialect, then groups of meanings
    /// (each with a pinyin line and an example that are not meanings).
    static func record(_ title: String, us: String? = nil, uk: String? = nil, _ groups: [(label: String, meanings: [String])]) -> String {
        var html = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><html xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng"><body>"#
        html += #"<d:entry id="x" d:title="\#(title)" class="entry"><span class="hwg x_xh0"><span d:dhw="1" class="hw">\#(title) </span>"#
        if let uk {
            html += #"<span dialect="BrE" class="prx"><span class="gp tg_prx"> | </span><span class="gp tg_prx">BrE </span><span dialect="BrE" class="ph">\#(uk)<d:prn></d:prn></span><span class="gp tg_prx">, </span></span>"#
        }
        if let us {
            html += #"<span dialect="AmE" class="prx"><span class="gp tg_prx">AmE </span><span dialect="AmE" class="ph">\#(us)<d:prn></d:prn></span><span class="gp tg_prx"> | </span></span>"#
        }
        html += "</span>"
        for group in groups {
            html += #"<span class="gramb x_xd0 hasSn"><span class="x_xdh"><span d:pos="1" class="ps">\#(group.label) <d:pos></d:pos></span></span><span class="semb x_xd1">"#
            for meaning in group.meanings {
                html += #"<span class="trg x_xd2"><span d:def="1" class="trans">\#(meaning) <d:def></d:def></span><span class="trans ty_pinyin">pīnyīn </span></span>"#
            }
            html += #"<span class="exg x_xd2"><span class="x_xdh"><span class="ex">an example </span></span><span class="trg x_xd3"><span class="trans">例句</span></span></span></span></span>"#
        }
        return html + "</d:entry></body></html>"
    }

    static let mix = record("mix", us: "mɪks", uk: "mɪks", [("transitive verb", ["使…混合", "调制", "混合"]), ("intransitive verb", ["相混合"]),
                                                           ("noun", ["混合物", "混合料"])])
    static let go = record("go", us: "ɡoʊ", uk: "ɡəʊ", [("intransitive verb", ["去", "进入某处", "变得"]), ("noun", ["精力"])])
    static let have = record("have", us: "hæv", uk: "hav", [("transitive verb", ["有", "由…组成"]), ("modal verb", ["必须"])])
    static let tomorrow = record("tomorrow", us: "təˈmɔroʊ", uk: "tʊˈmɒrəʊ", [("adverb", ["在明天", "不久"]), ("noun", ["明天", "未来"])])
    static let snow = record("snow", us: "snoʊ", uk: "snəʊ", [("noun", ["雪"]), ("impersonal verb", ["下雪"])])
    static let letterA = record("A", us: "eɪ", uk: "eɪ", [("noun", ["第一（个）"])])
    static let articleA = record("a", us: "ə", uk: "ə", [("indefinite article", ["一（个）"])])

    /// What the dictionary finds for each search, as it found it on this Mac (go comes first for went).
    private let found: [String: [String]] = [
        "mix": [mix], "went": [go, went], "go": [go], "has": [has, have], "have": [have], "tomorrow": [tomorrow],
        "huang": [huang], "a": [letterA, articleA], "snowing": [snow], "snow": [snow],
    ]

    private func lookup() -> CoachWordLookup {
        CoachWordLookup(records: { [found] in found[$0.lowercased()] ?? [] }, lemma: { ["snowing": "snow"][$0] ?? $0 })
    }

    // MARK: What the word layer shows

    func testMeaningsByPartOfSpeechWithoutExamplesOrPinyin() {
        let info = lookup().info(for: "mix", accent: "us")
        XCTAssertEqual(info.status, .found)
        XCTAssertEqual(info.ipa, "/mɪks/")
        XCTAssertEqual(info.senses, [.init(pos: "v.", meaning: "使…混合；调制"), .init(pos: "n.", meaning: "混合物；混合料")],
                       "two parts of speech, two meanings each; the two kinds of verb are one line")
        XCTAssertNil(info.emptyLine)
    }

    func testIPAFollowsTheAccentSetting() {
        XCTAssertEqual(lookup().info(for: "tomorrow", accent: "us").ipa, "/təˈmɔroʊ/")
        XCTAssertEqual(lookup().info(for: "tomorrow", accent: "uk").ipa, "/tʊˈmɒrəʊ/")
    }

    /// Searching Huang finds 肓 huāng: an entry headed by another word is nothing found.
    func testAnEntryHeadedByAnotherWordCountsAsNotFound() {
        let huang = lookup().info(for: "Huang", accent: "us")
        XCTAssertEqual(huang.status, .notFound)
        XCTAssertEqual(huang.ipa, "", "no guessed IPA")
        XCTAssertEqual(huang.emptyLine, "词典里没有，可能是人名或地名")
        XCTAssertEqual(lookup().info(for: "kokanee", accent: "us").emptyLine, "词典里没有这个词")
    }

    func testWordFormsTakeTheMeaningOfTheirWord() {
        let went = lookup().info(for: "went", accent: "us")
        XCTAssertEqual(went.ipa, "/wɛnt/", "the IPA of went, not of go")
        XCTAssertEqual(went.senses, [.init(pos: "v.", meaning: "go 的过去式：去；进入某处")])
        let has = lookup().info(for: "has", accent: "us")
        XCTAssertEqual(has.ipa, "/hæz/")
        XCTAssertEqual(has.senses, [.init(pos: "v.", meaning: "have 的第三人称单数：有；由…组成")])
    }

    /// Searching snowing finds the snow entry: its meanings, under a line saying whose form it is, and
    /// no IPA (the dictionary has only snow's).
    func testAFormWithoutItsOwnEntryShowsItsWord() {
        let info = lookup().info(for: "snowing", accent: "us")
        XCTAssertEqual(info.status, .found)
        XCTAssertEqual(info.ipa, "")
        XCTAssertEqual(info.senses, [.init(pos: "", meaning: "snow 的变化形式"), .init(pos: "n.", meaning: "雪"), .init(pos: "v.", meaning: "下雪")])
        XCTAssertEqual(CoachWordLookup.englishLemma("stories"), "story", "the system's lemma")
    }

    func testSameCaseComesFirst() {
        XCTAssertEqual(lookup().info(for: "a", accent: "us").senses.first?.pos, "art.", "a the article, not A the letter")
        XCTAssertEqual(lookup().info(for: "A", accent: "us").senses.first?.pos, "n.")
        XCTAssertEqual(lookup().info(for: "Tomorrow", accent: "us").status, .found, "a capital at the start of a sentence still finds it")
    }

    func testWithoutTheDictionaryTheLayerSaysHowToGetMeanings() {
        let info = CoachWordLookup(records: { _ in nil }).info(for: "mix", accent: "us")
        XCTAssertEqual(info.status, .noDictionary)
        XCTAssertEqual(info.emptyLine, "装上系统的英汉词典就能看中文意思")
        XCTAssertTrue(info.senses.isEmpty)
    }

    func testAMissingDictionaryIsAskedAgainLater() {
        var installed = false
        let dictionary = CoachDictionary(records: { _ in installed ? [Self.mix] : nil })
        XCTAssertEqual(dictionary.info(for: "mix", accent: "us").status, .noDictionary)
        installed = true
        XCTAssertEqual(dictionary.info(for: "mix", accent: "us").status, .found, "downloaded meanwhile: no stale answer kept")
    }

    func testTheMacsOwnDictionaryWhenItIsThere() throws {
        guard let records = CoachSystemDictionary.records("mix") else {
            throw XCTSkip("牛津英汉汉英词典 is not on this Mac")
        }
        let info = CoachWordLookup(records: { CoachSystemDictionary.records($0) }).info(for: "mix", accent: "us")
        XCTAssertFalse(records.isEmpty)
        XCTAssertEqual(info.ipa, "/mɪks/")
        XCTAssertEqual(info.senses.first?.pos, "v.")
        XCTAssertEqual(CoachWordLookup(records: { CoachSystemDictionary.records($0) }).info(for: "Huang", accent: "us").status, .notFound)
    }

    // MARK: Which words on a card the mouse can stop on

    func testOnlyTheEnglishTypeRightGaveAndNotTheSmallWords() {
        let translation = CoachCardContent.translate(source: "风雪交加", result: CoachTranslation(
            english: "a mix of wind and snow", ipa: "",
            note: "用来说风雪同时出现的天气；若只想说下大雪就用 “heavy snow”，只想说大风就用 “strong wind”。"
        ))
        XCTAssertEqual(translation.hoverWords, ["mix", "wind", "snow", "heavy", "strong"])
        let single = CoachCardContent.translate(source: "这个", result: CoachTranslation(english: "this", ipa: "", note: ""))
        XCTAssertEqual(single.hoverWords, ["this"], "the only word on the card")
        let sentence = CoachCardContent.sentence(original: "Yesterday I go to the office because I has a question.", check: CoachSentenceCheck(
            ok: false, corrected: "Yesterday I went to the office because I had a question.",
            changes: [.init(from: "go", to: "went", why: "过去的事用过去式"), .init(from: "has", to: "had", why: "")]
        ))
        XCTAssertEqual(sentence.hoverWords, ["went", "had"], "the user's own words do not open the layer")
        XCTAssertEqual(CoachCardContent.spelling(wrong: "tomorow", fixes: ["tomorrow", "tomorrows"]).hoverWords, ["tomorrow", "tomorrows"])
        let short = CoachCardContent.translate(source: "风雪", result: CoachTranslation(english: "caught in a blizzard", ipa: "",
                                                                                     note: "只说天气用 \"it's snowing and windy\"，别说 don't。"))
        XCTAssertEqual(short.hoverWords, ["caught", "blizzard", "snowing", "windy"], "it's and don't are small words too")
    }

    func testPunctuationStaysWithItsWordWhenALineBreaks() {
        let units = CoachWords.units(of: "用 “heavy snow”，只想").map { $0.map(\.text).joined() }
        XCTAssertEqual(units, ["用", " ", "“heavy", " ", "snow”，", "只", "想"])
    }

    func testChangesArePlacedInTheOrderOfTheSentence() {
        let original = "Yesterday I go to the office because I has a very good question."
        let placed = CoachText.placements(of: [.init(from: "has", to: "had", why: ""), .init(from: "go", to: "went", why: ""),
                                               .init(from: "very", to: "", why: "")], in: original)
        XCTAssertEqual(placed.map(\.to), ["went", "had", ""])
        XCTAssertEqual(placed.map(\.range), [12 ..< 14, 39 ..< 42, 45 ..< 50], "a word taken out takes one space with it")
        XCTAssertEqual(placed.map(\.from), ["go", "has", "very "])
    }
}
