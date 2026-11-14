//
// Config.swift
//
// App-wide settings. Edit SERVER_URL when the tunnel URL changes.
//

import Foundation

enum Config {
  /// Base URL of the Price Accordion server (no trailing slash).
  ///
  /// - iOS Simulator: `http://localhost:8000` reaches the Mac running uvicorn.
  /// - Real iPhone: run `cloudflared tunnel --url http://localhost:8000` and paste the
  ///   printed `https://<random>.trycloudflare.com` here. It changes on every restart.
  static let SERVER_URL = "http://localhost:8000"

  /// How long to wait for the server before showing an error. Identification and
  /// price lookup can take several seconds.
  static let requestTimeout: TimeInterval = 60

  /// Share of the frame (width and height) kept around the centre before upload.
  static let centreCropFraction: CGFloat = 0.7

  /// JPEG quality of the uploaded crop.
  static let jpegQuality: CGFloat = 0.8
}
