//
// AccordionPlayground.swift
//
// DEBUG only: drives the accordion with a scripted run (the real HR-V lookup, recorded), with
// no server, camera or Context.dev credits. Open it from the ladybug menu. Useful for tuning
// the animation and for screenshots.
//

#if DEBUG

import SwiftUI

struct AccordionPlayground: View {
  @State private var guess: Double = 18_000
  @State private var step = 0
  @State private var running = false

  /// One recorded run: the range narrowing as 6 sites answered (see price.py live test).
  private static let script: [(done: Int, adverts: Int, range: (Int, Int, Int)?)] = [
    (0, 0, nil),
    (1, 3, (13_490, 15_700, 15_800)),
    (2, 9, (11_300, 15_700, 19_590)),
    (3, 14, (13_520, 15_740, 17_630)),
    (4, 20, (13_270, 15_780, 18_140)),
    (5, 29, (10_590, 14_900, 17_880)),
    (6, 35, (12_980, 15_700, 18_860)),
  ]

  private var snapshot: LookSnapshot {
    let entry = Self.script[step]
    let finished = step == Self.script.count - 1
    let range = entry.range.map { LookSnapshot.PriceRange(low: $0.0, median: $0.1, high: $0.2) }
    let price = LookSnapshot.Price(
      status: finished ? "done" : (step == 0 ? "searching" : "reading"),
      range: range,
      sources: (0..<6).map { LookSnapshot.Source(domain: "site\($0 + 1).fi", status: $0 < entry.done ? "ok" : "reading", nListings: 6) },
      sourcesTotal: 6, sourcesDone: entry.done, nListings: entry.adverts,
      notes: finished ? [] : nil,
      fetchedAt: ISO8601DateFormatter().string(from: Date()), cached: false)
    var guessValue: LookSnapshot.Guess?
    if finished, let range {
      guessValue = LookSnapshot.Guess(guessEur: Int(guess), result: Self.compare(Int(guess), range))
    }
    return LookSnapshot(
      lookId: "playground",
      identification: .init(kind: "car", make: "Honda", model: "HR-V", yearRange: [2016, 2022], confidence: 0.85, description: "A grey SUV."),
      price: price, guess: guessValue)
  }

  var body: some View {
    ZStack {
      LinearGradient(colors: [.black, Color(white: 0.18)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
      VStack(spacing: 18) {
        Text("Accordion playground").font(.headline).foregroundStyle(.white)
        AccordionSection(snapshot: snapshot, guess: Int(guess))
          .padding(16)
          .background(.ultraThinMaterial)
          .environment(\.colorScheme, .dark)
          .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
          .padding(.horizontal, 16)

        VStack(alignment: .leading) {
          Text("Guess: \(Money.euros(Int(guess)))").foregroundStyle(.white)
          Slider(value: $guess, in: 3_000...60_000, step: 500)
        }
        .padding(.horizontal, 24)

        HStack(spacing: 12) {
          Button(running ? "Playing…" : "Play the lookup") { play() }
            .buttonStyle(.borderedProminent).disabled(running)
          Button("Reset") { withAnimation(.spring(response: 0.8, dampingFraction: 0.82)) { step = 0 } }
            .buttonStyle(.bordered).disabled(running)
          Button("Skip to end") { withAnimation(.spring(response: 0.8, dampingFraction: 0.82)) { step = Self.script.count - 1 } }
            .buttonStyle(.bordered).disabled(running)
        }
        Spacer()
      }
      .padding(.top, 24)
    }
    .navigationBarTitleDisplayMode(.inline)
  }

  private func play() {
    running = true
    step = 0
    Task {
      for next in 1..<Self.script.count {
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        withAnimation(.spring(response: 0.8, dampingFraction: 0.82)) { step = next }
      }
      running = false
    }
  }

  /// A stand-in for the server's comparison (server/score.py), for this playground only.
  private static func compare(_ guess: Int, _ range: LookSnapshot.PriceRange) -> LookSnapshot.GuessResult {
    let median = Double(range.median)
    let gap = Double(guess) - median
    let pct = gap / median * 100
    let verdict = abs(pct) <= 5 ? "close" : (gap > 0 ? "high" : "low")
    let inRange = guess >= range.low && guess <= range.high
    let score = Int((100 * max(0, 1 - abs(log(Double(guess) / median)) / log(2))).rounded())
    let how =
      verdict == "close"
      ? "You were within 5% of the median. Close!"
      : (inRange
        ? "You were inside the real range, \(Int(abs(pct).rounded()))% \(gap > 0 ? "above" : "below") the median."
        : "You were \(Int(abs(pct).rounded()))% \(verdict).")
    return LookSnapshot.GuessResult(
      guessEur: guess, gapEur: Int(gap), gapPct: pct, verdict: verdict, inRange: inRange, score: score,
      summary: "You guessed \(Money.euros(guess)). The real range is \(Money.euros(range.low)) to \(Money.euros(range.high)), median \(Money.euros(range.median)). \(how)")
  }
}

#endif
