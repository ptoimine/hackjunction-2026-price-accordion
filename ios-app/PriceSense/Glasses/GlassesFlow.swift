//
// GlassesFlow.swift
//
// The whole price lesson on the Ray-Ban Display, hands free:
//
//   aim ──capture──▶ lock ──▶ looking ──▶ success ──▶ confirm ──yes──▶ guess ──lock──▶ accordion ──▶ aim
//        (button / select / tap)   (coin spins)  (frame flies)  "Is this a …?"  (dial)   (squeezes, verdict)
//
// Inputs (see GlassesInputs): Capture short press, Select (touchpad or band tap) and a lens tap are all
// "primary"; Capture hold, Back and the action button are "back"; Nav up / down / left / right and the
// band's Drag turn the guess dial. The phone flow stays the source of truth: this drives the same
// LookViewModel the phone screen uses, so the phone mirrors what happens on the lens.
//

import Observation
import UIKit

@Observable
@MainActor
final class GlassesFlow {
  enum Phase: Equatable {
    case aim
    case lock(Date)
    case looking(Date)
    case success(Date)
    case confirm
    case guess
    case accordion
    case notPriceable
    case failed(String)

    var name: String {
      switch self {
      case .aim: "aim"
      case .lock: "lock"
      case .looking: "looking"
      case .success: "success"
      case .confirm: "confirm"
      case .guess: "guess"
      case .accordion: "accordion"
      case .notPriceable: "not priceable"
      case .failed: "failed"
      }
    }
  }

  private(set) var phase: Phase = .aim
  private(set) var isRunning = false
  private(set) var dial = GuessDial(value: 100)
  var voiceEnabled = true

  @ObservationIgnored private var look: LookViewModel?
  @ObservationIgnored private var display: GlassesDisplay?
  @ObservationIgnored private var capturePicture: (@MainActor () async -> UIImage?)?
  @ObservationIgnored private var isReady: (@MainActor () -> Bool)?
  @ObservationIgnored private var isCapturing = false
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var lastKey = ""
  @ObservationIgnored private var lastEpoch = -1
  @ObservationIgnored private var lastPrimary = Date.distantPast
  @ObservationIgnored private var easedLow: Double?
  @ObservationIgnored private var easedHigh: Double?
  @ObservationIgnored private var spokenKeys = Set<String>()
  @ObservationIgnored private var notice: String?
  @ObservationIgnored private let startedAt = Date()

  // MARK: - Lifecycle

