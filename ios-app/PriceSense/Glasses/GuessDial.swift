//
// GuessDial.swift
//
// The guess on the glasses is dialled in, not typed: Neural Band drag turns it like a log-scale
// dial, directional input steps it, Select locks it in. Pure logic so it can be unit-tested.
//

import Foundation

struct GuessDial: Equatable, Sendable {
  static let minimum = 1
  static let maximum = 2_000_000

  private(set) var value: Int
  /// The un-rounded value while dragging, so many tiny drag samples add up instead of each rounding away.
  private var exact: Double

  init(value: Int) {
    let v = min(Self.maximum, max(Self.minimum, value))
    self.value = v
    self.exact = Double(v)
  }

  /// A sensible place to start the dial for each kind of thing.
  static func start(forKind kind: String) -> GuessDial {
    switch kind {
    case "car": return GuessDial(value: 15_000)
    case "laptop": return GuessDial(value: 1_000)
    case "phone": return GuessDial(value: 600)
    case "headphones": return GuessDial(value: 200)
    default: return GuessDial(value: 100)
    }
  }

  /// Step size at a value: 5 / 50 / 500 ... (coarse) or 1 / 10 / 100 ... (fine).
  static func step(at value: Int, coarse: Bool) -> Int {
    let magnitude = Int(pow(10, floor(log10(Double(max(value, 1))))))
    let coarseStep = max(1, magnitude / 2)
    return coarse ? coarseStep : max(1, coarseStep / 5)
  }

  mutating func nudge(up: Bool, coarse: Bool) {
    // when going down use the value just below, so 1,000 steps down by 50 (not 500)
    let reference = up ? value : max(value - 1, 1)
    let step = Self.step(at: reference, coarse: coarse)
    let snapped = (Double(value) / Double(step)).rounded() * Double(step)
    value = Self.clamp(Int(snapped) + (up ? step : -step))
    exact = Double(value)
  }

  /// A drag turns the dial on a log scale: dragging the same distance multiplies the guess by the
  /// same factor at any size. Result is rounded to two significant digits so it stays readable.
  mutating func drag(by amount: Double, sensitivity: Double = 2.5) {
    guard amount.isFinite, amount != 0 else { return }
    exact = min(Double(Self.maximum), max(Double(Self.minimum), exact * exp(amount * sensitivity)))
    value = Self.clamp(Self.roundToTwoDigits(exact))
  }

  static func roundToTwoDigits(_ x: Double) -> Int {
    guard x >= 100 else { return max(1, Int(x.rounded())) }
    let magnitude = pow(10, floor(log10(x)) - 1)
    return Int((x / magnitude).rounded() * magnitude)
  }

  private static func clamp(_ v: Int) -> Int { min(maximum, max(minimum, v)) }
}
