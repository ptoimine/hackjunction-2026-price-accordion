//
// HUDTests.swift
//
// The Ray-Ban Display HUD without hardware: the guess dial, the crop calibration, the sprites, and
// every screen rendered to a 600 x 600 image (written to $HUD_OUT when set, to be looked at).
//

@testable import PriceSense
import UIKit
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

final class GuessDialTests: XCTestCase {
  func testStartsSensiblyPerKind() {
    XCTAssertEqual(GuessDial.start(forKind: "car").value, 15_000)
    XCTAssertEqual(GuessDial.start(forKind: "headphones").value, 200)
    XCTAssertEqual(GuessDial.start(forKind: "banana").value, 100)
  }

  func testCoarseAndFineSteps() {
    XCTAssertEqual(GuessDial.step(at: 15_000, coarse: true), 5_000)
    XCTAssertEqual(GuessDial.step(at: 15_000, coarse: false), 1_000)
    XCTAssertEqual(GuessDial.step(at: 250, coarse: true), 50)
    XCTAssertEqual(GuessDial.step(at: 250, coarse: false), 10)
    XCTAssertEqual(GuessDial.step(at: 7, coarse: false), 1)
  }

  func testNudgeUpAndDown() {
    var dial = GuessDial(value: 200)
    dial.nudge(up: true, coarse: true)
    XCTAssertEqual(dial.value, 250)
    dial.nudge(up: false, coarse: false)
    XCTAssertEqual(dial.value, 240)
  }

  func testStepsDownAcrossAMagnitudeUseTheSmallerStep() {
    var dial = GuessDial(value: 1_000)
    dial.nudge(up: false, coarse: true)
    XCTAssertEqual(dial.value, 950)  // not 500
  }

  func testNeverLeavesItsBounds() {
    var low = GuessDial(value: 1)
    low.nudge(up: false, coarse: false)
    XCTAssertEqual(low.value, 1)
    var high = GuessDial(value: GuessDial.maximum)
    high.nudge(up: true, coarse: true)
    XCTAssertEqual(high.value, GuessDial.maximum)
    XCTAssertEqual(GuessDial(value: -5).value, 1)
  }

  func testTinyDragSamplesAddUp() {
    var dial = GuessDial(value: 1_000)
    for _ in 0..<200 { dial.drag(by: 0.001, sensitivity: 2.5) }  // each alone would round away
    XCTAssertGreaterThan(dial.value, 1_400)
    XCTAssertLessThan(dial.value, 1_800)
  }

  func testDragIsSymmetricOnALogScale() {
    var dial = GuessDial(value: 20_000)
    dial.drag(by: 0.1)
    dial.drag(by: -0.1)
    XCTAssertEqual(dial.value, 20_000)
  }

  func testTwoSignificantDigits() {
    XCTAssertEqual(GuessDial.roundToTwoDigits(15_432), 15_000)
    XCTAssertEqual(GuessDial.roundToTwoDigits(15_999), 16_000)
    XCTAssertEqual(GuessDial.roundToTwoDigits(432), 430)
    XCTAssertEqual(GuessDial.roundToTwoDigits(37.4), 37)
  }
}

final class HUDCalibrationTests: XCTestCase {
  override func setUp() { CaptureSource.active = .stream; HUDCalibration.reset() }
  override func tearDown() { HUDCalibration.reset() }

  func testDefaultsToTheCentre70Percent() {
    let c = HUDCalibration.current()
    XCTAssertEqual(c.fraction, 0.7, accuracy: 0.001)
    XCTAssertEqual(c.offset, .zero)
  }

  func testWindowCannotLeaveTheFrame() {
    var c = HUDCalibration(fraction: 0.6, offset: CGPoint(x: 0.9, y: -0.9))
    c = c.clamped()
    XCTAssertEqual(c.offset.x, 0.2, accuracy: 0.001)  // (1 - 0.6) / 2
    XCTAssertEqual(c.offset.y, -0.2, accuracy: 0.001)
    XCTAssertEqual(HUDCalibration(fraction: 5, offset: .zero).clamped().fraction, 0.9, accuracy: 0.001)
  }

  func testSaveAndLoad() {
    HUDCalibration(fraction: 0.5, offset: CGPoint(x: 0.1, y: -0.05)).save()
    let c = HUDCalibration.current()
    XCTAssertEqual(c.fraction, 0.5, accuracy: 0.001)
    XCTAssertEqual(c.offset.x, 0.1, accuracy: 0.001)
    XCTAssertEqual(c.offset.y, -0.05, accuracy: 0.001)
  }

