//
// ScoreView.swift
//
// The Score screen: how close your price guesses are, per kind of thing, and whether you are getting better.
//

import SwiftUI

struct ScoreView: View {
  var store: ScoreStore = .shared
  @Environment(\.dismiss) private var dismiss
  @State private var confirmClear = false

  var body: some View {
    NavigationStack {
      let summary = store.summary
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if summary.count == 0 {
            VStack(spacing: 8) {
              Image(systemName: "scope").font(.system(size: 40)).foregroundStyle(.secondary)
              Text("No guesses yet").font(.headline)
              Text("Look at something, guess its price first, and your price sense shows up here.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
          } else {
            headline(summary)
            kinds(summary)
            recent
          }
        }
        .padding(16)
      }
      .navigationTitle("Your price sense")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if summary.count > 0 { Button("Clear", role: .destructive) { confirmClear = true } }
        }
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
      .confirmationDialog("Delete all your guesses from this phone?", isPresented: $confirmClear, titleVisibility: .visible) {
        Button("Delete", role: .destructive) { store.clear() }
      }
    }
    .accessibilityIdentifier("score_screen")
  }

  private func headline(_ summary: ScoreSummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(summary.average)").font(.system(size: 64, weight: .bold, design: .rounded))
          .accessibilityIdentifier("score_average")
        Text("average of 100").foregroundStyle(.secondary)
      }
      if let trend = summary.trend {
        Label(trend > 0 ? "Getting better: +\(trend) over your last three guesses" : trend < 0 ? "Slipping: \(trend) over your last three guesses" : "Holding steady",
          systemImage: trend > 0 ? "arrow.up.right" : trend < 0 ? "arrow.down.right" : "arrow.right")
          .foregroundStyle(trend > 0 ? Color.green : trend < 0 ? Color.orange : Color.secondary)
          .font(.subheadline.weight(.medium))
      }
      HStack(spacing: 10) {
        stat("\(summary.count)", "guesses")
        stat("\(summary.hitRatePct)%", "inside the range")
        stat("\(summary.streak)", "in a row")
        stat("\(summary.best)", "best")
      }
    }
  }

  private func stat(_ value: String, _ title: String) -> some View {
    VStack(spacing: 3) {
      Text(value).font(.system(size: 20, weight: .bold, design: .rounded))
      Text(title).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity).padding(.vertical, 10)
    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func kinds(_ summary: ScoreSummary) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("By kind of thing").font(.headline)
      ForEach(summary.byKind, id: \.kind) { item in
        HStack(spacing: 10) {
          Text(item.title).frame(width: 110, alignment: .leading).font(.subheadline)
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule().fill(Color.primary.opacity(0.1))
              Capsule().fill(color(item.average)).frame(width: max(8, geo.size.width * Double(item.average) / 100))
            }
          }
          .frame(height: 10)
          Text("\(item.average)").font(.subheadline.monospacedDigit()).frame(width: 30, alignment: .trailing)
          Text("×\(item.count)").font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
        }
      }
    }
  }

  private var recent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Recent guesses").font(.headline)
      ForEach(store.entries.sorted { $0.date > $1.date }.prefix(12)) { entry in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text("You \(Money.euros(entry.guessEur)) · real \(Money.euros(entry.medianEur)) · \(entry.hit ? "inside the range" : entry.verdict == "high" ? "too high" : "too low")")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Text("\(entry.score)").font(.headline.monospacedDigit()).foregroundStyle(color(entry.score))
        }
        .padding(.vertical, 2)
      }
    }
  }

  private func color(_ score: Int) -> Color { score >= 75 ? .green : score >= 50 ? .yellow : .orange }
}
