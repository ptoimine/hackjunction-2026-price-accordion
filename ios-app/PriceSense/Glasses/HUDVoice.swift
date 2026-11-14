//
// HUDVoice.swift
//
// Spoken answers through whatever the phone's audio goes to (the glasses' speakers when they are the
// Bluetooth output). Uses the iOS on-device voice: nothing is sent anywhere.
//

import AVFoundation

@MainActor
final class HUDVoice {
  static let shared = HUDVoice()
  private let synthesizer = AVSpeechSynthesizer()

  func speak(_ text: String) {
    synthesizer.stopSpeaking(at: .immediate)
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
    synthesizer.speak(utterance)
  }

  func stop() { synthesizer.stopSpeaking(at: .immediate) }
}
