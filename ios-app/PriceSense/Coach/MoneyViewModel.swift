//
// MoneyViewModel.swift
//
// The Coach screen's state: which demo customer is being coached, what the current look's price means for
// them, and the answer to a free-text question. Numbers come from the server (Python); the answer's wording
// from Nemotron, grounded in those numbers.
//

import Observation
import SwiftUI

@Observable
@MainActor
final class MoneyViewModel {
  private(set) var personas: [Persona] = []
  private(set) var reply: MoneyContextReply?
  private(set) var isLoading = false
  private(set) var loadError: String?
  private(set) var coachReply: CoachReply?
  private(set) var askedQuestion: String?
  private(set) var isAsking = false
  private(set) var askError: String?

  /// The customer being coached; nil until the personas are loaded (the server then picks "typical").
  private(set) var customerID: String? = UserDefaults.standard.string(forKey: "coach.customerID")

  private let client = MoneyClient()
  private var lookID: String?
  private var isPreview = false  // sample data: never talks to the server

  var persona: Persona? { personas.first { $0.customerId == (customerID ?? reply?.customerId) } }

  /// A model with a ready answer, for previews and screenshots (no server needed).
  convenience init(preview reply: MoneyContextReply, personas: [Persona], coach: CoachReply? = nil, asked: String? = nil) {
    self.init()
    self.isPreview = true
    self.reply = reply
    self.personas = personas
    self.customerID = reply.customerId
    self.coachReply = coach
    self.askedQuestion = asked
  }

  /// Load what the look's price means for the chosen customer (also fetches the personas the first time).
  func show(lookID: String) async {
    guard !isPreview else { return }
    if self.lookID != lookID {  // a different look: nothing from the last one may linger
      reply = nil
      coachReply = nil
      askedQuestion = nil
      askError = nil
    }
    self.lookID = lookID
    isLoading = true
    loadError = nil
    defer { isLoading = false }
    do {
      if personas.isEmpty { personas = (try? await client.personas()) ?? [] }
      let next = try await client.context(customerID: customerID, lookID: lookID)
      guard self.lookID == lookID else { return }
      reply = next
      if customerID == nil { customerID = next.customerId }
    } catch {
      loadError = error.localizedDescription
    }
  }

  func choose(_ persona: Persona) async {
    guard persona.customerId != customerID, let lookID else { return }
    customerID = persona.customerId
    UserDefaults.standard.set(persona.customerId, forKey: "coach.customerID")
    coachReply = nil
    askedQuestion = nil
    await show(lookID: lookID)
  }

  func ask(_ question: String) async {
    let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard question.count >= 2, !isAsking else { return }
    isAsking = true
    askError = nil
    askedQuestion = question
    coachReply = nil
    defer { isAsking = false }
    do {
      coachReply = try await client.ask(customerID: customerID, lookID: lookID, question: question)
    } catch {
      askError = error.localizedDescription
    }
  }

  func reset() {
    lookID = nil
    reply = nil
    coachReply = nil
    askedQuestion = nil
    loadError = nil
    askError = nil
  }
}
