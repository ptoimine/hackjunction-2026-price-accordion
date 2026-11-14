//
// GlassesDisplay.swift
//
// The Meta Ray-Ban Display capability of the DAT session. Every `send` replaces the whole screen and
// goes over Bluetooth, so sends are coalesced: one in flight, newest wins, the rest are dropped
// (counted, so the Glasses lab can show how much animation the link really carries).
//
// No SwiftUI import in this file on purpose: MWDATDisplay has its own Text / Button / Image.
//

import MWDATCore
import MWDATDisplay
import Observation
import UIKit

@Observable
@MainActor
final class GlassesDisplay {
  private(set) var stateText = "not attached"
  private(set) var isReady = false
  /// Goes up every time the display becomes ready (again), so the flow knows to re-send the screen.
  private(set) var readyEpoch = 0
  private(set) var lastSendMs = 0.0
  private(set) var averageSendMs = 0.0
  private(set) var sendCount = 0
  private(set) var droppedCount = 0
  private(set) var lastError: String?
  /// The newest screen handed to the lens (also while the display is still starting): the phone mirrors it
  /// so the lens content can be screen-recorded for a demo video.
  private(set) var lastImage: UIImage?

  /// `.fill` is the documented way to cover the lens with an image; `.icon` is the fallback if fill
  /// letterboxes or crops on the real display (a toggle in the Glasses lab, no rebuild needed).
  var useIconSize = false

  /// A tap on the lens touchpad lands here (the root view is tappable). Select events from the
  /// Inputs capability arrive separately.
  @ObservationIgnored var onTap: (@MainActor () -> Void)?

  @ObservationIgnored private var display: Display?
  @ObservationIgnored private let tokens = ListenerTokenBag()
  @ObservationIgnored private var pending: UIImage?
  @ObservationIgnored private var inFlight = false

  var isAttached: Bool { display != nil }

  func attach(to session: DeviceSession) {
    guard display == nil else { return }
    do {
      let capability = try session.addDisplay()
      display = capability
      capability.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.handle(state) }
      }.store(in: tokens)
      stateText = "starting"
      capability.start()
    } catch {
      stateText = "failed"
      lastError = "addDisplay: \(error.localizedDescription)"
    }
  }

  func detach() {
    tokens.clear()
    display?.stop()
    display = nil
    isReady = false
    pending = nil
    inFlight = false
    stateText = "not attached"
  }

  private func handle(_ state: DisplayState) {
    switch state {
    case .starting: stateText = "starting"
    case .started:
      stateText = "ready"
      isReady = true
      readyEpoch += 1
    case .stopping: stateText = "stopping"
    case .stopped:
      stateText = "stopped"
      isReady = false
      display = nil
      tokens.clear()
    }
  }

  // MARK: - Sending

  /// Show a full-screen image (600 x 600 is the display's size; larger buys nothing).
  func show(_ image: UIImage) {
    lastImage = image
    if inFlight {
      if pending != nil { droppedCount += 1 }
      pending = image
      return
    }
    guard let display, isReady else {
      pending = image  // sent as soon as the display reports ready
      return
    }
    send(image, on: display)
  }

  private func send(_ image: UIImage, on display: Display) {
    inFlight = true
    let started = ContinuousClock.now
    let view = FlexBox(direction: .column, alignment: .center, crossAlignment: .center) {
      Image(image: image, sizePreset: useIconSize ? .icon : .fill)
    }
    .onTap { [weak self] in Task { @MainActor in self?.onTap?() } }
    Task { [weak self] in
      var failure: String?
      do { try await display.send(view) } catch { failure = (error as? DisplayError)?.description ?? error.localizedDescription }
      guard let self else { return }
      let elapsed = started.duration(to: .now)
      let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
      self.inFlight = false
      if let failure {
        self.lastError = failure
      } else {
        self.lastSendMs = ms
        self.sendCount += 1
        self.averageSendMs = self.averageSendMs == 0 ? ms : self.averageSendMs * 0.8 + ms * 0.2
      }
      if let next = self.pending, self.isReady, let display = self.display {
        self.pending = nil
        self.send(next, on: display)
      }
    }
  }

  /// Native components (Text, Buttons, Icon) instead of one image: to see what the system styles look
  /// like on the lens and whether touchpad focus works. Taps are reported through `onAction`.
  func showNativeTest(onAction: @escaping @Sendable (String) -> Void) {
    guard let display, isReady else { return }
    let view = FlexBox(direction: .column, spacing: 12, padding: EdgeInsets(all: 20)) {
      Text("PRICE SENSE", style: .heading)
      Text("Native components test", style: .body, color: .secondary)
      Text("Is this a Sony WH-1000XM5?", style: .body)
      ButtonGroup(alignment: .center) {
        Button(label: "Yes", style: .primary, onClick: { onAction("yes") })
        Button(label: "No", style: .outline, onClick: { onAction("no") })
      }
      Text("Step 1 of 3", style: .meta, color: .secondary)
    }
    Task { try? await display.send(view) }
  }

  func clear() {
    guard let display else { return }
    pending = nil
    Task { try? await display.clearDisplay() }
  }
}
