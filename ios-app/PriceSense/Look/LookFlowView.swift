//
// LookFlowView.swift
//
// The card above the camera for Look -> Guess -> Accordion:
//   identifying -> "what do you think it costs?" (guess first) -> the accordion squeezes to the
//   real price range while sources answer -> the gap, score and sources.
// The raw server JSON stays one tap away (the { } button) for debugging.
//

import SwiftUI

struct LookFlowView: View {
  var look: LookViewModel
  /// Opens the Coach screen for the finished look.
  var onCoach: (() -> Void)? = nil
  @State private var showRaw = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial)
    .environment(\.colorScheme, .dark)
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .accessibilityIdentifier("look_flow")
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text("Look")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
      Spacer(minLength: 0)
      if case .result = look.state {
        Button {
          showRaw.toggle()
        } label: {
          Image(systemName: "curlybraces")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.white.opacity(showRaw ? 1 : 0.55))
        }
        .accessibilityLabel("Show server reply")
        .accessibilityIdentifier("look_raw_toggle")
      }
      Button {
        look.dismiss()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 22))
          .foregroundStyle(Color.white.opacity(0.7))
      }
      .accessibilityLabel("Close")
      .accessibilityIdentifier("look_dismiss_button")
    }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch look.state {
    case .idle:
      EmptyView()
    case .preparing:
      progress("Blurring faces and cropping…")
    case .uploading:
      progress("Identifying…")
    case .failed(let message):
      Text(message)
        .font(.system(size: 14))
        .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("look_error")
    case .result(let result):
      if showRaw {
        rawJSON(result)
      } else if let snapshot = result.snapshot {
        flow(snapshot, result)
      } else {
        rawJSON(result)  // not a look at all (an error response): show it as it is
      }
    }
  }

  private func flow(_ snapshot: LookSnapshot, _ result: LookResult) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      IdentificationRow(identification: snapshot.identification, image: result.sentImage, facesBlurred: result.facesBlurred)

      if !look.identityConfirmed {
        ConfirmSection(look: look, identification: snapshot.identification)
      } else if snapshot.price.hasNoPrice {
        Text(snapshot.price.reason ?? "There is no price for this.")
          .font(.system(size: 14))
          .foregroundStyle(Color.white.opacity(0.85))
          .fixedSize(horizontal: false, vertical: true)
      } else if let guess = look.lockedGuess {
        AccordionSection(snapshot: snapshot, guess: guess, onCoach: onCoach)
      } else {
        GuessSection(look: look, isProduct: snapshot.identification.kind != "car")
      }
    }
  }

  private func progress(_ text: String) -> some View {
    HStack(spacing: 10) {
      ProgressView().tint(.white)
      Text(text).foregroundStyle(Color.white.opacity(0.8)).font(.system(size: 14))
    }
  }

  private func rawJSON(_ result: LookResult) -> some View {
    ScrollView {
      Text("HTTP \(result.reply.statusCode)\n" + result.reply.text)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(result.reply.isSuccess ? .white : Color(red: 1, green: 0.75, blue: 0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityIdentifier("look_reply_text")
    }
    .frame(maxHeight: 220)
  }
}

// MARK: - What was seen

private struct IdentificationRow: View {
  var identification: LookSnapshot.Identification
  var image: UIImage?
  var facesBlurred: Int

  var body: some View {
    HStack(spacing: 12) {
      if let image {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 48, height: 64)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .accessibilityLabel("The image that was sent")
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(identification.title)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(2)
        Text(detail)
          .font(.system(size: 13))
          .foregroundStyle(Color.white.opacity(0.65))
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("look_identification")
  }

  private var detail: String {
    var parts: [String] = []
    if let years = identification.years { parts.append(years) }
    if let variant = identification.variant { parts.append(variant) }
    parts.append("\(Int((identification.confidence * 100).rounded()))% sure")
    if facesBlurred > 0 { parts.append(facesBlurred == 1 ? "1 face blurred" : "\(facesBlurred) faces blurred") }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Is that it?

/// Before the guess: the model can be wrong, and the price depends on the exact model. The user
/// confirms, corrects, or (when the model could not tell) says what it is.
private struct ConfirmSection: View {
  var look: LookViewModel
  var identification: LookSnapshot.Identification
  @State private var editing = false

  var body: some View {
    if editing {
      EditIdentityForm(look: look, identification: identification) { editing = false }
    } else if identification.isPriceable {
      question
    } else {
      unknown
    }
  }

  private var question: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(identification.confidence < 0.5 ? "I'm not sure, but is this a \(identification.title)?" : "Is this a \(identification.title)?")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("confirm_question")
      Text("The price depends on the exact model, so check before you guess.")
        .font(.system(size: 13))
        .foregroundStyle(Color.white.opacity(0.65))
      if let error = look.confirmError {
        Text(error).font(.system(size: 13)).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
      }
      HStack(spacing: 10) {
        CustomButton(title: look.isConfirming ? "One moment…" : "Yes, that's it", style: .primary, isDisabled: look.isConfirming) {
          look.confirmIdentity()
        }
        .accessibilityIdentifier("confirm_yes_button")
        Button("No, change it") { editing = true }
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 56)
          .background(Color.white.opacity(0.15))
          .clipShape(RoundedRectangle(cornerRadius: 30))
          .accessibilityIdentifier("confirm_change_button")
      }
    }
  }

  private var unknown: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("I couldn't tell what this is.")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
      Text("I can price cars, headphones, phones and laptops. Tell me which one this is and I'll look it up.")
        .font(.system(size: 13))
        .foregroundStyle(Color.white.opacity(0.65))
        .fixedSize(horizontal: false, vertical: true)
      CustomButton(title: "Tell me what it is", style: .primary, isDisabled: false) { editing = true }
        .accessibilityIdentifier("tell_me_button")
    }
  }
}

