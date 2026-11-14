//
// GlassesRigMockTests.swift
//
// The glasses HUD end to end against Meta's mock Ray-Ban Display: the display and inputs attach to the
// real DAT session, screens are sent, and mock touchpad / band / button events drive the flow.
// The last test runs the whole lesson (needs the server and a car video: $HUD_CAR_VIDEO).
//

@testable import PriceSense
import Foundation
import MWDATCamera
import MWDATCore
import MWDATMockDevice
import UIKit
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

@MainActor
final class GlassesRigMockTests: XCTestCase {
  private var glasses: MockGlasses!
  private var viewModel: CameraViewModel!
  private var look: LookViewModel!

  override func setUp() async throws {
    try await super.setUp()
    CaptureSource.active = .stream
    try? Wearables.configure()
    MockDeviceKit.shared.enable()
    glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
    glasses.powerOn()
    glasses.don()
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }

  override func tearDown() async throws {
    CaptureSource.active = .stream
    viewModel?.endSession()
    viewModel = nil
    look = nil
    await MockDeviceKit.shared.disable()
    glasses = nil
    try await super.tearDown()
  }

  private func until(_ timeout: TimeInterval, _ what: String = "", file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while !condition() {
      if ContinuousClock.now > deadline {
        XCTFail("Not within \(timeout) s: \(what)", file: file, line: line)
        return
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  private func start(feed url: URL) async {
    glasses.services.camera.setCameraFeed(fileURL: url)
    let vm = CameraViewModel(wearables: Wearables.shared)
    let look = LookViewModel()
    viewModel = vm
    self.look = look
    vm.rig.configure(look: look, capture: { await vm.captureForLook() }, ready: { vm.canLook })
    await until(5, "device") { vm.hasActiveDevice }
    vm.startGlassesHUD()
    await until(20, "display ready") { vm.rig.display.isReady }
  }

  private var plant: URL { Bundle.main.url(forResource: "plant", withExtension: "mp4")! }

  func testDisplayAndInputsAttachAndTheAimScreenIsSent() async throws {
    await start(feed: plant)
    let rig = viewModel.rig
    XCTAssertEqual(rig.display.stateText, "ready")
    await until(5, "flow running") { rig.flow.isRunning }
    await until(5, "inputs active") { rig.inputs.stateText == "active" }
    await until(5, "first screen sent") { rig.display.sendCount > 0 }
    XCTAssertEqual(rig.flow.phase, .aim)
    XCTAssertNil(rig.display.lastError)
  }

  func testMockInputsAreReceivedAndLogged() async throws {
    await start(feed: plant)
    let rig = viewModel.rig
    await until(5, "inputs active") { rig.inputs.stateText == "active" }
    glasses.services.input.navUp(source: .neuralBand)
    glasses.services.input.capture(pressType: .doublePress)
    await until(5, "two events") { rig.inputs.eventCount >= 2 }
    let log = rig.inputs.log.joined(separator: "\n")
    XCTAssertTrue(log.contains("nav up"), log)
    XCTAssertTrue(log.contains("capture doublePress"), log)
  }

  func testCaptureButtonStartsALookWhenTheCameraIsStreaming() async throws {
    await start(feed: plant)
    let rig = viewModel.rig
    await until(30, "camera frames") { self.viewModel.isStreaming && self.viewModel.currentVideoFrame != nil }
    glasses.services.input.capture(pressType: .shortPress)
    await until(5, "lock phase") { rig.flow.phase.name != "aim" }
    XCTAssertTrue(["lock", "looking", "failed", "success", "confirm", "not priceable"].contains(rig.flow.phase.name), rig.flow.phase.name)
  }

  func testLookingWithoutAStreamShowsANotice() async throws {
    await start(feed: plant)
    let rig = viewModel.rig
    viewModel.stopStreaming()
    await until(10, "stream stopped") { !self.viewModel.isStreaming }
    glasses.services.input.select(source: .captouch)
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(rig.flow.phase, .aim, "no frame: stay aiming")
  }

  /// The whole lesson from the lens: capture -> "Is this a …?" -> select -> dial the guess -> select -> accordion.
  func testWholeLessonFromTheLens() async throws {
    var health = URLRequest(url: URL(string: Config.SERVER_URL + "/health")!, timeoutInterval: 3)
    health.httpMethod = "GET"
    do { _ = try await URLSession.shared.data(for: health) } catch {
      throw XCTSkip("Server not reachable at \(Config.SERVER_URL)")
    }
    guard let path = ProcessInfo.processInfo.environment["HUD_CAR_VIDEO"], FileManager.default.fileExists(atPath: path) else {
      throw XCTSkip("Set TEST_RUNNER_HUD_CAR_VIDEO to a car video")
    }
    await start(feed: URL(fileURLWithPath: path))
    let rig = viewModel.rig
    let input = glasses.services.input
    await until(30, "camera frames") { self.viewModel.isStreaming && self.viewModel.currentVideoFrame != nil }

    input.capture(pressType: .shortPress)
    await until(90, "confirm card; phase is \(rig.flow.phase.name)") { rig.flow.phase == .confirm || rig.flow.phase.name == "not priceable" || rig.flow.phase.name == "failed" }
    XCTAssertEqual(rig.flow.phase, .confirm, "the car should be identified and ask for a yes")

    input.select(source: .neuralBand)  // yes, that is it
    await until(15, "guess dial") { rig.flow.phase == .guess }
    let start = rig.flow.dial.value
    XCTAssertEqual(start, 15_000)
    try await Task.sleep(nanoseconds: 400_000_000)
    input.navUp(source: .captouch)  // +5,000
    await until(3, "dial up") { rig.flow.dial.value == start + 5_000 }
    input.navLeft(source: .captouch)  // -1,000 (fine)
    await until(3, "dial fine down") { rig.flow.dial.value == start + 4_000 }
    input.drag(action: .down, x: 0, y: 0, dx: 0, dy: 0)
    input.drag(action: .move, x: 10, y: 0, dx: 40, dy: 0)  // a pinch-and-drag to the right turns it up
    await until(3, "drag turned the dial") { rig.flow.dial.value > start + 4_000 }
    let locked = rig.flow.dial.value

    try await Task.sleep(nanoseconds: 400_000_000)
    input.select(source: .neuralBand)  // lock in
    await until(15, "accordion") { rig.flow.phase == .accordion }
    await until(15, "guess locked") { self.look.lockedGuess == locked }
    await until(120, "comparison") { self.look.state.resultValue?.snapshot?.guess?.result != nil }
    XCTAssertNil(rig.display.lastError)
    XCTAssertGreaterThan(rig.display.sendCount, 10, "the squeeze animation should have produced several sends")

    try await Task.sleep(nanoseconds: 500_000_000)  // presses within 350 ms count once
    input.select(source: .captouch)  // look at something else
    await until(5, "back to aim") { rig.flow.phase == .aim }
  }

  /// What the (mock) lens shows for our full-screen image: written to $HUD_OUT/mock-lens-*.png.
  func testMockLensShowsTheScreenWeSend() async throws {
    await start(feed: plant)
    let rig = viewModel.rig
    rig.flow.stop()
    let preview = glasses.services.display.createPreviewView()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 700))
    window.backgroundColor = .darkGray
    let host = UIViewController()
    window.rootViewController = host
    host.view.addSubview(preview)
    preview.frame = host.view.bounds
    window.makeKeyAndVisible()

    func snapshot(_ name: String) async {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      preview.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(bounds: preview.bounds).image { _ in
        preview.drawHierarchy(in: preview.bounds, afterScreenUpdates: true)
      }
      if let dir = ProcessInfo.processInfo.environment["HUD_OUT"] {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("mock-lens-\(name).png"))
      }
    }
    rig.display.show(HUDRenderer.testPattern())
    await snapshot("pattern")
    rig.display.show(HUDRenderer.aim(zone: HUDSprites.idle.frames[0], streaming: true, caption: "PRESS CAPTURE TO LOOK"))
    await snapshot("aim")
    rig.display.showNativeTest { _ in }
    await snapshot("native")
    XCTAssertNil(rig.display.lastError)
  }

