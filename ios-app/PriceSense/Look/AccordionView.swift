//
// AccordionView.swift
//
// The price accordion (CLAUDE.md section 4): a horizontal accordion whose bellows show a price range.
//   * It OPENS WIDE on the user's guess (uncertainty): before any source has answered, the bellows
//     span half to one-and-a-half times the guess.
//   * It SQUEEZES as each source answers: the ends spring to the current low and high.
//   * The final state shows the real range, the median, the guess marker and (in the card around
//     it) the gap in euros and percent, all computed by the server.
//

import SwiftUI

/// Where things sit on the horizontal price axis. Pure, so it is easy to test.
struct AccordionGeometry: Equatable {
  /// Before any range is known the bellows span this share of the guess.
  static let openLow = 0.5
  static let openHigh = 1.5

  let guess: Double
  let range: LookSnapshot.PriceRange?

  init(guess: Int, range: LookSnapshot.PriceRange?) {
    self.guess = Double(guess)
    self.range = range
  }

  /// Left and right end of the bellows, in euros.
  var bandLow: Double { range.map { Double($0.low) } ?? guess * Self.openLow }
  var bandHigh: Double { range.map { Double($0.high) } ?? guess * Self.openHigh }

  /// The axis always contains the guess, the open (uncertain) band and the real range. Because it
  /// includes the open band from the start, the axis does not jump when the first range arrives:
  /// the bellows simply squeeze (the axis only grows if the real price is far from the guess).
  var domain: ClosedRange<Double> {
    let low = min(guess * Self.openLow, bandLow, guess) * 0.9
    let high = max(guess * Self.openHigh, bandHigh, guess) * 1.05
    return low...high
  }

  /// Position of a euro value on the axis, 0 (left) to 1 (right).
  func fraction(_ value: Double) -> Double {
    let d = domain
    guard d.upperBound > d.lowerBound else { return 0.5 }
    return min(1, max(0, (value - d.lowerBound) / (d.upperBound - d.lowerBound)))
  }
}

struct AccordionView: View {
  var guess: Int
  var price: LookSnapshot.Price
  var guessResult: LookSnapshot.GuessResult?

  private let barTop: CGFloat = 40
  private let barHeight: CGFloat = 46

  private var geometry: AccordionGeometry { AccordionGeometry(guess: guess, range: price.range) }

  /// Green when the guess landed inside the real range, orange otherwise (and while unknown).
  private var guessColor: Color {
    guard let result = guessResult else { return .orange }
    return result.inRange ? .green : .orange
  }

  var body: some View {
    let geo = geometry
    GeometryReader { proxy in
      let width = proxy.size.width
      let guessX = geo.fraction(Double(guess)) * width
      let bottom = barTop + barHeight

      ZStack(alignment: .topLeading) {
        Bellows(from: geo.fraction(geo.bandLow), to: geo.fraction(geo.bandHigh))
          .frame(width: width, height: barHeight)
          .offset(y: barTop)
          .opacity(price.isDone ? 1 : 0.88)

        if let range = price.range {
          // the median: a white line through the bellows
          let medianX = geo.fraction(Double(range.median)) * width
          Rectangle().fill(.white)
            .frame(width: 3, height: barHeight + 10)
            .position(x: medianX, y: barTop + barHeight / 2)
          label("median \(Money.euros(range.median))", x: medianX, y: bottom + 32, width: width, bold: true)
          label(Money.euros(range.low), x: geo.fraction(Double(range.low)) * width, y: bottom + 14, width: width)
          label(Money.euros(range.high), x: geo.fraction(Double(range.high)) * width, y: bottom + 14, width: width)
        }

        // the guess: a marker above the bellows with a thin line through them
        Rectangle().fill(guessColor.opacity(0.9))
          .frame(width: 2, height: barHeight + 14)
          .position(x: guessX, y: barTop + barHeight / 2 - 2)
        Triangle().fill(guessColor)
          .frame(width: 14, height: 9)
          .position(x: guessX, y: barTop - 16)
        label("You \(Money.euros(guess))", x: guessX, y: 8, width: width, color: guessColor, bold: true)
      }
    }
    .frame(height: barTop + barHeight + 50)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
    .accessibilityIdentifier("accordion")
  }

  private var accessibilityText: String {
    if let result = guessResult { return result.summary }
    if price.isPending { return "Reading listings. Your guess is \(Money.euros(guess))." }
    return "Your guess is \(Money.euros(guess))."
  }

  /// A small text label centred on `x`, kept inside the view.
  private func label(
    _ text: String, x: CGFloat, y: CGFloat, width: CGFloat, color: Color = .white, bold: Bool = false
  ) -> some View {
    let half: CGFloat = 52
    return Text(text)
      .font(.system(size: 12, weight: bold ? .semibold : .regular, design: .rounded))
      .foregroundStyle(color.opacity(bold ? 1 : 0.8))
      .lineLimit(1)
      .fixedSize()
      .position(x: min(max(x, half), max(half, width - half)), y: y)
  }
}

private struct Triangle: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

/// The folded bellows between two ends. `from` and `to` are fractions of the width and animate,
/// so the pleats (a fixed number) visibly compress and spread as the range changes.
private struct Bellows: View, @preconcurrency Animatable {
  var from: Double
  var to: Double

  var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(from, to) }
    set {
      from = newValue.first
      to = newValue.second
    }
  }

  private static let pleats = 16

  var body: some View {
    Canvas { context, size in
      let left = from * size.width
      let right = max(left + 3, to * size.width)  // never vanish completely
      let step = (right - left) / Double(Self.pleats)
      let fold = min(size.height * 0.18, max(1.5, step * 0.9))  // folds flatten as they compress

      func vertex(_ i: Int) -> (x: Double, top: Double, bottom: Double) {
        let inset = i.isMultiple(of: 2) ? 0.0 : fold
        return (left + step * Double(i), inset, size.height - inset)
      }

      for i in 0..<Self.pleats {
        let a = vertex(i), b = vertex(i + 1)
        var pleat = Path()
        pleat.move(to: CGPoint(x: a.x, y: a.top))
        pleat.addLine(to: CGPoint(x: b.x, y: b.top))
        pleat.addLine(to: CGPoint(x: b.x, y: b.bottom))
        pleat.addLine(to: CGPoint(x: a.x, y: a.bottom))
        pleat.closeSubpath()
        context.fill(pleat, with: .color(Color.appPrimary.opacity(i.isMultiple(of: 2) ? 0.95 : 0.6)))
        context.stroke(pleat, with: .color(.white.opacity(0.35)), lineWidth: 0.7)
      }

      // the two end plates the player holds
      for x in [left - 7, right] {
        let plate = Path(roundedRect: CGRect(x: x, y: 0, width: 7, height: size.height), cornerRadius: 3)
        context.fill(plate, with: .color(.white.opacity(0.92)))
      }
    }
  }
}