private struct EditIdentityForm: View {
  var look: LookViewModel
  var onCancel: () -> Void
  @State private var kind: String
  @State private var make: String
  @State private var model: String
  @State private var variant: String
  @State private var yearFrom: String
  @State private var yearTo: String

  init(look: LookViewModel, identification: LookSnapshot.Identification, onCancel: @escaping () -> Void) {
    self.look = look
    self.onCancel = onCancel
    let priceable = LookSnapshot.Identification.priceableKinds.contains(identification.kind)
    _kind = State(initialValue: priceable ? identification.kind : "item")
    _make = State(initialValue: identification.make ?? "")
    _model = State(initialValue: identification.model ?? "")
    _variant = State(initialValue: identification.variant ?? "")
    _yearFrom = State(initialValue: identification.yearRange?.first.map(String.init) ?? "")
    _yearTo = State(initialValue: identification.yearRange?.last.map(String.init) ?? "")
  }

  private var input: IdentityInput? {
    let make = make.trimmingCharacters(in: .whitespaces), model = model.trimmingCharacters(in: .whitespaces)
    guard !model.isEmpty, kind == "item" || !make.isEmpty else { return nil }
    let size = variant.trimmingCharacters(in: .whitespaces)
    return IdentityInput(
      kind: kind, make: make, model: model, variant: kind == "car" || size.isEmpty ? nil : size,
      yearFrom: kind == "car" ? Int(yearFrom) : nil, yearTo: kind == "car" ? Int(yearTo) : nil)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("What is it?")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)

      Picker("Kind", selection: $kind) {
        Text("Car").tag("car")
        Text("Audio").tag("headphones")
        Text("Phone").tag("phone")
        Text("Laptop").tag("laptop")
        Text("Other").tag("item")
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("kind_picker")

      field(kind == "car" ? "Make, e.g. Honda" : (kind == "item" ? "Brand (optional)" : "Brand, e.g. Sony"), text: $make, id: "make_field")
      field(
        kind == "car" ? "Model, e.g. HR-V" : (kind == "item" ? "What is it? e.g. wooden dining chair" : "Model, e.g. WH-1000XM5"),
        text: $model, id: "model_field")
      if kind == "car" {
        HStack(spacing: 10) {
          field("Year from", text: $yearFrom, id: "year_from_field", numeric: true)
          field("to", text: $yearTo, id: "year_to_field", numeric: true)
        }
      } else {
        field("Size, e.g. 128GB (optional)", text: $variant, id: "variant_field")
      }

      if let error = look.confirmError {
        Text(error).font(.system(size: 13)).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
      }
      HStack(spacing: 10) {
        Button("Back") { onCancel() }
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 56)
          .background(Color.white.opacity(0.15))
          .clipShape(RoundedRectangle(cornerRadius: 30))
        CustomButton(title: look.isConfirming ? "One moment…" : "Use this", style: .primary, isDisabled: input == nil || look.isConfirming) {
          if let input { look.submitIdentity(input) }
        }
        .accessibilityIdentifier("use_identity_button")
      }
    }
  }

  private func field(_ prompt: String, text: Binding<String>, id: String, numeric: Bool = false) -> some View {
    TextField(prompt, text: text)
      .keyboardType(numeric ? .numberPad : .default)
      .textInputAutocapitalization(numeric ? .never : .words)
      .autocorrectionDisabled()
      .font(.system(size: 16))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(Color.white.opacity(0.12))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .accessibilityIdentifier(id)
  }
}

// MARK: - Guess first

private struct GuessSection: View {
  var look: LookViewModel
  var isProduct: Bool = false
  @State private var text = ""
  @FocusState private var focused: Bool

