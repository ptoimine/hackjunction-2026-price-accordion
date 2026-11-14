//
// TestPhoto.swift
//
// Photos for the tests. The repository carries no photo of its own: the live end-to-end tests need a real picture of
// something with a price, which you supply; the other tests only need *a* picture and make one.
//

import UIKit
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

enum TestPhoto {
  /// A real photo of something with a price (a car works best) for the live tests that identify it with Nemotron and price it.
  /// Pass its path with `TEST_RUNNER_PRICE_TEST_PHOTO=/path/to/photo.jpg`; without it those tests are skipped.
  static func real() throws -> Data {
    guard let path = ProcessInfo.processInfo.environment["PRICE_TEST_PHOTO"], let data = FileManager.default.contents(atPath: path) else {
      throw XCTSkip("Set TEST_RUNNER_PRICE_TEST_PHOTO=/path/to/photo.jpg (a photo of a car) to run this live test")
    }
    return data
  }

  /// A plain picture written to a temporary JPEG file, for tests where only the capture path matters, not what is in the picture.
  static func syntheticFile() throws -> URL {
    let size = CGSize(width: 480, height: 640)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.darkGray.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      UIColor.orange.setFill()
      context.fill(CGRect(x: 120, y: 200, width: 240, height: 240))
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("price-sense-test-photo.jpg")
    try XCTUnwrap(image.jpegData(compressionQuality: 0.8)).write(to: url)
    return url
  }
}