  func testCropOffsetMovesTheCrop() throws {
    // a frame that is black on the left half and white on the right half
    let size = CGSize(width: 400, height: 300)
    let frame = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
      UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
      UIColor.white.setFill(); ctx.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
    }
    func brightness(_ jpeg: Data) -> CGFloat {
      let image = UIImage(data: jpeg)!.cgImage!
      let data = image.dataProvider!.data! as Data
      let bytesPerPixel = image.bitsPerPixel / 8
      var sum = 0, count = 0
      for i in stride(from: 0, to: data.count - bytesPerPixel, by: bytesPerPixel * 7) { sum += Int(data[i]); count += 1 }
      return CGFloat(sum) / CGFloat(max(count, 1)) / 255
    }
    let left = try ImagePrivacy.prepareForUpload(frame, cropFraction: 0.4, cropOffset: CGPoint(x: -0.3, y: 0))
    let right = try ImagePrivacy.prepareForUpload(frame, cropFraction: 0.4, cropOffset: CGPoint(x: 0.3, y: 0))
    XCTAssertLessThan(brightness(left.jpeg), 0.15)
    XCTAssertGreaterThan(brightness(right.jpeg), 0.85)
  }
}

@MainActor
final class HUDRenderTests: XCTestCase {
  private var outDir: URL? {
    ProcessInfo.processInfo.environment["HUD_OUT"].map { URL(fileURLWithPath: $0) }
  }

  private func save(_ image: UIImage, _ name: String) {
    guard let dir = outDir else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? image.pngData()?.write(to: dir.appendingPathComponent("\(name).png"))
  }

  private func pixel(_ image: UIImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    let cg = image.cgImage!
    let data = cg.dataProvider!.data! as Data
    let bpp = cg.bitsPerPixel / 8
    let i = y * cg.bytesPerRow + x * bpp
    return (data[i], data[i + 1], data[i + 2])
  }

  func testSpritesAreBundledAndTheRightSize() {
    XCTAssertEqual(HUDSprites.reticle.size, CGSize(width: 512, height: 512))
    XCTAssertEqual(HUDSprites.bracketsBase.size, CGSize(width: 256, height: 256))
    XCTAssertEqual(HUDSprites.cameraIcon.size, CGSize(width: 32, height: 32))
    for clip in [HUDSprites.idle, HUDSprites.lockOn, HUDSprites.success, HUDSprites.coinSpin] {
      XCTAssertEqual(clip.frames.count, 8)
    }
    XCTAssertEqual(HUDSprites.lockOn.duration, 0.48, accuracy: 0.01)
  }

  func testClipsHoldTheirLastFrameOrLoop() {
    let lock = HUDSprites.lockOn
    XCTAssertTrue(lock.frame(at: 5) === lock.frames.last)
    XCTAssertTrue(lock.isFinished(at: 0.5))
    XCTAssertFalse(HUDSprites.idle.isFinished(at: 100))
    XCTAssertTrue(HUDSprites.idle.frame(at: 0) === HUDSprites.idle.frames[0])
    XCTAssertTrue(HUDSprites.idle.frame(at: 8 * 0.15 + 0.01) === HUDSprites.idle.frames[0])
  }

  func testScreensAre600SquareWithABlackBackground() {
    let screens: [(String, UIImage)] = [
      ("aim", HUDRenderer.aim(zone: HUDSprites.idle.frames[0], streaming: true, caption: "PRESS CAPTURE TO LOOK")),
      ("lock", HUDRenderer.aim(zone: HUDSprites.lockOn.frames[3], streaming: true)),
      ("looking", HUDRenderer.aim(zone: HUDSprites.bracketsBase, streaming: true, coin: HUDSprites.coinSpin.frames[2], caption: "LOOKING…", captionColor: HUDRenderer.Palette.yellow)),
      ("success", HUDRenderer.aim(zone: HUDSprites.success.frames[2], streaming: true)),
      ("pattern", HUDRenderer.testPattern()),
    ]
    for (name, image) in screens {
      XCTAssertEqual(image.size, CGSize(width: 600, height: 600), name)
      XCTAssertEqual(image.scale, 1, name)
      let corner = pixel(image, 300, 590 > 0 ? 3 : 0)  // top middle edge: black except the pattern's frame
      if name != "pattern" { XCTAssertEqual(corner.0 + corner.1 + corner.2, 0, "\(name) must have a pure black background") }
      save(image, name)
    }
  }

