//
// LookViewModel.swift
//
// Look -> Confirm -> Guess -> Accordion:
//   1. current frame -> blur faces + crop centre 60% + JPEG (all on device) -> POST /look
//   2. the identification comes back at once; the server reads shop or listing pages in the background
//   3. the user CONFIRMS or corrects what it is (POST /confirm): the model can be wrong, and a
//      correction restarts the price lookup for the right thing
//   4. the user locks in a price GUESS (POST /guess) before seeing any price
//   5. the app polls GET /look/{id}; the price range narrows as sources answer (the accordion
//      squeezes) and, once final, the server's comparison of guess and price arrives
//

import Observation
import SwiftUI
import UIKit

struct LookResult {
  let reply: LookReply
  let facesBlurred: Int
  let uploadBytes: Int
  let pixelSize: CGSize
  /// Exactly what was uploaded, so the user can see the crop and the blur.
  let sentImage: UIImage?

  var snapshot: LookSnapshot? { reply.snapshot }
}

@Observable
@MainActor
final class LookViewModel {
  enum State {
    case idle
    case preparing
    case uploading
    case result(LookResult)
    case failed(String)
  }

  private(set) var state: State = .idle
  /// The user said "yes, that is it" or told us what it is. The guess comes after this.
  private(set) var identityConfirmed = false
  private(set) var isConfirming = false
  private(set) var confirmError: String?
  /// The user's locked-in guess in whole euros; the price is only shown after this is set.
  private(set) var lockedGuess: Int?
  private(set) var isLockingGuess = false
  private(set) var guessError: String?

  private var task: Task<Void, Never>?
  private var pollTask: Task<Void, Never>?
  private var activeLookID: String?
  private var baseResult: LookResult?
  /// Looks whose finished guess is already in the Score history.
  private var recordedLooks = Set<String>()
  private let client = LookClient()

  /// The accordion springs when the range changes.
  private static let squeeze = Animation.spring(response: 0.8, dampingFraction: 0.82)

  var isBusy: Bool {
    switch state {
    case .preparing, .uploading: return true
    default: return false
    }
  }

  var hasContent: Bool {
    if case .idle = state { return false }
    return true
  }

  func look(at frame: UIImage?) {
    guard !isBusy else { return }
    guard let frame else {
      state = .failed("No camera frame yet. Start the preview first.")
      return
    }
    task?.cancel()  // a new look replaces any price lookup still being polled
    pollTask?.cancel()
    identityConfirmed = false
    confirmError = nil
    lockedGuess = nil
    guessError = nil
    activeLookID = nil
    baseResult = nil
    state = .preparing
    task = Task { [client] in
      do {
        // Vision + Core Image + JPEG off the main actor.
        let crop = HUDCalibration.current()
        let prepared = try await Task.detached(priority: .userInitiated) {
          try ImagePrivacy.prepareForUpload(frame, cropFraction: crop.fraction, cropOffset: crop.offset)
        }.value
        try Task.checkCancellation()

        state = .uploading
        let reply = try await client.send(jpeg: prepared.jpeg)
        let result = LookResult(
          reply: reply,
          facesBlurred: prepared.facesBlurred,
          uploadBytes: prepared.jpeg.count,
          pixelSize: prepared.pixelSize,
          sentImage: UIImage(data: prepared.jpeg)
        )
        activeLookID = reply.lookID
        baseResult = result
        state = .result(result)

        // The identification came back at once; the price is looked up in the background on the
        // server and narrows as sources answer. Poll until it settles.
        if reply.priceIsPending, let lookID = reply.lookID {
          startPolling(lookID: lookID, client: client)
        }
      } catch is CancellationError {
        state = .idle
      } catch {
        state = .failed(error.localizedDescription)
      }
    }
  }

