//
// GlassesRig.swift
//
// Owns the three glasses capabilities that ride on the same DAT DeviceSession as the camera stream:
// the display, the inputs (touchpad, Neural Band, buttons) and the HUD flow that connects them to
// the Look -> Confirm -> Guess -> Accordion lesson.
//

import MWDATCore
import MWDATInputs
import Observation
import UIKit

@Observable
@MainActor
final class GlassesRig {
  let display = GlassesDisplay()
  let inputs = GlassesInputs()
  let flow = GlassesFlow()

  /// Run the HUD flow as soon as the display is ready (otherwise only from the Glasses lab).
  var autoRunFlow = true
  private(set) var hasAttached = false

  @ObservationIgnored private var look: LookViewModel?
  @ObservationIgnored private var capture: (@MainActor () async -> UIImage?)?
  @ObservationIgnored private var ready: (@MainActor () -> Bool)?
  @ObservationIgnored private var watcher: Task<Void, Never>?

  init() {
    inputs.onEvent = { [weak self] event in self?.route(event) }
    display.onTap = { [weak self] in self?.flow.primary() }
  }

  /// The camera screen gives the rig what it needs to look at things.
  func configure(
    look: LookViewModel, capture: @escaping @MainActor () async -> UIImage?, ready: @escaping @MainActor () -> Bool
  ) {
    self.look = look
    self.capture = capture
    self.ready = ready
    startFlowIfReady()
  }

  func attach(to session: DeviceSession) {
    hasAttached = true
    display.attach(to: session)
    inputs.attach(to: session)
    watcher?.cancel()
    watcher = Task { [weak self] in
      while !Task.isCancelled {
        self?.startFlowIfReady()
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  func detach() {
    watcher?.cancel()
    watcher = nil
    flow.stop()
    display.detach()
    inputs.detach()
    hasAttached = false
  }

  func startFlowIfReady() {
    guard autoRunFlow, display.isReady, !flow.isRunning, let look, let capture, let ready else { return }
    flow.start(look: look, display: display, capture: capture, ready: ready)
  }

  func startFlow() {
    guard let look, let capture, let ready else { return }
    flow.start(look: look, display: display, capture: capture, ready: ready)
  }

  private func route(_ event: InputEvent) {
    switch event {
    case .capture(let press, _, _):
      switch press {
      case .shortPress: flow.primary()
      case .hold: flow.back()
      case .doublePress: break
      }
    case .select: flow.primary()
    case .back, .button: flow.back()
    case .nav(let direction, _, _):
      switch direction {
      case .up: flow.navigate(.up)
      case .down: flow.navigate(.down)
      case .left: flow.navigate(.left)
      case .right: flow.navigate(.right)
      }
    case .drag(let action, _, _, let dx, _, _, _):
      if action == .move { flow.drag(dx: Double(dx)) }
    @unknown default: break
    }
  }
}
