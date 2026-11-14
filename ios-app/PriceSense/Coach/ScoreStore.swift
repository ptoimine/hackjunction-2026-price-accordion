//
// ScoreStore.swift
//
// The price-sense score over time (CLAUDE.md section 3): every finished guess is kept on the phone, and the
// Score screen shows how close the guesses are, per kind of thing, and whether they are getting better.
// Nothing leaves the device; the numbers themselves (score, gap) were computed by the server.
//

import Foundation
import Observation

struct ScoreEntry: Codable, Identifiable, Equatable, Sendable {
  var id: String  // the look id: one entry per look
  var date: Date
  var kind: String
  var name: String
  var guessEur: Int
  var medianEur: Int
  var gapPct: Double
  var score: Int
  var verdict: String  // close | high | low
  var inRange: Bool

  var hit: Bool { inRange || verdict == "close" }
}

struct ScoreSummary: Equatable, Sendable {
  struct KindScore: Equatable, Sendable {
    var kind: String
    var count: Int
    var average: Int
    var title: String { ScoreSummary.title(for: kind) }
  }

  var count: Int
  var average: Int
  var best: Int
  var hitRatePct: Int
  var byKind: [KindScore]
  /// Average of the latest three guesses minus the three before them; nil with fewer than six guesses.
  var trend: Int?
  /// Newest guesses in a row that landed inside the real range (or within 5 %).
  var streak: Int

  init(_ entries: [ScoreEntry]) {
    let ordered = entries.sorted { $0.date < $1.date }
    count = ordered.count
    average = Self.mean(ordered.map(\.score))
    best = ordered.map(\.score).max() ?? 0
    hitRatePct = ordered.isEmpty ? 0 : Int((100 * Double(ordered.filter(\.hit).count) / Double(ordered.count)).rounded())
    byKind = Dictionary(grouping: ordered, by: \.kind)
      .map { KindScore(kind: $0.key, count: $0.value.count, average: Self.mean($0.value.map(\.score))) }
      .sorted { ($0.count, $1.kind) > ($1.count, $0.kind) }
    if ordered.count >= 6 {
      let latest = ordered.suffix(3).map(\.score)
      let before = ordered.dropLast(3).suffix(3).map(\.score)
      trend = Self.mean(latest) - Self.mean(before)
    } else {
      trend = nil
    }
    streak = ordered.reversed().prefix(while: \.hit).count
  }

  static func mean(_ values: [Int]) -> Int {
    values.isEmpty ? 0 : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
  }

  static func title(for kind: String) -> String {
    switch kind {
    case "car": return "Cars"
    case "headphones": return "Headphones"
    case "phone": return "Phones"
    case "laptop": return "Laptops"
    default: return "Other things"
    }
  }
}

@Observable
@MainActor
final class ScoreStore {
  static let shared = ScoreStore()
  private static let key = "score.entries.v1"
  private static let limit = 500

  private(set) var entries: [ScoreEntry]

  init(entries: [ScoreEntry]? = nil) {
    if let entries {
      self.entries = entries
    } else if let data = UserDefaults.standard.data(forKey: Self.key),
      let stored = try? JSONDecoder().decode([ScoreEntry].self, from: data)
    {
      self.entries = stored
    } else {
      self.entries = []
    }
  }

  var summary: ScoreSummary { ScoreSummary(entries) }

  /// Keep a finished guess once (a look is never recorded twice).
  func record(_ entry: ScoreEntry) {
    guard !entries.contains(where: { $0.id == entry.id }) else { return }
    entries.append(entry)
    if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    save()
  }

  func clear() {
    entries = []
    save()
  }

  private func save() {
    if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }
  }
}
