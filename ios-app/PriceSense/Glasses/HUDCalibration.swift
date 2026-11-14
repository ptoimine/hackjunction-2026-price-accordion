//
// HUDCalibration.swift
//
// Where, inside the camera frame, the user is aiming. The glasses' camera sits at the edge of the
// frame and sees a much wider view than the display's ~20 degrees, so the display's aim point is
// not automatically the centre of the camera image (and parallax changes it with distance).
// The Glasses lab lets you nudge this on the real glasses and see the crop that would be sent.
//

import CoreGraphics
import Foundation

/// Where the picture for a look comes from: a frame of the live camera stream, or a standalone photo.
/// The stream is cropped to a narrow 9:16 view and stabilised; a standalone photo is wider and sharper but
/// takes longer (and cannot run at the same time as the stream). Each source has its own calibration.
enum CaptureSource: String, CaseIterable, Sendable {
  case stream
  case photo

  private static let key = "hud.captureSource"

  static var active: CaptureSource {
    get { UserDefaults.standard.string(forKey: key).flatMap(CaptureSource.init(rawValue:)) ?? .stream }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
  }

  var title: String { self == .stream ? "Stream frame" : "Standalone photo" }

  /// A photo already covers a wider view, so less of it needs to be kept.
  var defaultFraction: CGFloat { self == .stream ? Config.centreCropFraction : 0.5 }

  fileprivate var calibrationKey: String { self == .stream ? "hud.calibration.v1" : "hud.calibration.photo.v1" }
}

struct HUDCalibration: Equatable, Sendable {
  /// Share of the picture (each side) that is cropped and sent.
  var fraction: CGFloat = CaptureSource.active.defaultFraction
  /// Moves the crop window, in fractions of the picture (+x right, +y down).
  var offset: CGPoint = .zero

  /// The saved calibration of the active capture source.
  static func current() -> HUDCalibration {
    guard let values = UserDefaults.standard.array(forKey: CaptureSource.active.calibrationKey) as? [Double], values.count == 3 else {
      return HUDCalibration()
    }
    return HUDCalibration(fraction: CGFloat(values[0]), offset: CGPoint(x: values[1], y: values[2])).clamped()
  }

  func save() {
    let c = clamped()
    UserDefaults.standard.set([Double(c.fraction), Double(c.offset.x), Double(c.offset.y)], forKey: CaptureSource.active.calibrationKey)
  }

  static func reset() { UserDefaults.standard.removeObject(forKey: CaptureSource.active.calibrationKey) }

  func clamped() -> HUDCalibration {
    var c = self
    c.fraction = min(0.9, max(0.25, c.fraction))
    let room = (1 - c.fraction) / 2  // how far the window can move before it leaves the picture
    c.offset.x = min(room, max(-room, c.offset.x))
    c.offset.y = min(room, max(-room, c.offset.y))
    return c
  }
}
