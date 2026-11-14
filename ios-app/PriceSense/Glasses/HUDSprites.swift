//
// HUDSprites.swift
//
// The cleaned 8-bit arcade art (design/glasses/process_assets.py writes HUD/*.png): pure black
// background, because on the additive Meta Ray-Ban Display black is transparent. Whole-number
// nearest-neighbour scaling was done in the script; the renderer must not smooth them either.
//

import UIKit

@MainActor
enum HUDSprites {
  /// A short animation: one PNG per frame (the display cannot stream video layered over an image,
  /// so the app composes whole 600x600 screens itself and sends them as images).
  struct Clip {
    let frames: [UIImage]
    let frameDuration: TimeInterval
    let loops: Bool

    var duration: TimeInterval { frameDuration * Double(frames.count) }

    /// The frame to show `elapsed` seconds after the clip started (the last frame is held when it does not loop).
    func frame(at elapsed: TimeInterval) -> UIImage? {
      guard !frames.isEmpty else { return nil }
      let index = Int(max(0, elapsed) / frameDuration)
      return frames[loops ? index % frames.count : min(index, frames.count - 1)]
    }

    func isFinished(at elapsed: TimeInterval) -> Bool { !loops && elapsed >= duration }
  }

  private static func image(_ name: String) -> UIImage {
    guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
      let image = UIImage(contentsOfFile: url.path)
    else {
      assertionFailure("missing HUD asset \(name).png")
      return UIImage()
    }
    return image
  }

  private static func clip(_ name: String, frames: Int, ms: Double, loops: Bool) -> Clip {
    Clip(frames: (0..<frames).map { image("hud_\(name)_\($0)") }, frameDuration: ms / 1000, loops: loops)
  }

  /// 512 px: magenta/cyan corner brackets and a crosshair. The aim point.
  static let reticle = image("hud_reticle")
  /// 256 px yellow brackets: the crop zone.
  static let bracketsBase = image("hud_brackets_base")
  /// 256 px cyan picture frame.
  static let captureFrame = image("hud_capture_frame")
  /// 32 px.
  static let cameraIcon = image("hud_icon_camera")
  static let coin = image("hud_coin")

  static let idle = clip("idle", frames: 8, ms: 150, loops: true)
  static let lockOn = clip("lockon", frames: 8, ms: 60, loops: false)
  static let success = clip("success", frames: 8, ms: 60, loops: false)
  static let coinSpin = clip("coin_spin", frames: 8, ms: 100, loops: true)
}