  /// "Yes, that is it": confirm what the model saw as it is.
  func confirmIdentity() {
    guard case .result(let result) = state, let id = result.snapshot?.identification, id.isPriceable,
      let model = id.model
    else { return }
    submitIdentity(
      IdentityInput(
        kind: id.kind, make: id.make ?? "", model: model, variant: id.variant,
        yearFrom: id.yearRange?.first, yearTo: id.yearRange?.last))
  }

  /// Confirm or correct what it is. The server restarts the price lookup if anything changed.
  func submitIdentity(_ identity: IdentityInput) {
    guard !isConfirming, case .result(let result) = state, let lookID = result.reply.lookID else { return }
    isConfirming = true
    confirmError = nil
    Task { [client] in
      defer { isConfirming = false }
      do {
        let reply = try await client.confirm(lookID: lookID, identity: identity)
        guard activeLookID == lookID else { return }
        apply(reply)
        identityConfirmed = true
        startPolling(lookID: lookID, client: client)  // the lookup may have been restarted
      } catch {
        confirmError = error.localizedDescription
      }
    }
  }

  /// Lock in the guess. After this the app may show the price (guess first, then see).
  func lockGuess(_ euros: Int) {
    guard euros > 0, identityConfirmed, lockedGuess == nil, !isLockingGuess,
      case .result(let result) = state, let lookID = result.reply.lookID
    else { return }
    isLockingGuess = true
    guessError = nil
    Task { [client] in
      defer { isLockingGuess = false }
      do {
        try await client.submitGuess(lookID: lookID, euros: euros)
        guard activeLookID == lookID else { return }  // dismissed or replaced meanwhile
        lockedGuess = euros
        // Fetch right away: if the price is already final, the comparison is waiting.
        _ = await refresh(lookID: lookID, client: client)
      } catch {
        guessError = error.localizedDescription
      }
    }
  }

  // MARK: - Polling

  private func startPolling(lookID: String, client: LookClient) {
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      await self?.pollPrice(lookID: lookID, client: client)
    }
  }

  /// Poll GET /look/{id} every 1.5 s (up to ~90 s) and refresh the card as the price narrows.
  private func pollPrice(lookID: String, client: LookClient) async {
    for _ in 0..<60 {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      if Task.isCancelled { return }
      guard let reply = try? await client.fetch(lookID: lookID) else { continue }  // transient: keep trying
      if reply.statusCode == 404 { return }  // expired on the server
      guard reply.isSuccess, activeLookID == lookID else { continue }
      apply(reply)
      if !reply.priceIsPending { return }
    }
  }

  private func refresh(lookID: String, client: LookClient) async -> LookReply? {
    guard let reply = try? await client.fetch(lookID: lookID), reply.isSuccess, activeLookID == lookID else {
      return nil
    }
    apply(reply)
    return reply
  }

  private func apply(_ reply: LookReply) {
    guard let base = baseResult else { return }
    recordScore(reply.snapshot)
    withAnimation(Self.squeeze) {
      state = .result(
        LookResult(
          reply: reply, facesBlurred: base.facesBlurred, uploadBytes: base.uploadBytes,
          pixelSize: base.pixelSize, sentImage: base.sentImage))
    }
  }

  /// Once the server has compared guess and price, keep it for the Score screen (one entry per look).
  private func recordScore(_ snapshot: LookSnapshot?) {
    guard let snapshot, let result = snapshot.guess?.result, let range = snapshot.price.range,
      recordedLooks.insert(snapshot.lookId).inserted
    else { return }
    ScoreStore.shared.record(
      ScoreEntry(
        id: snapshot.lookId, date: Date(), kind: snapshot.identification.kind, name: snapshot.identification.title,
        guessEur: result.guessEur, medianEur: range.median, gapPct: result.gapPct, score: result.score,
        verdict: result.verdict, inRange: result.inRange))
  }

  func dismiss() {
    task?.cancel()
    task = nil
    pollTask?.cancel()
    pollTask = nil
    activeLookID = nil
    baseResult = nil
    identityConfirmed = false
    confirmError = nil
    lockedGuess = nil
    guessError = nil
    state = .idle
  }
}
