//
// GlassesInputs.swift
//
// Input events from the glasses and the Meta Neural Band (DAT "Inputs", beta, dev release channel):
// Nav (4 directions) and Select from the touchpad or the band, Capture (short / hold / double) from
// the camera button, Button from the action button, and Drag from the band's pinch-and-drag.
// Which physical gesture maps to which event is decided by the device and the wearer's settings.
//

import MWDATCore
import MWDATInputs
import Observation
import UIKit

@Observable
@MainActor
final class GlassesInputs {
  private(set) var stateText = "not attached"
  private(set) var lastError: String?
  /// Newest first; the Glasses lab shows these live so gestures can be matched to events.
  private(set) var log: [String] = []
  private(set) var eventCount = 0
  /// Raw numbers of the latest drag sample: needed to calibrate the guess dial on real hardware.
  private(set) var lastDrag = ""

  @ObservationIgnored var onEvent: (@MainActor (InputEvent) -> Void)?

  @ObservationIgnored private var inputs: Inputs?
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private let tokens = ListenerTokenBag()

  func attach(to session: DeviceSession) {
    guard inputs == nil else { return }
    do {
      guard let capability = try session.addInputs() else {
        stateText = "unavailable"
        return
      }
      inputs = capability
      stateText = "\(capability.state)"
      capability.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.stateText = "\(state)" }
      }.store(in: tokens)
      capability.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.lastError = error.localizedDescription }
      }.store(in: tokens)
      let events = capability.events
      eventTask = Task { [weak self] in
        for await event in events {
          guard let self else { return }
          self.handle(event)
        }
      }
    } catch {
      stateText = "failed"
      lastError = "addInputs: \(error.localizedDescription)"
    }
  }

  func detach() {
    eventTask?.cancel()
    eventTask = nil
    tokens.clear()
    inputs = nil
    stateText = "not attached"
  }

  private func handle(_ event: InputEvent) {
    eventCount += 1
    if case .drag(_, let x, let y, let dx, let dy, _, _) = event {
      lastDrag = String(format: "x %.2f y %.2f dx %.2f dy %.2f", x, y, dx, dy)
    } else {
      log.insert(Self.describe(event), at: 0)  // drags would flood the log; they have their own line
      if log.count > 14 { log.removeLast() }
    }
    onEvent?(event)
  }

  static func describe(_ event: InputEvent) -> String {
    switch event {
    case .nav(let direction, let source, _): return "nav \(direction) · \(source)"
    case .select(let source, _): return "select · \(source)"
    case .back(let source, _): return "back · \(source)"
    case .button(let button, let source, _): return "button \(button) · \(source)"
    case .capture(let press, let source, _): return "capture \(press) · \(source)"
    case .drag(let action, _, _, _, _, let source, _): return "drag \(action) · \(source)"
    @unknown default: return "unknown event"
    }
  }
}
