//
// HUDMirrorView.swift
//
// A full-screen copy of whatever the lens is showing, on pure black, so the iPhone's own screen recording
// captures the HUD for a demo video. Tap anywhere to close. The screen stays awake while it is open.
//

import SwiftUI
import UIKit

struct HUDMirrorView: View {
  var display: GlassesDisplay
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if let image = display.lastImage {
        Image(uiImage: image)
          .resizable()
          .interpolation(.none)
          .aspectRatio(1, contentMode: .fit)
      } else {
        Text("Nothing on the lens yet")
          .font(.system(size: 20, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.cyan)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { dismiss() }
    .statusBarHidden()
    .persistentSystemOverlays(.hidden)
    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
  }
}