  func testCardsGuessAndAccordionRender() {
    let thumb = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { ctx in
      UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
    }
    save(HUDRenderer.card(label: "IS THIS A…", title: "Sony WH-1000XM5?", detail: "HEADPHONES · 90% SURE", footer: "SELECT = YES    BACK = TRY AGAIN", thumbnail: thumb), "confirm")
    save(HUDRenderer.card(label: "IS THIS A…", title: "Honda Civic Hatchback Type R?", detail: "2017–2021 · NOT SURE", footer: "SELECT = YES    BACK = TRY AGAIN", thumbnail: thumb), "confirm-long")
    save(HUDRenderer.card(label: "I THINK THIS IS…", title: "wooden dining chair", detail: "NOT SURE", footer: "SELECT = YES    BACK = TRY AGAIN", body: "A light oak dining chair with a curved backrest and four tapered legs. The seat looks upholstered in beige fabric and there is some wear on the front edge."), "confirm-description")
    save(HUDRenderer.card(label: "OOPS", title: "SOMETHING WENT WRONG", detail: "Cannot reach the server.", footer: "SELECT = TRY AGAIN", accent: HUDRenderer.Palette.red), "error")
    save(HUDRenderer.guess(value: 250, title: "Sony WH-1000XM5 · PRICE IN A SHOP?", hint: "▲▼ BIG STEPS  ◀▶ SMALL  DRAG TURNS\nSELECT = LOCK IN"), "guess")
    save(HUDRenderer.guess(value: 1_250_000, title: "Škoda Octavia · WHAT DOES IT COST?", hint: "SELECT = LOCK IN"), "guess-big")

    let range = LookSnapshot.PriceRange(low: 26_000, median: 28_500, high: 31_000)
    let result = LookSnapshot.GuessResult(guessEur: 18_000, gapEur: -10_500, gapPct: -36.8, verdict: "low", inRange: false, score: 61, summary: "You guessed €18,000. The real range is €26,000 to €31,000, median €28,500. You were 37% low.")
    func state(low: Double, high: Double, range: LookSnapshot.PriceRange?, done: Bool, result: LookSnapshot.GuessResult?, status: String?) -> HUDRenderer.AccordionState {
      .init(title: "Škoda Octavia", guess: 18_000, range: range, bandLow: low, bandHigh: high, done: done, result: result, status: status, usedRange: nil, coin: done ? nil : HUDSprites.coinSpin.frames[1])
    }
    save(HUDRenderer.accordion(state(low: 9_000, high: 27_000, range: nil, done: false, result: nil, status: "READING PRICES… 1/6")), "accordion-open")
    save(HUDRenderer.accordion(state(low: 20_000, high: 29_000, range: range, done: false, result: nil, status: "READING PRICES… 4/6")), "accordion-squeezing")
    save(HUDRenderer.accordion(state(low: 26_000, high: 31_000, range: range, done: true, result: result, status: nil)), "accordion-result")
    let inside = LookSnapshot.GuessResult(guessEur: 28_000, gapEur: -500, gapPct: -1.8, verdict: "close", inRange: true, score: 97, summary: "You guessed €28,000. Spot on.")
    save(HUDRenderer.accordion(.init(title: "Sony WH-1000XM5", guess: 28_000, range: range, bandLow: 26_000, bandHigh: 31_000, done: true, result: inside, status: nil, usedRange: LookSnapshot.PriceRange(low: 18_000, median: 20_000, high: 22_000), coin: nil)), "accordion-spot-on")
  }

  func testVerdictWording() {
    func make(_ verdict: String, _ pct: Double) -> LookSnapshot.GuessResult {
      .init(guessEur: 1, gapEur: 0, gapPct: pct, verdict: verdict, inRange: false, score: 0, summary: "")
    }
    XCTAssertEqual(HUDRenderer.verdict(make("low", -36.8)), "37% LOW")
    XCTAssertEqual(HUDRenderer.verdict(make("high", 14.6)), "15% HIGH")
    XCTAssertEqual(HUDRenderer.verdict(make("close", 2.2)), "SPOT ON! 2% OFF")
  }
}
