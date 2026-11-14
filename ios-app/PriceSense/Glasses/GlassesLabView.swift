//
// GlassesLabView.swift
//
// The control room for a session with real Meta Ray-Ban Display glasses: connect everything with one
// tap, push test screens to the lens, watch the link speed, see every input event the glasses and the
// Neural Band send (to match gestures to events), calibrate where the camera crop is, and run the
// HUD flow. Nothing here is needed by the phone-only flow.
//

import MWDATCamera
import SwiftUI
import UIKit

#if DEBUG
import MWDATMockDevice
#endif

struct GlassesLabView: View {
  var rig: GlassesRig
  var camera: CameraViewModel
  var look: LookViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var calibration = HUDCalibration.current()
  @State private var cropPreview: UIImage?
  @State private var framePreview: UIImage?
  @State private var speedReport = ""
  @State private var nativeTaps: [String] = []
  @State private var source = CaptureSource.active
  @State private var showMirror = false
  @State private var frozen: UIImage?
  @State private var tappedAim: CGPoint?

  var body: some View {
    NavigationStack {
      Form {
        connection
        mirrorSection
        sourceSection
        flowSection
        displayTests
        linkStats
        inputSection
        backSection
        aimSection
        calibrationSection
        voiceSection
        #if DEBUG
        mockSection
        #endif
      }
      .navigationTitle("Glasses lab")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Done") { dismiss() } }
      .fullScreenCover(isPresented: $showMirror) { HUDMirrorView(display: rig.display) }
    }
  }

  // MARK: Connection

  private var connection: some View {
    Section("Connection") {
      row("Session", camera.sessionStateText)
      row("Stream", camera.streamStateText)
      row("Display", rig.display.stateText)
      row("Inputs", rig.inputs.stateText)
      if let error = rig.display.lastError { Text("Display: \(error)").font(.footnote).foregroundStyle(.red) }
      if let error = rig.inputs.lastError { Text("Inputs: \(error)").font(.footnote).foregroundStyle(.red) }
      Button("Start session + display + inputs + camera") { camera.startGlassesHUD() }
        .disabled(camera.hasSession)
      Button("End session", role: .destructive) { camera.endSession() }
        .disabled(!camera.hasSession)
    }
  }

  // MARK: Lens mirror (for the demo video)

  private var mirrorSection: some View {
    Section("Record what the lens shows") {
      Button("Open the lens mirror (full screen)") { showMirror = true }
      Text("Start the iPhone's screen recording (Control Center), open the mirror, then do the demo with the glasses on. The phone shows exactly what the lens shows, on black. In editing, put it over a clip filmed by someone else with the blend mode Screen or Lighten: black becomes see-through, like the real display.")
        .font(.footnote).foregroundStyle(.secondary)
    }
  }

  // MARK: Capture source

