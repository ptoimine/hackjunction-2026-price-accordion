//
// LookModels.swift
//
// What the server says about a look (POST /look, GET /look/{id}), decoded for the UI. Every
// number shown to the user comes from the server (Python does the arithmetic, CLAUDE.md rule 2);
// the app only draws it. Fields are optional where the server may leave them out.
//

import Foundation

struct LookSnapshot: Decodable, Sendable, Equatable {
  struct Identification: Decodable, Sendable, Equatable {
    var kind: String  // car | headphones | phone | laptop | item | building | menu | other
    var make: String?
    var model: String?
    var variant: String?  // storage or screen size, products only
    var yearRange: [Int]?
    var confidence: Double
    var description: String

    /// Kinds the server can put a price on.
    static let priceableKinds = ["car", "headphones", "phone", "laptop", "item"]
    /// Cars, headphones, phones and laptops need a make and model; any other item only needs a name.
    var isPriceable: Bool {
      guard Self.priceableKinds.contains(kind), model != nil else { return false }
      return kind == "item" || make != nil
    }

    /// "Honda HR-V", or the plain description when there is no make and model.
    var title: String {
      let name = [make, model].compactMap { $0 }.joined(separator: " ")
      return name.isEmpty ? description : name
    }

    /// "2016–2022" (or "2018" when the range is one year).
    var years: String? {
      guard let range = yearRange, range.count == 2 else { return nil }
      return range[0] == range[1] ? "\(range[0])" : "\(range[0])–\(range[1])"
    }
  }

  struct PriceRange: Decodable, Sendable, Equatable {
    var low: Int
    var median: Int
    var high: Int
  }

  struct Source: Decodable, Sendable, Equatable {
    var domain: String
    var status: String  // reading | ok | failed | timeout
    var nListings: Int?
  }

  struct Price: Decodable, Sendable, Equatable {
    var status: String  // searching | reading | done | insufficient | failed | skipped | unavailable
    var reason: String?
    var range: PriceRange?
    /// "new" normally; "used" when the model is only sold used or refurbished now (products).
    var priceBasis: String?
    /// Products: the used / refurbished range, shown as a second line next to the new price.
    var usedRange: PriceRange?
    var sources: [Source]?
    var sourcesTotal: Int?
    var sourcesDone: Int?
    var nListings: Int?
    var notes: [String]?
    var fetchedAt: String?
    var cached: Bool?

    var isPending: Bool { status == "searching" || status == "reading" }
    var isDone: Bool { status == "done" }
    /// Nothing to guess against (not a car, or the server has no listing source).
    var hasNoPrice: Bool { status == "skipped" || status == "unavailable" }
  }

  struct GuessResult: Decodable, Sendable, Equatable {
    var guessEur: Int
    var gapEur: Int
    var gapPct: Double
    var verdict: String  // close | high | low
    var inRange: Bool
    var score: Int
    var summary: String
  }

  struct Guess: Decodable, Sendable, Equatable {
    var guessEur: Int
    var result: GuessResult?  // null until the price is final
  }

  var lookId: String
  var identification: Identification
  var confirmed: Bool?
  var price: Price
  var guess: Guess?

  static func decode(_ data: Data) -> LookSnapshot? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode(LookSnapshot.self, from: data)
  }
}

enum Money {
  /// "€18,000" / "18 000 €" depending on the device's region, whole euros.
  static func euros(_ value: Int) -> String {
    value.formatted(.currency(code: "EUR").precision(.fractionLength(0)))
  }
}