  private var amount: Int? {
    guard let value = Int(text.filter(\.isNumber)), (1...10_000_000).contains(value) else { return nil }
    return value
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(isProduct ? "What does it cost in a shop?" : "What do you think it costs?")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
      Text(isProduct ? "Guess the new price first, then see the real one." : "Guess first, then see the real price.")
        .font(.system(size: 13))
        .foregroundStyle(Color.white.opacity(0.65))

      HStack(spacing: 6) {
        Text("€")
          .font(.system(size: 30, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.7))
        TextField("0", text: $text)
          .keyboardType(.numberPad)
          .focused($focused)
          .font(.system(size: 34, weight: .semibold, design: .rounded))
          .foregroundStyle(.white)
          .accessibilityLabel("Your price guess in euros")
          .accessibilityIdentifier("guess_field")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(Color.white.opacity(0.12))
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

      if let error = look.guessError {
        Text(error).font(.system(size: 13)).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
      }

      CustomButton(
        title: look.isLockingGuess ? "Locking in…" : "Lock in my guess",
        style: .primary,
        isDisabled: amount == nil || look.isLockingGuess
      ) {
        if let amount { look.lockGuess(amount) }
      }
      .accessibilityIdentifier("lock_guess_button")
    }
    .task { focused = true }
  }
}

// MARK: - The accordion and what it says

struct AccordionSection: View {
  var snapshot: LookSnapshot
  var guess: Int
  var onCoach: (() -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      AccordionView(guess: guess, price: snapshot.price, guessResult: snapshot.guess?.result)
      status
    }
    .onChange(of: snapshot.guess?.result?.summary) { _, summary in
      if let summary { AccessibilityNotification.Announcement(summary).post() }
    }
  }

  @ViewBuilder
  private var status: some View {
    let price = snapshot.price
    if let result = snapshot.guess?.result {
      VStack(alignment: .leading, spacing: 8) {
        Text(result.summary)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(.white)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("guess_summary")
        HStack(spacing: 10) {
          ScorePill(score: result.score)
          Text(sourcesLine(price)).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.6))
        }
        if let used = price.usedRange {
          Text("Used or refurbished: \(Money.euros(used.low)) to \(Money.euros(used.high)), median \(Money.euros(used.median))")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.75))
            .accessibilityIdentifier("used_range")
        }
        if price.priceBasis == "used" {
          Text("This model is only sold used or refurbished now, so this is the used price.")
            .font(.system(size: 12)).foregroundStyle(Color.orange.opacity(0.9))
            .accessibilityIdentifier("used_basis")
        }
        if let note = price.notes?.first(where: { $0.contains("disagree") || $0.contains("rough") || $0.contains("several sizes") }) {
          Text(note.prefix(1).uppercased() + note.dropFirst())
            .font(.system(size: 12)).foregroundStyle(Color.orange.opacity(0.9))
        }
        if let onCoach, price.range != nil {
          CustomButton(title: "What this means for my money", style: .primary, isDisabled: false, action: onCoach)
            .accessibilityIdentifier("coach_button")
        }
      }
    } else if price.isPending {
      Text(pendingLine(price))
        .font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.7))
        .accessibilityIdentifier("price_progress")
    } else if price.status == "insufficient" {
      Text("I couldn't find enough matching listings to give a price range for this one.")
        .font(.system(size: 14)).foregroundStyle(Color.white.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)
    } else if price.status == "failed" {
      Text("I couldn't read the listings right now. Try again in a moment.")
        .font(.system(size: 14)).foregroundStyle(Color.white.opacity(0.85))
    } else {
      Text("Comparing your guess…").font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.7))
    }
  }

  private func pendingLine(_ price: LookSnapshot.Price) -> String {
    guard let total = price.sourcesTotal, total > 0 else { return "Finding listings…" }
    let found = price.nListings ?? 0
    let adverts = found > 0 ? " · \(found) \(snapshot.identification.kind == "car" ? "adverts" : "offers") so far" : ""
    return "Reading prices… \(price.sourcesDone ?? 0) of \(total) sites\(adverts)"
  }

  /// "6 sites · 35 adverts · fetched 14:53", the grounding line (CLAUDE.md rule 3).
  private func sourcesLine(_ price: LookSnapshot.Price) -> String {
    var parts: [String] = []
    let ok = price.sources?.filter { $0.status == "ok" }.count ?? 0
    if ok > 0 { parts.append(ok == 1 ? "1 site" : "\(ok) sites") }
    if let n = price.nListings { parts.append("\(n) \(snapshot.identification.kind == "car" ? "adverts" : "offers")") }
    if let stamp = price.fetchedAt, let date = ISO8601DateFormatter().date(from: stamp) {
      parts.append((price.cached == true ? "cached " : "fetched ") + date.formatted(date: .omitted, time: .shortened))
    }
    return parts.joined(separator: " · ")
  }
}

private struct ScorePill: View {
  var score: Int

  private var color: Color {
    score >= 75 ? .green : (score >= 40 ? .yellow : .orange)
  }

  var body: some View {
    Text("Score \(score)")
      .font(.system(size: 13, weight: .bold, design: .rounded))
      .foregroundStyle(.black)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(color)
      .clipShape(Capsule())
      .accessibilityLabel("Price sense score \(score) out of 100")
      .accessibilityIdentifier("score_pill")
  }
}