  // MARK: - Standalone photo mode

  /// Any picture will do here: these tests are about the capture path, not about what is in the photo.
  private var carPhoto: URL? { try? TestPhoto.syntheticFile() }

  private func startPhotoMode(photo url: URL) async {
    CaptureSource.active = .photo
    glasses.services.cameraCapture.setCapturedPhoto(fileURL: url)
    await start(feed: plant)
    await until(15, "photo capability started") { self.viewModel.canLook }
  }

  func testPhotoModeHasNoStreamAndTakesAStill() async throws {
    let url = try XCTUnwrap(carPhoto)
    await startPhotoMode(photo: url)
    XCTAssertEqual(viewModel.photoState, .started)
    XCTAssertFalse(viewModel.isStreaming, "the stream must be off in photo mode")
    let image = await viewModel.captureForLook()
    XCTAssertNotNil(image, viewModel.lastPhotoInfo)
    XCTAssertFalse(viewModel.isTakingPhoto)
    XCTAssertFalse(viewModel.lastPhotoInfo.hasPrefix("failed"), viewModel.lastPhotoInfo)
  }

  func testSwitchingTheSourceAtRuntimeKeepsTheCameraWorking() async throws {
    let url = try XCTUnwrap(carPhoto)
    glasses.services.cameraCapture.setCapturedPhoto(fileURL: url)
    await start(feed: plant)
    await until(30, "stream frames") { self.viewModel.canLook }
    await viewModel.setCaptureSource(.photo)
    await until(15, "photo mode ready") { self.viewModel.canLook && self.viewModel.photoState == .started }
    XCTAssertFalse(viewModel.isStreaming)
    await viewModel.setCaptureSource(.stream)
    await until(30, "stream back") { self.viewModel.canLook && self.viewModel.isStreaming }
    XCTAssertEqual(viewModel.photoState, .stopped)
  }