  func start(
    look: LookViewModel, display: GlassesDisplay, capture: @escaping @MainActor () async -> UIImage?,
    ready: @escaping @MainActor () -> Bool
  ) {
    self.look = look
    self.display = display
    self.capturePicture = capture
    self.isReady = ready
    guard !isRunning else { return }
    isRunning = true
    reset()
    loop = Task { [weak self] in
      while !Task.isCancelled {
        self?.tick()
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
    isRunning = false
    HUDVoice.shared.stop()
  }

  private func reset() {
    phase = .aim
    lastKey = ""
    easedLow = nil
    easedHigh = nil
    notice = nil
    spokenKeys.removeAll()
  }

  /// Back to aiming for a new look.
  func newLook() {
    look?.dismiss()
    reset()
  }

  // MARK: - Commands (from the glasses)

  /// Capture / Select / tap.
  func primary() {
    guard debounced() else { return }
    HUDVoice.shared.stop()
    switch phase {
    case .aim: capture()
    case .confirm: look?.confirmIdentity()
    case .guess: look?.lockGuess(dial.value)
    case .accordion, .notPriceable, .failed: newLook()
    case .lock, .looking, .success: break
    }
  }

  /// Capture hold / Back / action button: retry or leave.
  func back() {
    guard debounced() else { return }
    HUDVoice.shared.stop()
    switch phase {
    case .aim: break
    default: newLook()
    }
  }

  /// Temple swipes and band taps. Outside the guess dial any swipe goes back (try again / look at
  /// something else). On the dial every direction turns the number, so Back there is the back swipe twice
  /// within 0.8 s. A two-finger tap is the system's Back and ends the display session: not usable.
  func navigate(_ direction: NavigationDirection) {
    if isLearningBackSwipe {
      backDirection = direction
      isLearningBackSwipe = false
      return
    }
    switch phase {
    case .guess:
      if direction == backDirection {
        if Date().timeIntervalSince(lastBackSwipe) < 0.8 {
          lastBackSwipe = .distantPast
          back()
          return
        }
        lastBackSwipe = Date()
      }
      switch direction {
      case .up: dial.nudge(up: true, coarse: true)
      case .down: dial.nudge(up: false, coarse: true)
      case .right: dial.nudge(up: true, coarse: false)
      case .left: dial.nudge(up: false, coarse: false)
      }
    case .confirm, .accordion, .notPriceable, .failed:
      back()
    default: break
    }
  }

  /// A drag sample from the Neural Band. Units are not documented, so the scale is guessed from the
  /// magnitude (pixels vs. normalised) and has to be confirmed on the real band: see the Glasses lab.
  func drag(dx: Double) {
    guard phase == .guess, dx.isFinite else { return }
    let scale = abs(dx) > 2 ? 0.003 : 0.5
    dial.drag(by: dx * scale / 2.5)
  }

  enum NavigationDirection: String, CaseIterable, Sendable {
    case up, down, left, right
    var label: String { rawValue.uppercased() }
  }

  /// The swipe that means "back". It is the one direction that is free in every phase, and the wearer's
  /// device settings can invert swipes, so it can be taught from the Glasses lab (`learnBackSwipe`).
  var backDirection: NavigationDirection = GlassesFlow.storedBackDirection() {
    didSet { UserDefaults.standard.set(backDirection.rawValue, forKey: "hud.backDirection") }
  }
  /// The next swipe becomes the back swipe.
  private(set) var isLearningBackSwipe = false

  func learnBackSwipe() { isLearningBackSwipe = true }

  private static func storedBackDirection() -> NavigationDirection {
    UserDefaults.standard.string(forKey: "hud.backDirection").flatMap(NavigationDirection.init(rawValue:)) ?? .down
  }

  @ObservationIgnored private var lastBackSwipe = Date.distantPast

  private func debounced() -> Bool {
    let now = Date()
    guard now.timeIntervalSince(lastPrimary) > 0.35 else { return false }
    lastPrimary = now
    return true
  }

  /// Take the picture (a stream frame at once, or a standalone photo in a few seconds) and look at it.
  private func capture() {
    guard let look, !isCapturing else { return }
    guard isReady?() == true else {
      notice = CaptureSource.active == .photo ? "CAMERA NOT READY" : "NO CAMERA STREAM"
      return
    }
    notice = nil
    look.dismiss()
    phase = .lock(Date())
    isCapturing = true
    Task { [weak self] in
      let image = await self?.capturePicture?()
      guard let self else { return }
      self.isCapturing = false
      switch self.phase {
      case .lock, .looking: break
      default: return  // the user backed out while the photo was being taken
      }
      guard let image else {
        self.notice = "PICTURE FAILED, TRY AGAIN"
        self.phase = .aim
        return
      }
      look.look(at: image)
    }
  }

  // MARK: - Drawing (every 100 ms)

  private func tick() {
    guard let look, let display else { return }
    if display.readyEpoch != lastEpoch {  // the display just (re)started: draw again
      lastEpoch = display.readyEpoch
      lastKey = ""
    }
    let now = Date()
    let isStreaming = isReady?() ?? false
    let snapshot = currentSnapshot(look)

    switch phase {
    case .aim:
      let elapsed = now.timeIntervalSince(startedAt)
      let index = Int(elapsed / HUDSprites.idle.frameDuration) % HUDSprites.idle.frames.count
      let caption = notice ?? (isStreaming ? "PRESS CAPTURE TO LOOK" : "STARTING CAMERA…")
      let color = notice != nil || !isStreaming ? HUDRenderer.Palette.orange : HUDRenderer.Palette.cyan
      present("aim-\(index)-\(isStreaming)-\(caption)") {
        HUDRenderer.aim(zone: HUDSprites.idle.frame(at: elapsed), streaming: isStreaming, caption: caption, captionColor: color)
      }

    case .lock(let start):
      let elapsed = now.timeIntervalSince(start)
      if HUDSprites.lockOn.isFinished(at: elapsed) { phase = .looking(now) }
      let index = Int(elapsed / HUDSprites.lockOn.frameDuration)
      present("lock-\(index)") {
        HUDRenderer.aim(zone: HUDSprites.lockOn.frame(at: elapsed), streaming: isStreaming)
      }

    case .looking(let start):
      let elapsed = now.timeIntervalSince(start)
      switch look.state {
      case .result(let result) where result.snapshot != nil:
        phase = .success(now)
      case .failed(let message):
        phase = .failed(message)
      default:
        if elapsed > 45 { phase = .failed("The server took too long.") }
      }
      let index = Int(elapsed / HUDSprites.coinSpin.frameDuration) % HUDSprites.coinSpin.frames.count
      present("looking-\(index)") {
        HUDRenderer.aim(
          zone: HUDSprites.bracketsBase, streaming: isStreaming, coin: HUDSprites.coinSpin.frame(at: elapsed),
          caption: "LOOKING…", captionColor: HUDRenderer.Palette.yellow)
      }

    case .success(let start):
      let elapsed = now.timeIntervalSince(start)
      if HUDSprites.success.isFinished(at: elapsed) { advanceAfterSuccess(snapshot) }
      let index = Int(elapsed / HUDSprites.success.frameDuration)
      present("success-\(index)") {
        HUDRenderer.aim(zone: HUDSprites.success.frame(at: elapsed), streaming: isStreaming)
      }

    case .confirm:
      guard let snapshot else { phase = .aim; return }
      if look.identityConfirmed {
        phase = .guess
        return
      }
      let title = snapshot.identification.title
      let description = snapshot.identification.description
      let sure = snapshot.identification.confidence >= 0.5
      speakOnce("confirm-\(snapshot.lookId)", "\(sure ? "I think this is" : "I'm not sure, maybe") \(title). \(description)")
      var detail = [snapshot.identification.variant, snapshot.identification.years].compactMap { $0 }.joined(separator: " · ")
      if !sure { detail = (detail.isEmpty ? "" : detail + " · ") + "NOT SURE" }
      let footer = look.confirmError ?? (look.isConfirming ? "ONE MOMENT…" : "TAP = YES    SWIPE = TRY AGAIN")
      present("confirm-\(title)-\(detail)-\(footer)") {
        HUDRenderer.card(
          label: sure ? "I THINK THIS IS…" : "MAYBE…", title: title, detail: detail.isEmpty ? nil : detail, footer: footer,
          body: description.isEmpty ? nil : description)
      }

    case .guess:
      guard let snapshot else { phase = .aim; return }
      if look.lockedGuess != nil {
        phase = .accordion
        return
      }
      let kind = snapshot.identification.kind
      let hint =
        look.guessError ?? (look.isLockingGuess ? "LOCKING IN…" : "UP DOWN = BIG   LEFT RIGHT = SMALL\nTAP = LOCK IN   2x \(backDirection.label) = BACK")
      speakOnce("guess-\(snapshot.lookId)", kind == "car" ? "What do you think it costs?" : "What does it cost in a shop?")
      present("guess-\(dial.value)-\(hint)") {
        HUDRenderer.guess(value: dial.value, title: snapshot.identification.title, hint: hint)
      }

    case .accordion:
      guard let snapshot, let locked = look.lockedGuess else { phase = .aim; return }
      drawAccordion(snapshot, guess: locked, elapsed: now.timeIntervalSince(startedAt))

    case .notPriceable:
      let description = snapshot?.identification.description ?? ""
      let title = snapshot?.identification.title ?? "SOMETHING"
      present("not-priceable-\(title)") {
        HUDRenderer.card(
          label: "I SEE…", title: title, detail: snapshot?.price.reason,
          footer: "TAP OR SWIPE = LOOK AT SOMETHING ELSE", accent: HUDRenderer.Palette.orange,
          body: description.isEmpty ? nil : description)
      }

    case .failed(let message):
      present("failed-\(message)") {
        HUDRenderer.card(
          label: "OOPS", title: "SOMETHING WENT WRONG", detail: message,
          footer: "TAP OR SWIPE = TRY AGAIN", accent: HUDRenderer.Palette.red)
      }
    }
  }

  private func currentSnapshot(_ look: LookViewModel) -> LookSnapshot? {
    look.state.resultValue?.snapshot
  }

  private func advanceAfterSuccess(_ snapshot: LookSnapshot?) {
    guard let snapshot else {
      phase = .aim
      return
    }
    if snapshot.identification.isPriceable {
      dial = GuessDial.start(forKind: snapshot.identification.kind)
      phase = .confirm
    } else {
      speakOnce("np-\(snapshot.lookId)", "\(snapshot.identification.description) \(snapshot.price.reason ?? "I can't price it.")")
      phase = .notPriceable
    }
  }

  private func drawAccordion(_ snapshot: LookSnapshot, guess: Int, elapsed: TimeInterval) {
    let price = snapshot.price
    let targetLow = Double(price.range?.low ?? 0) > 0 ? Double(price.range!.low) : Double(guess) * AccordionGeometry.openLow
    let targetHigh = price.range.map { Double($0.high) } ?? Double(guess) * AccordionGeometry.openHigh
    // ease the bellows towards the real range: this is the squeeze
    var low = easedLow ?? Double(guess) * AccordionGeometry.openLow
    var high = easedHigh ?? Double(guess) * AccordionGeometry.openHigh
    low += (targetLow - low) * 0.35
    high += (targetHigh - high) * 0.35
    if abs(targetLow - low) < max(1, targetLow * 0.002) { low = targetLow }
    if abs(targetHigh - high) < max(1, targetHigh * 0.002) { high = targetHigh }
    easedLow = low
    easedHigh = high

    let result = snapshot.guess?.result
    if let result { speakOnce("result-\(snapshot.lookId)", result.summary) }

    var status: String?
    if price.isPending {
      status = "READING PRICES… \(price.sourcesDone ?? 0)/\(price.sourcesTotal ?? 0)"
    } else if !price.isDone {
      status = (price.reason ?? "NO PRICE FOUND").uppercased()
    }
    let spinning = price.isPending
    let coinIndex = spinning ? Int(elapsed / HUDSprites.coinSpin.frameDuration) % HUDSprites.coinSpin.frames.count : -1
    let state = HUDRenderer.AccordionState(
      title: snapshot.identification.title, guess: guess, range: price.range, bandLow: low, bandHigh: high,
      done: price.isDone, result: result, status: status, usedRange: price.usedRange,
      coin: spinning ? HUDSprites.coinSpin.frame(at: elapsed) : nil)
    present("acc-\(Int(low))-\(Int(high))-\(status ?? "")-\(result?.score ?? -1)-\(coinIndex)") {
      HUDRenderer.accordion(state)
    }
  }

  private func present(_ key: String, _ make: () -> UIImage) {
    guard key != lastKey, let display else { return }
    lastKey = key
    display.show(make())
  }

  private func speakOnce(_ key: String, _ text: String) {
    guard voiceEnabled, spokenKeys.insert(key).inserted else { return }
    HUDVoice.shared.speak(text)
  }
}

extension LookViewModel.State {
  var resultValue: LookResult? {
    if case .result(let result) = self { return result }
    return nil
  }
}
