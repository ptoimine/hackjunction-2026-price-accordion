//
// CoachPreviews.swift
//
// Debug-only sample data so the Coach and Score screens can be looked at without a server or a look
// (ladybug menu -> "Coach and Score previews").
//

#if DEBUG

import Foundation

@MainActor
enum CoachPreviews {
  static let sample = """
    {"customer_id":"CUST03934","profile":{"customer_id":"CUST03934","age":29,"age_band":"25-34","months_used":12,"currency":"EUR",
      "per_month":{"income":1792,"regular":1480,"irregular":17,"leaks":137,"saved":0,"spare":158},
      "baskets":[],"per_week":{"leaks":32,"spare":36},"balance_eur":1270,"share_of_days_overdrawn_pct":3,
      "peers":{"age_band":"25-34","leaks_median_per_month":250,"leaks_vs_peers_pct":-45,"n":658},
      "notes":["synthetic data"]},
     "context":{"price_eur":299,"name":"Sony WH-1000XM5","kind":"headphones","price_basis":"new",
      "basket":{"id":"leaks","title":"Everyday leaks","why":"a want more than a need: this is the money that slips through your fingers"},
      "weeks_of_leaks":9.3,"leaks_time":"about 2 months","save_time":"about 2 months","pct_of_monthly_income":17,
      "pct_of_spare_money":189,"months_to_save":1.9,"verdict":"save-up","balance_after_purchase_eur":971,"would_overdraw":false,
      "what_if_cut_leaks_20":{"cut_pct":20,"saving_per_month":27,"saving_per_year":329,"months_to_afford":1.6},
      "summary":"€299 is about 2 months of what you spend on everyday leaks. With €158 spare a month, that is about 2 months of saving. Cutting everyday leaks by 20% would free €27 a month, so it would take about 2 months."}}
    """

  static var money: MoneyViewModel {
    let reply = MoneyContextReply.decode(Data(sample.utf8))!
    let personas = [
      Persona(slot: "tight", label: "Tight month", customerId: "CUST04551", age: 30, sparePerMonth: -70),
      Persona(slot: "typical", label: "Typical", customerId: "CUST03934", age: 29, sparePerMonth: 158),
      Persona(slot: "comfortable", label: "Comfortable", customerId: "CUST02166", age: 22, sparePerMonth: 599),
    ]
    let answer = CoachReply(
      answer: "The Sony WH-1000XM5 costs €299 and sits in Everyday leaks, a want more than a need. With €158 spare a month it is a save-up purchase, about 2 months. A kind next step is to set aside part of your spare money each month.",
      source: "nemotron", basket: reply.context.basket, note: nil)
    return MoneyViewModel(preview: reply, personas: personas, coach: answer, asked: "Can I afford these headphones?")
  }

  static var scoreStore: ScoreStore {
    let names = ["Honda HR-V", "Sony WH-1000XM5", "iPhone 15", "wooden dining chair"]
    let kinds = ["car", "headphones", "phone", "item"]
    return ScoreStore(entries: (1...9).map { i in
      ScoreEntry(
        id: "p\(i)", date: Date(timeIntervalSince1970: Double(i) * 1000), kind: kinds[i % 4], name: names[i % 4],
        guessEur: 100 * i, medianEur: 110 * i, gapPct: -9, score: 40 + i * 6, verdict: i % 3 == 0 ? "close" : "low", inRange: i % 2 == 0)
    })
  }
}

#endif
