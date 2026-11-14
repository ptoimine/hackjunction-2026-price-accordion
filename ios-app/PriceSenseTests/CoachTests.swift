//
// CoachTests.swift
//
// The money coach and the Score history: decoding what the server computes, the score summary maths, and
// (with the server running) the whole path from a finished guess to the coach's answer.
//

@testable import PriceSense
import Foundation
import SwiftUI
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

final class MoneyModelsTests: XCTestCase {
  static let sample = """
    {"customer_id":"CUST03934","profile":{"customer_id":"CUST03934","age":29,"age_band":"25-34","months_used":12,"currency":"EUR",
      "per_month":{"income":1792,"regular":1480,"irregular":17,"leaks":137,"saved":0,"spare":158},
      "baskets":[],"per_week":{"leaks":32,"spare":36},"balance_eur":1270,"share_of_days_overdrawn_pct":3,
      "peers":{"age_band":"25-34","leaks_median_per_month":250,"leaks_vs_peers_pct":-45,"n":658},
      "notes":["synthetic data"]},
     "context":{"price_eur":299,"name":"Sony WH-1000XM5","kind":"headphones","price_basis":"new",
      "basket":{"id":"leaks","title":"Everyday leaks","why":"a want more than a need"},
      "weeks_of_leaks":9.3,"leaks_time":"about 2 months","save_time":"about 2 months","pct_of_monthly_income":17,
      "pct_of_spare_money":189,"months_to_save":1.9,"verdict":"save-up","balance_after_purchase_eur":971,"would_overdraw":false,
      "what_if_cut_leaks_20":{"cut_pct":20,"saving_per_month":27,"saving_per_year":329,"months_to_afford":1.6},
      "summary":"€299 is about 2 months of what you spend on everyday leaks."}}
    """

  func testDecodesWhatAPriceMeansForACustomer() throws {
    let reply = try XCTUnwrap(MoneyContextReply.decode(Data(Self.sample.utf8)))
    XCTAssertEqual(reply.customerId, "CUST03934")
    XCTAssertEqual(reply.profile.perMonth.spare, 158)
    XCTAssertEqual(reply.profile.peers?.leaksVsPeersPct, -45)
    let c = reply.context
    XCTAssertEqual(c.basket.title, "Everyday leaks")
    XCTAssertEqual(c.leaksTime, "about 2 months")
    XCTAssertEqual(c.pctOfSpareMoney, 189)
    XCTAssertEqual(c.whatIfCutLeaks20.savingPerYear, 329)
    XCTAssertEqual(c.whatIfCutLeaks20.monthsToAfford, 1.6)
    XCTAssertEqual(c.verdictTitle, "Save up for it")
    XCTAssertFalse(c.isGoodNews)
    XCTAssertTrue(c.summary.hasPrefix("€299"))
  }

  func testNoSpareMoneyDecodesWithMissingTimes() throws {
    let tight = Self.sample.replacingOccurrences(of: "\"save_time\":\"about 2 months\"", with: "\"save_time\":null")
      .replacingOccurrences(of: "\"pct_of_spare_money\":189", with: "\"pct_of_spare_money\":null")
      .replacingOccurrences(of: "\"verdict\":\"save-up\"", with: "\"verdict\":\"no-room\"")
    let c = try XCTUnwrap(MoneyContextReply.decode(Data(tight.utf8))).context
    XCTAssertNil(c.saveTime)
    XCTAssertNil(c.pctOfSpareMoney)
    XCTAssertEqual(c.verdictTitle, "No room in a typical month")
  }

