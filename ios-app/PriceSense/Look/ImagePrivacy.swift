//
// ImagePrivacy.swift
//
// On-device preparation of a camera frame before anything leaves the phone
// (CLAUDE.md hard rule 1): blur faces with Apple Vision, crop to the centre of the
// frame, JPEG-encode. Faces are detected on the FULL frame and blurred before the
// crop, so a face that is only partly inside the crop is still blurred.
//
// Not covered yet: licence plates (Vision has no plate detector; would need text
// recognition).
//

import CoreImage
import CoreML
import UIKit
import Vision

enum ImagePrivacyError: LocalizedError {
  case unreadableImage
  case renderFailed
  case encodeFailed

  var errorDescription: String? {
    switch self {
    case .unreadableImage: return "The camera frame could not be read."
    case .renderFailed: return "The frame could not be processed."
    case .encodeFailed: return "The frame could not be encoded as JPEG."
    }
  }
}

struct PreparedImage: Sendable {
  let jpeg: Data
  let facesBlurred: Int
  let pixelSize: CGSize
}

enum ImagePrivacy {
  /// Shared: creating a CIContext is expensive. CIContext is thread-safe.
  private static let ciContext = CIContext()

  /// Blur faces, crop the centre `cropFraction`, return JPEG data. CPU/GPU heavy,
  /// call off the main actor.
  static func prepareForUpload(
    _ frame: UIImage,
    cropFraction: CGFloat = Config.centreCropFraction,
    cropOffset: CGPoint = .zero,
    jpegQuality: CGFloat = Config.jpegQuality
  ) throws -> PreparedImage {
    guard let upright = uprightCGImage(frame) else { throw ImagePrivacyError.unreadableImage }
    let width = CGFloat(upright.width)
    let height = CGFloat(upright.height)

    // 1. Faces on the full frame. Vision boxes are normalized, origin bottom-left,
    //    which matches Core Image's coordinate space.
    let faceBoxes = try detectFaces(in: upright).map { box -> CGRect in
      VNImageRectForNormalizedRect(box, upright.width, upright.height)
        .insetBy(dx: -box.width * width * 0.25, dy: -box.height * height * 0.25)  // 25% margin each side
        .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    // 2. Blur those regions.
    let source = CIImage(cgImage: upright)
    var output = source
    if !faceBoxes.isEmpty {
      let blurSigma = max(12, max(width, height) / 40)
      let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: blurSigma)
      for rect in faceBoxes {
        output = blurred.cropped(to: rect).composited(over: output)
      }
    }

    // 3. Centre crop (Core Image origin is bottom-left; the centre is symmetric).
    // `cropOffset` moves the window (fractions of the frame, +x right, +y down). The glasses' camera
    // does not look exactly where the display's aim point is, so the HUD can calibrate this.
    let cropWidth = width * cropFraction
    let cropHeight = height * cropFraction
    let centreX = width / 2 + cropOffset.x * width
    let centreYFromTop = height / 2 + cropOffset.y * height
    let cropRect = CGRect(
      x: min(max(0, centreX - cropWidth / 2), width - cropWidth),
      y: min(max(0, height - centreYFromTop - cropHeight / 2), height - cropHeight),
      width: cropWidth,
      height: cropHeight
    ).integral
    guard let cropped = ciContext.createCGImage(output, from: cropRect) else {
      throw ImagePrivacyError.renderFailed
    }

    // 4. JPEG.
    guard let jpeg = UIImage(cgImage: cropped).jpegData(compressionQuality: jpegQuality) else {
      throw ImagePrivacyError.encodeFailed
    }
    return PreparedImage(
      jpeg: jpeg,
      facesBlurred: faceBoxes.count,
      pixelSize: CGSize(width: cropped.width, height: cropped.height)
    )
  }

  // MARK: - Private

  private static func detectFaces(in image: CGImage) throws -> [CGRect] {
    let request = VNDetectFaceRectanglesRequest()
    #if targetEnvironment(simulator)
      // The simulator cannot create Vision's default inference context ("Could not
      // create inference context"); run on the CPU there. Real devices use the default.
      for (stage, devices) in try request.supportedComputeStageDevices {
        if let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
          request.setComputeDevice(cpu, for: stage)
        }
      }
    #endif
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).map(\.boundingBox)
  }

  /// A CGImage with `.up` orientation, so Vision and the crop see the pixels the way
  /// the user sees them.
  private static func uprightCGImage(_ image: UIImage) -> CGImage? {
    if image.imageOrientation == .up, let cg = image.cgImage { return cg }
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
    return renderer.image { _ in image.draw(at: .zero) }.cgImage
  }
}
