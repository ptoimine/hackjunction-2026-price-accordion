//
// LookFlowTests.swift
//
// Tests for the "Look" button: on-device crop + JPEG, and the full path from a Mock
// Device frame to the server's /look (needs `uvicorn main:app --port 8000` on the Mac;
// that test is skipped when the server is not reachable).
//

@testable import PriceSense
import MWDATCore
import MWDATMockDevice
import UIKit
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

final class ImagePrivacyTests: XCTestCase {
  private func syntheticFrame(width: Int = 720, height: Int = 1280) -> UIImage {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
      UIColor.systemTeal.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
      UIColor.white.setFill()
      ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    }
  }

  func testCropsTheCentreAndEncodesJPEG() throws {
    let prepared = try ImagePrivacy.prepareForUpload(syntheticFrame())

    XCTAssertEqual(prepared.pixelSize.width, 504, accuracy: 1)  // 70% of 720
    XCTAssertEqual(prepared.pixelSize.height, 896, accuracy: 1)  // 70% of 1280
    XCTAssertEqual(prepared.facesBlurred, 0)
    XCTAssertEqual(Array(prepared.jpeg.prefix(3)), [0xFF, 0xD8, 0xFF], "not a JPEG")

    let decoded = try XCTUnwrap(UIImage(data: prepared.jpeg))
    XCTAssertEqual(decoded.size.width * decoded.scale, 504, accuracy: 1)
    XCTAssertEqual(decoded.size.height * decoded.scale, 896, accuracy: 1)
  }

  func testRotatedFrameIsCroppedInDisplayOrientation() throws {
    // A 1280x720 bitmap marked .right displays as 720x1280.
    let landscape = try XCTUnwrap(syntheticFrame(width: 1280, height: 720).cgImage)
    let rotated = UIImage(cgImage: landscape, scale: 1, orientation: .right)
    let prepared = try ImagePrivacy.prepareForUpload(rotated)
    XCTAssertEqual(prepared.pixelSize.width, 504, accuracy: 1)
    XCTAssertEqual(prepared.pixelSize.height, 896, accuracy: 1)
  }
}

@MainActor
final class LookFlowTests: XCTestCase {
  private var viewModel: CameraViewModel?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()
    MockDeviceKit.shared.enable()
  }

  override func tearDown() async throws {
    viewModel?.endSession()
    viewModel = nil
    await MockDeviceKit.shared.disable()
    try await super.tearDown()
  }

  private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while !condition() {
      if ContinuousClock.now > deadline { return false }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return true
  }

  /// Mock Device frame -> blur/crop/JPEG -> POST /look -> JSON on screen state.
  func testMockDeviceFrameReachesServer() async throws {
    // Skip (not fail) when no server is running.
    var health = URLRequest(url: URL(string: Config.SERVER_URL + "/health")!, timeoutInterval: 3)
    health.httpMethod = "GET"
    do { _ = try await URLSession.shared.data(for: health) } catch {
      throw XCTSkip("Server not reachable at \(Config.SERVER_URL): \(error.localizedDescription)")
    }

    let mock = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
    mock.powerOn()
    mock.don()
    let videoURL = try XCTUnwrap(Bundle.main.url(forResource: "plant", withExtension: "mp4"))
    mock.services.camera.setCameraFeed(fileURL: videoURL)

    let camera = CameraViewModel(wearables: Wearables.shared)
    viewModel = camera
    let deviceReady = await waitUntil(8) { camera.hasActiveDevice }
    XCTAssertTrue(deviceReady, "mock device not detected")

    camera.startSession()
    let sessionReady = await waitUntil(8) { camera.isSessionActive }
    XCTAssertTrue(sessionReady, "session did not start")
    await camera.startStreaming()
    let gotFrame = await waitUntil(15) { camera.isStreaming && camera.currentVideoFrame != nil }
    XCTAssertTrue(gotFrame, "no frame from the mock device")
    let frame = try XCTUnwrap(camera.currentVideoFrame)

    // What the Look button does.
    let look = LookViewModel()
    look.look(at: frame)
    let finished = await waitUntil(30) { !look.isBusy }
    XCTAssertTrue(finished, "Look never finished")

    switch look.state {
    case .result(let result):
      print("LOOK RESULT: HTTP \(result.reply.statusCode), \(result.uploadBytes) bytes, "
        + "\(Int(result.pixelSize.width))x\(Int(result.pixelSize.height)), faces=\(result.facesBlurred)")
      print("LOOK REPLY:\n\(result.reply.text)")
      XCTAssertNotEqual(result.reply.statusCode, 0)
      XCTAssertFalse(result.reply.text.isEmpty)
      XCTAssertEqual(result.pixelSize.width, frame.size.width * frame.scale * HUDCalibration.current().fraction, accuracy: 2)
      XCTAssertEqual(result.pixelSize.height, frame.size.height * frame.scale * HUDCalibration.current().fraction, accuracy: 2)
      XCTAssertNotNil(result.sentImage)
    case .failed(let message):
      XCTFail("Look failed: \(message)")
    default:
      XCTFail("unexpected state \(look.state)")
    }
  }

  /// A car photo through the real Look flow: identification arrives at once, then the view model
  /// polls GET /look/{id} until the server has a price range. Needs the server with Nemotron and
  /// Context.dev keys (a recent lookup is served from the server's 30-minute cache) and a photo of a car
  /// (TEST_RUNNER_PRICE_TEST_PHOTO).
  func testCarPhotoGetsAPriceRangeByPolling() async throws {
    var health = URLRequest(url: URL(string: Config.SERVER_URL + "/health")!, timeoutInterval: 3)
    health.httpMethod = "GET"
    do { _ = try await URLSession.shared.data(for: health) } catch {
      throw XCTSkip("Server not reachable at \(Config.SERVER_URL): \(error.localizedDescription)")
    }
    let data = try TestPhoto.real()  // skips the test when no photo is given
    let frame = try XCTUnwrap(UIImage(data: data))

    let look = LookViewModel()
    look.look(at: frame)

    func settledResult() -> LookResult? {
      if case .result(let r) = look.state, !r.reply.priceIsPending { return r }
      return nil
    }
    let done = await waitUntil(120) { settledResult() != nil }
    XCTAssertTrue(done, "price never settled; last state: \(look.state)")
    let result = try XCTUnwrap(settledResult())
    print("PRICE STATUS: \(result.reply.priceStatus ?? "nil")")
    print("LOOK REPLY:\n\(result.reply.text.prefix(900))")
    XCTAssertEqual(result.reply.priceStatus, "done")
    XCTAssertTrue(result.reply.text.contains("\"median\""))
    XCTAssertNotNil(result.reply.lookID)
  }

  func testUnreachableServerGivesReadableError() async throws {
    let client = LookClient(baseURL: "http://127.0.0.1:9", timeout: 5)
    do {
      _ = try await client.send(jpeg: Data([0xFF, 0xD8, 0xFF]))
      XCTFail("expected an error")
    } catch let error as LookError {
      XCTAssertTrue(error.localizedDescription.contains("Cannot reach the server"), error.localizedDescription)
    }
  }

  func testLookWithoutFrameAsksToStartPreview() {
    let look = LookViewModel()
    look.look(at: nil)
    guard case .failed(let message) = look.state else { return XCTFail("expected failure") }
    XCTAssertTrue(message.contains("Start the preview"))
  }
}