  private var sourceSection: some View {
    Section("Where the picture comes from") {
      Picker("Source", selection: $source) {
        ForEach(CaptureSource.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .onChange(of: source) { _, new in
        Task {
          await camera.setCaptureSource(new)
          calibration = HUDCalibration.current()  // each source has its own calibration
          frozen = nil
          tappedAim = nil
          cropPreview = nil
          framePreview = nil
        }
      }
      if source == .photo {
        Picker("Resolution", selection: Binding(get: { camera.photoResolution }, set: { camera.photoResolution = $0 })) {
          ForEach(PhotoResolution.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        row("Photo capability", "\(camera.photoState)")
        row("Last photo", camera.lastPhotoInfo.isEmpty ? "—" : camera.lastPhotoInfo)
        Button("Take a test photo and show it") {
          Task {
            frozen = await camera.captureForLook()
            tappedAim = nil
            if frozen != nil { showCrop() }
          }
        }
        .disabled(!camera.canLook)
      }
      Text(source == .stream
        ? "The stream is a narrow, stabilised 9:16 crop of what the camera sees; a frame is instant."
        : "A standalone photo is wider and sharper than a stream frame but takes a few seconds, and the live stream is off while photo mode is on. Beta: an app using it cannot be published yet.")
        .font(.footnote).foregroundStyle(.secondary)
    }
  }

  // MARK: HUD flow

  private var flowSection: some View {
    Section("HUD flow (look → confirm → guess → accordion)") {
      row("Phase", rig.flow.phase.name)
      row("Dial", Money.euros(rig.flow.dial.value))
      Toggle("Run the flow automatically", isOn: Binding(get: { rig.autoRunFlow }, set: { rig.autoRunFlow = $0 }))
      Toggle("Speak the questions and the result", isOn: Binding(get: { rig.flow.voiceEnabled }, set: { rig.flow.voiceEnabled = $0 }))
      HStack {
        Button("Start flow") { rig.startFlow() }.disabled(!rig.display.isReady || rig.flow.isRunning)
        Spacer()
        Button("Stop flow") { rig.flow.stop() }.disabled(!rig.flow.isRunning)
        Spacer()
        Button("New look") { rig.flow.newLook() }
      }
      .buttonStyle(.bordered)
    }
  }

  // MARK: Display tests

  private var displayTests: some View {
    Section("Display tests (they pause the flow)") {
      testButton("Test pattern: edges, grid, colours") { HUDRenderer.testPattern() }
      testButton("Aim screen: reticle + blinking brackets") { HUDRenderer.aim(zone: HUDSprites.idle.frames[0], streaming: true, caption: "PRESS CAPTURE TO LOOK") }
      testButton("Confirm card") { HUDRenderer.card(label: "IS THIS A…", title: "Sony WH-1000XM5?", detail: "HEADPHONES", footer: "SELECT = YES    BACK = TRY AGAIN") }
      testButton("Guess dial") { HUDRenderer.guess(value: 250, title: "Sony WH-1000XM5", hint: "UP DOWN = BIG   LEFT RIGHT = SMALL\nDRAG TO TURN   SELECT = LOCK IN") }
      testButton("Accordion: open on the guess") { accordionDemo(squeezed: false, result: false) }
      testButton("Accordion: squeezed") { accordionDemo(squeezed: true, result: false) }
      testButton("Accordion: result") { accordionDemo(squeezed: true, result: true) }
      Button("Native components (Text + Buttons)") {
        rig.flow.stop()
        rig.display.showNativeTest { id in Task { @MainActor in nativeTaps.insert(id, at: 0) } }
      }
      if !nativeTaps.isEmpty { Text("native taps: \(nativeTaps.prefix(6).joined(separator: ", "))").font(.footnote.monospaced()) }
      Button("Animation speed test (10 s, 15 fps asked)") { Task { await speedTest() } }
      if !speedReport.isEmpty { Text(speedReport).font(.footnote.monospaced()) }
      Toggle("Image size .icon instead of .fill (if the picture is cropped or small)", isOn: Binding(get: { rig.display.useIconSize }, set: { rig.display.useIconSize = $0 }))
      Button("Clear the display") { rig.flow.stop(); rig.display.clear() }
    }
  }

  private func testButton(_ title: String, make: @escaping () -> UIImage) -> some View {
    Button(title) {
      rig.flow.stop()
      rig.display.show(make())
    }
    .disabled(!rig.display.isReady)
  }

  private func accordionDemo(squeezed: Bool, result: Bool) -> UIImage {
    let range = LookSnapshot.PriceRange(low: 26_000, median: 28_500, high: 31_000)
    let guess = 18_000
    let gap = LookSnapshot.GuessResult(
      guessEur: guess, gapEur: -10_500, gapPct: -36.8, verdict: "low", inRange: false, score: 61,
      summary: "You guessed €18,000. The real range is €26,000 to €31,000, median €28,500. You were 37% low.")
    return HUDRenderer.accordion(
      .init(
        title: "Škoda Octavia", guess: guess, range: squeezed ? range : nil,
        bandLow: squeezed ? Double(range.low) : Double(guess) * 0.5, bandHigh: squeezed ? Double(range.high) : Double(guess) * 1.5,
        done: result, result: result ? gap : nil, status: result ? nil : "READING PRICES… 3/6", usedRange: nil, coin: result ? nil : HUDSprites.coinSpin.frames[0]))
  }

  private func speedTest() async {
    rig.flow.stop()
    guard rig.display.isReady else { return }
    let sentBefore = rig.display.sendCount
    let droppedBefore = rig.display.droppedCount
    let clock = ContinuousClock()
    let start = clock.now
    for i in 0..<150 {
      rig.display.show(HUDRenderer.aim(zone: HUDSprites.idle.frames[i % 8], streaming: true, caption: "FRAME \(i)"))
      try? await Task.sleep(for: .milliseconds(66))
    }
    try? await Task.sleep(for: .milliseconds(500))
    let seconds = Double(start.duration(to: clock.now).components.seconds)
    let sent = rig.display.sendCount - sentBefore
    speedReport = String(
      format: "asked 150 frames in %.0f s · delivered %d (%.1f fps) · dropped %d · avg %.0f ms · last %.0f ms",
      seconds, sent, Double(sent) / max(seconds, 1), rig.display.droppedCount - droppedBefore, rig.display.averageSendMs, rig.display.lastSendMs)
  }

  // MARK: Link stats and inputs

  private var linkStats: some View {
    Section("Link") {
      row("Sends", "\(rig.display.sendCount)")
      row("Dropped (newest wins)", "\(rig.display.droppedCount)")
      row("Last send", String(format: "%.0f ms", rig.display.lastSendMs))
      row("Average send", String(format: "%.0f ms", rig.display.averageSendMs))
    }
  }

  private var inputSection: some View {
    Section("Input events (touchpad · Neural Band · buttons)") {
      row("Events so far", "\(rig.inputs.eventCount)")
      row("Last drag", rig.inputs.lastDrag.isEmpty ? "—" : rig.inputs.lastDrag)
      if rig.inputs.log.isEmpty {
        Text("Tap the temple, press the capture button, pinch with the band… each one shows up here.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      ForEach(Array(rig.inputs.log.enumerated()), id: \.offset) { _, line in
        Text(line).font(.footnote.monospaced())
      }
    }
  }

  // MARK: Back gesture

  private var backSection: some View {
    Section("Back gesture on the temple") {
      row("Back swipe", rig.flow.backDirection.label)
      Button(rig.flow.isLearningBackSwipe ? "Swipe the gesture you want for back now…" : "Learn: choose my back swipe") {
        rig.flow.learnBackSwipe()
      }
      .disabled(rig.flow.isLearningBackSwipe)
      Text("Anywhere except the guess dial, any swipe goes back. On the dial, swipe the back swipe twice. A two-finger tap is the system's Back: it ends the display session, so it cannot be used. Back events do not reach apps from real glasses yet; the capture button's hold also goes back.")
        .font(.footnote).foregroundStyle(.secondary)
    }
  }

  // MARK: Aim calibration (tap the target)

  /// The camera sits at the temple and sees a much wider view than the display, so the reticle on the lens
  /// does not point at the middle of the camera frame. Aim the reticle at something at your usual working
  /// distance, freeze the frame, and tap where the reticle was: the crop window follows.
  private var aimSection: some View {
    Section("Aim calibration: tap what the reticle was on") {
      Button(source == .photo ? "1. Aim the reticle at a target, then take a photo" : "1. Aim the reticle at a target, then freeze the camera frame") {
        Task {
          frozen = await camera.captureForLook()
          tappedAim = nil
        }
      }
      .disabled(!camera.canLook)
      if let frozen {
        Image(uiImage: frozen)
          .resizable()
          .aspectRatio(frozen.size, contentMode: .fit)
          .overlay {
            GeometryReader { geo in
              ZStack {
                Color.clear.contentShape(Rectangle())
                  .gesture(
                    SpatialTapGesture().onEnded { value in
                      applyAim(CGPoint(x: value.location.x / geo.size.width, y: value.location.y / geo.size.height))
                    })
                let crop = calibration.clamped()
                Rectangle()
                  .stroke(Color.yellow, lineWidth: 3)
                  .frame(width: geo.size.width * crop.fraction, height: geo.size.height * crop.fraction)
                  .position(x: geo.size.width * (0.5 + crop.offset.x), y: geo.size.height * (0.5 + crop.offset.y))
                  .allowsHitTesting(false)
                if let tappedAim {
                  Image(systemName: "plus.circle").font(.system(size: 28, weight: .bold)).foregroundStyle(.cyan)
                    .position(x: geo.size.width * tappedAim.x, y: geo.size.height * tappedAim.y)
                    .allowsHitTesting(false)
                }
              }
            }
          }
        Text("2. Tap the spot the reticle was on. The yellow window is what gets sent to the model; it moves to your tap and is saved.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      Text("Calibrate at the distance you will use: the camera and the lens are a few centimetres apart, so the offset changes with distance.")
        .font(.footnote).foregroundStyle(.secondary)
    }
  }

  private func applyAim(_ tap: CGPoint) {
    tappedAim = tap
    calibration.offset = CGPoint(x: tap.x - 0.5, y: tap.y - 0.5)
    calibration = calibration.clamped()
    calibration.save()
    showCrop()
  }

  // MARK: Calibration

  private var calibrationSection: some View {
    Section("Camera crop (where the aim point is in the camera frame)") {
      slider("Move right", value: Binding(get: { calibration.offset.x }, set: { calibration.offset.x = $0; calibration = calibration.clamped() }), range: -0.3...0.3)
      slider("Move down", value: Binding(get: { calibration.offset.y }, set: { calibration.offset.y = $0; calibration = calibration.clamped() }), range: -0.3...0.3)
      slider("Size", value: Binding(get: { calibration.fraction }, set: { calibration.fraction = $0; calibration = calibration.clamped() }), range: 0.25...0.9)
      HStack {
        Button("Show crop") { showCrop() }.disabled(frozen == nil && camera.currentVideoFrame == nil)
        Spacer()
        Button("Save") { calibration.save() }
        Spacer()
        Button("Reset", role: .destructive) { HUDCalibration.reset(); calibration = HUDCalibration() }
      }
      .buttonStyle(.bordered)
      if let framePreview { Image(uiImage: framePreview).resizable().scaledToFit() }
      if let cropPreview { Image(uiImage: cropPreview).resizable().scaledToFit().frame(maxHeight: 180) }
      Text("Aim the reticle at something, tap Show crop, and move the window until the crop holds what you aimed at. Distance changes the offset (parallax), so calibrate at the distance you will use.")
        .font(.footnote).foregroundStyle(.secondary)
    }
  }

  private func showCrop() {
    guard let frame = frozen ?? camera.currentVideoFrame else { return }
    let crop = calibration.clamped()
    if let prepared = try? ImagePrivacy.prepareForUpload(frame, cropFraction: crop.fraction, cropOffset: crop.offset) {
      cropPreview = UIImage(data: prepared.jpeg)
    }
    // the whole frame with the crop window drawn on it
    let size = frame.size
    let renderer = UIGraphicsImageRenderer(size: size)
    framePreview = renderer.image { context in
      frame.draw(at: .zero)
      let w = size.width * crop.fraction, h = size.height * crop.fraction
      let rect = CGRect(x: size.width / 2 + crop.offset.x * size.width - w / 2, y: size.height / 2 + crop.offset.y * size.height - h / 2, width: w, height: h)
      context.cgContext.setStrokeColor(UIColor.yellow.cgColor)
      context.cgContext.setLineWidth(max(4, size.width / 120))
      context.cgContext.stroke(rect)
    }
  }

  // MARK: Voice

  private var voiceSection: some View {
    Section("Voice") {
      Button("Speak a sample answer") {
        HUDVoice.shared.speak("You guessed 250 euros. The real range is 299 to 329 euros. You were 24 percent low.")
      }
    }
  }

  // MARK: Mock display (simulator)

  #if DEBUG
  private var mockSection: some View {
    Section("Mock display preview (simulator, Pair Ray-Ban Display first)") {
      MockDisplayPreview().frame(height: 300)
    }
  }
  #endif

  // MARK: Helpers

  private func row(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value).font(.callout.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
    }
  }

  private func slider(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
    VStack(alignment: .leading) {
      Text("\(label): \(String(format: "%.2f", Double(value.wrappedValue)))").font(.footnote)
      Slider(value: value, in: range)
    }
  }
}

#if DEBUG
/// The mock glasses' own rendering of whatever the app sends (600 x 600 additive display).
struct MockDisplayPreview: UIViewRepresentable {
  func makeUIView(context: Context) -> UIView {
    let glasses = MockDeviceKit.shared.pairedDevices.compactMap { $0 as? MockGlasses }
    return glasses.first?.services.display.createPreviewView() ?? UIView()
  }

  func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
