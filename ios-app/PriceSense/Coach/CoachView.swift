//
// CoachView.swift
//
// The Coach screen: what the price you just guessed means for a (synthetic) S-Pankki customer's own money.
// Which of the three baskets it belongs to, how many weeks of everyday leaks it is, how much of the spare money,
// what cutting leaks would free, and a box to ask the coach anything. All numbers come from the server.
//

import SwiftUI

struct CoachView: View {
  var money: MoneyViewModel
  var lookID: String
  @Environment(\.dismiss) private var dismiss
  @State private var question = ""
  @FocusState private var asking: Bool

  private let suggestions = ["Can I afford it?", "What if I cut everyday leaks by 20%?", "What kind of spender am I?"]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          personaPicker
          if let reply = money.reply {
            thing(reply.context)
            basketCard(reply.context)
            stats(reply.context)
            Text(reply.context.summary)
              .font(.system(size: 16, weight: .medium))
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("coach_summary")
            monthBar(reply.profile)
            whatIf(reply.context, reply.profile)
            askBox
          } else if money.isLoading {
            HStack(spacing: 10) { ProgressView(); Text("Working out what it means for you…").foregroundStyle(.secondary) }
          } else if let error = money.loadError {
            Text(error).foregroundStyle(.red).font(.callout)
            Button("Try again") { Task { await money.show(lookID: lookID) } }
          }
          Text("Example data: a synthetic customer from the Junction 2026 S-Pankki challenge, not a real person. This is coaching, not financial advice.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
      }
      .navigationTitle("What it means for you")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Done") { dismiss() } }
      .task { await money.show(lookID: lookID) }
    }
    .accessibilityIdentifier("coach_screen")
  }

  // MARK: Persona

  private var personaPicker: some View {
    HStack {
      Text("Coaching").foregroundStyle(.secondary)
      Menu {
        ForEach(money.personas) { persona in
          Button("\(persona.title) · spare €\(persona.sparePerMonth)/mo") { Task { await money.choose(persona) } }
        }
      } label: {
        HStack(spacing: 4) {
          Text(money.persona?.title ?? "A typical young adult").fontWeight(.semibold)
          Image(systemName: "chevron.up.chevron.down").font(.caption)
        }
      }
      .disabled(money.personas.isEmpty)
      .accessibilityIdentifier("persona_menu")
      Spacer()
    }
    .font(.subheadline)
  }

  // MARK: The price

  private func thing(_ context: MoneyContext) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(context.name ?? "This").font(.title3.weight(.semibold))
      Text("\(Money.euros(context.priceEur)) · typical price\(context.kind == "car" ? "" : " (new)")")
        .font(.subheadline).foregroundStyle(.secondary)
      Text(context.verdictTitle)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(context.isGoodNews ? Color.green : context.verdict == "save-up" ? Color.orange : Color.red)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background((context.isGoodNews ? Color.green : context.verdict == "save-up" ? Color.orange : Color.red).opacity(0.15), in: Capsule())
        .padding(.top, 4)
        .accessibilityIdentifier("coach_verdict")
    }
  }

  private func basketCard(_ context: MoneyContext) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Circle().fill(basketColor(context.basket.id)).frame(width: 14, height: 14).padding(.top, 4)
      VStack(alignment: .leading, spacing: 3) {
        Text(context.basket.title).font(.headline)
        if let why = context.basket.why { Text(why).font(.subheadline).foregroundStyle(.secondary) }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(basketColor(context.basket.id).opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("basket_card")
  }

  private func stats(_ context: MoneyContext) -> some View {
    HStack(spacing: 10) {
      tile(title: "Of everyday leaks", value: context.leaksTime?.replacingOccurrences(of: "about ", with: "~") ?? "–")
      tile(title: "Of spare money", value: context.pctOfSpareMoney.map { "\($0)%" } ?? "no room")
      tile(title: "To save up", value: context.saveTime?.replacingOccurrences(of: "about ", with: "~") ?? "–")
    }
  }

  private func tile(title: String, value: String) -> some View {
    VStack(spacing: 4) {
      Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
      Text(title).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  // MARK: The month

  private func monthBar(_ profile: MoneyProfile) -> some View {
    let m = profile.perMonth
    let parts: [(String, Int, Color)] = [
      ("Regular must-pays", m.regular, basketColor("regular")),
      ("Lumpy must-pays", m.irregular, basketColor("irregular")),
      ("Everyday leaks", m.leaks, basketColor("leaks")),
      ("Moved to savings", m.saved, .green),
      ("Left over", max(0, m.spare), .mint),
    ].filter { $0.1 > 0 }
    let total = Double(max(1, parts.reduce(0) { $0 + $1.1 }))
    return VStack(alignment: .leading, spacing: 8) {
      Text("Your typical month: \(Money.euros(m.income)) in").font(.headline)
      GeometryReader { geo in
        HStack(spacing: 2) {
          ForEach(parts.indices, id: \.self) { i in
            RoundedRectangle(cornerRadius: 4).fill(parts[i].2).frame(width: max(2, geo.size.width * Double(parts[i].1) / total))
          }
        }
      }
      .frame(height: 22)
      ForEach(parts.indices, id: \.self) { i in
        HStack(spacing: 8) {
          Circle().fill(parts[i].2).frame(width: 9, height: 9)
          Text(parts[i].0).font(.subheadline)
          Spacer()
          Text(Money.euros(parts[i].1)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
      if m.spare < 0 {
        Text("A typical month spends \(Money.euros(-m.spare)) more than comes in.").font(.subheadline).foregroundStyle(.red)
      }
      if let peers = profile.peers, let pct = peers.leaksVsPeersPct {
        Text(pct == 0 ? "Everyday leaks are about the same as the median in your age group (\(peers.ageBand))."
          : "Everyday leaks are \(abs(pct))% \(pct > 0 ? "above" : "below") the median in your age group (\(peers.ageBand), \(peers.n) people).")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func whatIf(_ context: MoneyContext, _ profile: MoneyProfile) -> some View {
    let cut = context.whatIfCutLeaks20
    return VStack(alignment: .leading, spacing: 4) {
      Text("What if you cut everyday leaks by \(Int(cut.cutPct))%?").font(.headline)
      Text("That frees \(Money.euros(cut.savingPerMonth)) a month, \(Money.euros(cut.savingPerYear)) a year."
        + (cut.monthsToAfford.map { " You could afford this in about \(String(format: "%.1f", $0)) months." } ?? ""))
        .font(.subheadline).foregroundStyle(.secondary)
    }
  }

  // MARK: Ask

  private var askBox: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Ask the coach").font(.headline)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack {
          ForEach(suggestions, id: \.self) { text in
            Button(text) { question = text; submit() }
              .font(.footnote)
              .padding(.horizontal, 12).padding(.vertical, 7)
              .background(Color.accentColor.opacity(0.15), in: Capsule())
          }
        }
      }
      HStack {
        TextField("Ask anything about this money…", text: $question, axis: .vertical)
          .focused($asking)
          .textFieldStyle(.roundedBorder)
          .submitLabel(.send)
          .onSubmit(submit)
          .accessibilityIdentifier("coach_question")
        Button("Ask", action: submit)
          .buttonStyle(.borderedProminent)
          .disabled(money.isAsking || question.trimmingCharacters(in: .whitespaces).count < 2)
          .accessibilityIdentifier("coach_ask_button")
      }
      if money.isAsking {
        HStack(spacing: 8) { ProgressView(); Text("Thinking…").foregroundStyle(.secondary) }
      }
      if let error = money.askError { Text(error).font(.callout).foregroundStyle(.red) }
      if let answer = money.coachReply {
        VStack(alignment: .leading, spacing: 6) {
          if let asked = money.askedQuestion { Text(asked).font(.footnote).foregroundStyle(.secondary) }
          Text(answer.answer).font(.body).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("coach_answer")
          Text(answer.source == "nemotron" ? "Explained by Nemotron from the numbers above" : "Computed answer (\(answer.note ?? "the model was unavailable"))")
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
    }
  }

  private func submit() {
    asking = false
    let text = question
    Task { await money.ask(text) }
  }

  private func basketColor(_ id: String) -> Color {
    switch id {
    case "regular": return .blue
    case "irregular": return .purple
    default: return .orange
    }
  }
}