  func testCaptureButtonTakesAPhotoAndStartsALook() async throws {
    let url = try XCTUnwrap(carPhoto)
    await startPhotoMode(photo: url)
    await until(5, "flow running") { self.viewModel.rig.flow.isRunning }
    glasses.services.input.capture(pressType: .shortPress)
    await until(30, "a look was started from the photo") { self.look.hasContent }
    XCTAssertNotEqual(viewModel.rig.flow.phase.name, "aim")
  }

  func testCalibrationIsSeparatePerSource() {
    CaptureSource.active = .stream
    HUDCalibration.reset()
    HUDCalibration(fraction: 0.6, offset: CGPoint(x: 0.1, y: 0)).save()
    CaptureSource.active = .photo
    HUDCalibration.reset()
    XCTAssertEqual(HUDCalibration.current().fraction, 0.5, accuracy: 0.001, "a photo keeps less of a wider view")
    XCTAssertEqual(HUDCalibration.current().offset, .zero)
    HUDCalibration(fraction: 0.4, offset: CGPoint(x: -0.05, y: 0.05)).save()
    CaptureSource.active = .stream
    XCTAssertEqual(HUDCalibration.current().offset.x, 0.1, accuracy: 0.001)
    HUDCalibration.reset()
    CaptureSource.active = .photo
    HUDCalibration.reset()
    CaptureSource.active = .stream
  }

  // MARK: - Back from the temple

  func testBackSwipeCanBeLearnedFromTheFirstSwipe() async throws {
    UserDefaults.standard.removeObject(forKey: "hud.backDirection")
    await start(feed: plant)
    let flow = viewModel.rig.flow
    await until(5, "inputs active") { self.viewModel.rig.inputs.stateText == "active" }
    XCTAssertEqual(flow.backDirection, .down)
    flow.learnBackSwipe()
    glasses.services.input.navLeft(source: .captouch)
    await until(5, "learned") { flow.backDirection == .left }
    XCTAssertFalse(flow.isLearningBackSwipe)
    UserDefaults.standard.removeObject(forKey: "hud.backDirection")
  }

  /// Swipes go back from the confirm card, and twice (the back swipe) from the guess dial.
  func testSwipesGoBackFromConfirmAndFromTheDial() async throws {
    var health = URLRequest(url: URL(string: Config.SERVER_URL + "/health")!, timeoutInterval: 3)
    health.httpMethod = "GET"
    do { _ = try await URLSession.shared.data(for: health) } catch { throw XCTSkip("Server not reachable") }
    guard let path = ProcessInfo.processInfo.environment["HUD_CAR_VIDEO"], FileManager.default.fileExists(atPath: path) else {
      throw XCTSkip("Set TEST_RUNNER_HUD_CAR_VIDEO to a car video")
    }
    UserDefaults.standard.removeObject(forKey: "hud.backDirection")
    await start(feed: URL(fileURLWithPath: path))
    let rig = viewModel.rig
    let input = glasses.services.input
    await until(30, "camera frames") { self.viewModel.canLook }

    input.capture(pressType: .shortPress)
    await until(90, "confirm card") { rig.flow.phase == .confirm }
    try await Task.sleep(nanoseconds: 500_000_000)
    input.navRight(source: .captouch)  // any swipe goes back from the confirm card
    await until(5, "back to aim") { rig.flow.phase == .aim }

    try await Task.sleep(nanoseconds: 500_000_000)
    input.capture(pressType: .shortPress)
    await until(90, "confirm card again") { rig.flow.phase == .confirm }
    try await Task.sleep(nanoseconds: 500_000_000)
    input.select(source: .captouch)
    await until(15, "guess dial") { rig.flow.phase == .guess }
    try await Task.sleep(nanoseconds: 500_000_000)
    input.navDown(source: .captouch)  // the back swipe once only turns the dial down
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(rig.flow.phase, .guess)
    XCTAssertLessThan(rig.flow.dial.value, 15_000)
    input.navDown(source: .captouch)  // twice within 0.8 s: back
    await until(5, "back to aim from the dial") { rig.flow.phase == .aim }
  }
}
