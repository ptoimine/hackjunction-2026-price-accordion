//
// MoneyModels.swift
//
// What the server says about a customer's money (GET /money/personas, POST /money/context, POST /coach).
// Every number is computed in Python on the server (CLAUDE.md rule 2); the app only shows it. The customers
// are synthetic (Junction 2026 S-Pankki challenge data), never real people.
//

import Foundation

struct Persona: Decodable, Sendable, Equatable, Identifiable {
  var slot: String  // tight | typical | comfortable
  var label: String
  var customerId: String
  var age: Int
  var sparePerMonth: Int
  var id: String { customerId }
  var title: String { "\(label), \(age)" }
}

struct PersonaList: Decodable, Sendable { var personas: [Persona] }

struct Basket: Decodable, Sendable, Equatable {
  var id: String  // regular | irregular | leaks
  var title: String
  var why: String?
}

struct MonthlyMoney: Decodable, Sendable, Equatable {
  var income: Int
  var regular: Int
  var irregular: Int
  var leaks: Int
  var saved: Int
  var spare: Int
}

struct WeeklyMoney: Decodable, Sendable, Equatable {
  var leaks: Int
  var spare: Int
}

struct Peers: Decodable, Sendable, Equatable {
  var ageBand: String
  var leaksMedianPerMonth: Int
  var leaksVsPeersPct: Int?
  var n: Int
}

struct MoneyProfile: Decodable, Sendable, Equatable {
  var customerId: String
  var age: Int
  var ageBand: String
  var perMonth: MonthlyMoney
  var perWeek: WeeklyMoney
  var balanceEur: Int
  var peers: Peers?
  var notes: [String]
}

struct WhatIf: Decodable, Sendable, Equatable {
  var cutPct: Double
  var savingPerMonth: Int
  var savingPerYear: Int
  var monthsToAfford: Double?
}

struct MoneyContext: Decodable, Sendable, Equatable {
  var priceEur: Int
  var name: String?
  var kind: String
  var basket: Basket
  var leaksTime: String?  // "about 4 weeks of everyday leaks", worded by the server
  var saveTime: String?
  var pctOfMonthlyIncome: Int?
  var pctOfSpareMoney: Int?
  var monthsToSave: Double?
  var verdict: String  // fits-this-week | fits-this-month | save-up | out-of-reach | no-room
  var balanceAfterPurchaseEur: Int
  var wouldOverdraw: Bool
  var whatIfCutLeaks20: WhatIf
  var summary: String

  /// A short, plain label for the verdict.
  var verdictTitle: String {
    switch verdict {
    case "fits-this-week": return "Fits this week"
    case "fits-this-month": return "Fits this month"
    case "save-up": return "Save up for it"
    case "out-of-reach": return "Out of reach for now"
    default: return "No room in a typical month"
    }
  }

  var isGoodNews: Bool { verdict == "fits-this-week" || verdict == "fits-this-month" }
}

struct MoneyContextReply: Decodable, Sendable, Equatable {
  var customerId: String
  var profile: MoneyProfile
  var context: MoneyContext

  static func decode(_ data: Data) -> MoneyContextReply? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode(MoneyContextReply.self, from: data)
  }
}

struct CoachReply: Decodable, Sendable, Equatable {
  var answer: String
  var source: String  // nemotron | fallback
  var basket: Basket?
  var note: String?
}