  func testPersonaAndCoachReplyDecode() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let personas = try decoder.decode(PersonaList.self, from: Data(#"{"personas":[{"slot":"typical","label":"Typical","customer_id":"CUST03934","age":29,"spare_per_month":158}]}"#.utf8))
    XCTAssertEqual(personas.personas.first?.title, "Typical, 29")
    let reply = try decoder.decode(CoachReply.self, from: Data(#"{"answer":"Save up.","source":"fallback","basket":null,"note":"the model was unavailable","numbers":{}}"#.utf8))
    XCTAssertEqual(reply.source, "fallback")
    XCTAssertNil(reply.basket)
  }

  func testServerErrorMessagesAreReadable() {
    XCTAssertEqual(MoneyClient.message(from: Data(#"{"detail":"unknown customer"}"#.utf8), status: 404), "unknown customer")
    XCTAssertEqual(MoneyClient.message(from: Data(#"{"detail":{"status":"unavailable","message":"the money data is not built"}}"#.utf8), status: 503), "the money data is not built")
    XCTAssertEqual(MoneyClient.message(from: Data("oops".utf8), status: 502), "The server answered HTTP 502.")
  }
}

final class ScoreTests: XCTestCase {
  private func entry(_ i: Int, kind: String = "car", score: Int, inRange: Bool = false, verdict: String = "low") -> ScoreEntry {
    ScoreEntry(id: "look\(i)", date: Date(timeIntervalSince1970: Double(i) * 100), kind: kind, name: "thing \(i)", guessEur: 100, medianEur: 120, gapPct: -10, score: score, verdict: verdict, inRange: inRange)
  }

  func testEmptyHistory() {
    let s = ScoreSummary([])
    XCTAssertEqual(s.count, 0)
    XCTAssertEqual(s.average, 0)
    XCTAssertNil(s.trend)
    XCTAssertEqual(s.streak, 0)
    XCTAssertTrue(s.byKind.isEmpty)
  }

  func testAveragesPerKindAndHitRate() {
    let s = ScoreSummary([
      entry(1, kind: "car", score: 60), entry(2, kind: "car", score: 80, inRange: true),
      entry(3, kind: "phone", score: 40), entry(4, kind: "item", score: 95, verdict: "close"),
    ])
    XCTAssertEqual(s.count, 4)
    XCTAssertEqual(s.average, 69)  // (60 + 80 + 40 + 95) / 4 = 68.75
    XCTAssertEqual(s.best, 95)
    XCTAssertEqual(s.hitRatePct, 50)  // the in-range one and the "close" one
    XCTAssertEqual(s.byKind.first, ScoreSummary.KindScore(kind: "car", count: 2, average: 70))
    XCTAssertEqual(s.byKind.map(\.title).sorted(), ["Cars", "Other things", "Phones"])
  }

  func testTrendNeedsSixGuessesAndComparesTheLatestThree() {
    XCTAssertNil(ScoreSummary((1...5).map { entry($0, score: 50) }).trend)
    let better = ScoreSummary([40, 40, 40, 70, 70, 70].enumerated().map { entry($0.offset + 1, score: $0.element) })
    XCTAssertEqual(better.trend, 30)
    let worse = ScoreSummary([90, 90, 90, 60, 60, 60].enumerated().map { entry($0.offset + 1, score: $0.element) })
    XCTAssertEqual(worse.trend, -30)
  }

  func testStreakCountsTheNewestHitsInARow() {
    let s = ScoreSummary([
      entry(1, score: 50, inRange: true), entry(2, score: 30), entry(3, score: 80, inRange: true),
      entry(4, score: 90, verdict: "close"), entry(5, score: 85, inRange: true),
    ])
    XCTAssertEqual(s.streak, 3)  // 5, 4 and 3; the miss at 2 breaks it
  }

  @MainActor
  func testStoreKeepsEachLookOnceAndCanBeCleared() {
    let store = ScoreStore(entries: [])
    store.record(entry(1, score: 50))
    store.record(entry(1, score: 99))  // the same look again: ignored
    store.record(entry(2, score: 70))
    XCTAssertEqual(store.entries.count, 2)
    XCTAssertEqual(store.summary.average, 60)
    store.clear()
    XCTAssertTrue(store.entries.isEmpty)
    UserDefaults.standard.removeObject(forKey: "score.entries.v1")  // this store wrote through to the real key
  }
}

@MainActor
final class CoachScreenshotTests: XCTestCase {
  private func render<V: View>(_ view: V, name: String, height: CGFloat) {
    guard let dir = ProcessInfo.processInfo.environment["HUD_OUT"] else { return }
    let renderer = ImageRenderer(content: view.frame(width: 390, height: height).background(Color(uiColor: .systemBackground)))
    renderer.scale = 2
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? renderer.uiImage?.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
  }

  func testRenderCoachAndScoreScreens() throws {
    let json = Data(MoneyModelsTests.sample.utf8)
    let reply = try XCTUnwrap(MoneyContextReply.decode(json))
    let personas = [Persona(slot: "tight", label: "Tight month", customerId: "A", age: 30, sparePerMonth: -70), Persona(slot: "typical", label: "Typical", customerId: "CUST03934", age: 29, sparePerMonth: 158)]
    let answer = CoachReply(answer: "The Sony WH-1000XM5 costs €299 and sits in Everyday leaks, a want more than a need. With €158 spare a month it is a save-up purchase, about 2 months. A kind next step is to set aside part of your spare money each month.", source: "nemotron", basket: reply.context.basket, note: nil)
    let money = MoneyViewModel(preview: reply, personas: personas, coach: answer, asked: "Can I afford these headphones?")
    render(CoachView(money: money, lookID: "x"), name: "coach", height: 1500)

    let entries = (1...9).map { i in
      ScoreEntry(id: "l\(i)", date: Date(timeIntervalSince1970: Double(i) * 1000), kind: ["car", "headphones", "phone", "item"][i % 4], name: ["Honda HR-V", "Sony WH-1000XM5", "iPhone 15", "wooden dining chair"][i % 4], guessEur: 100 * i, medianEur: 110 * i, gapPct: -9, score: 40 + i * 6, verdict: i % 3 == 0 ? "close" : "low", inRange: i % 2 == 0)
    }
    render(ScoreView(store: ScoreStore(entries: entries)), name: "score", height: 900)
    render(ScoreView(store: ScoreStore(entries: [])), name: "score-empty", height: 500)
  }
}
