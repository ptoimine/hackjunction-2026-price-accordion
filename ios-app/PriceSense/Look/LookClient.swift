//
// LookClient.swift
//
// POSTs the prepared JPEG to SERVER_URL/look. The body is the raw JPEG
// (`Content-Type: image/jpeg`); the server answers with JSON.
//

import Foundation

struct LookReply: Sendable {
  let statusCode: Int
  /// Pretty-printed JSON when the body parses as JSON, otherwise the raw text.
  let text: String
  let elapsed: TimeInterval
  /// Id of the look on the server (`look_id`), used to poll for the price.
  var lookID: String? = nil
  /// `price.status` from the server: searching | reading | done | insufficient | failed | skipped | unavailable.
  var priceStatus: String? = nil
  /// The reply decoded for the UI (nil when the body is not a look, e.g. an error response).
  var snapshot: LookSnapshot? = nil

  var isSuccess: Bool { (200..<300).contains(statusCode) }
  /// The server is still looking up listings; poll GET /look/{id}.
  var priceIsPending: Bool { lookID != nil && (priceStatus == "searching" || priceStatus == "reading") }
}

enum LookError: LocalizedError {
  case badServerURL(String)
  case timedOut(seconds: Int)
  case cannotReachServer(String)
  case other(String)

  var errorDescription: String? {
    switch self {
    case .badServerURL(let url): return "SERVER_URL is not a valid URL: \(url)"
    case .timedOut(let seconds): return "The server did not answer within \(seconds) s. It may still be thinking; try again."
    case .cannotReachServer(let url): return "Cannot reach the server at \(url). Is uvicorn running, and is SERVER_URL in Config.swift the current tunnel URL?"
    case .other(let message): return message
    }
  }
}

/// What the user says it is, sent to POST /confirm.
struct IdentityInput: Sendable, Equatable {
  var kind: String  // car | headphones | phone | laptop
  var make: String
  var model: String
  var variant: String? = nil  // products: storage or screen size
  var yearFrom: Int? = nil  // cars
  var yearTo: Int? = nil
}

struct LookClient: Sendable {
  var baseURL: String = Config.SERVER_URL
  var timeout: TimeInterval = Config.requestTimeout

  func send(jpeg: Data) async throws -> LookReply {
    var request = try makeRequest(path: ["look"], method: "POST")
    request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
    return try await perform(request) { try await URLSession.shared.upload(for: request, from: jpeg) }
  }

  /// Current state of a look (identification + price so far). Poll while `priceIsPending`.
  func fetch(lookID: String) async throws -> LookReply {
    let request = try makeRequest(path: ["look", lookID], method: "GET", timeout: 15)
    return try await perform(request) { try await URLSession.shared.data(for: request) }
  }

  /// Confirm or correct what the model saw (POST /confirm). The server restarts the price lookup if it changed.
  func confirm(lookID: String, identity: IdentityInput) async throws -> LookReply {
    var request = try makeRequest(path: ["confirm"], method: "POST", timeout: 15)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = ["look_id": lookID, "kind": identity.kind, "make": identity.make, "model": identity.model]
    if let variant = identity.variant, !variant.isEmpty { body["variant"] = variant }
    if let from = identity.yearFrom { body["year_from"] = from }
    if let to = identity.yearTo { body["year_to"] = to }
    let data = try JSONSerialization.data(withJSONObject: body)
    let reply = try await perform(request) { try await URLSession.shared.upload(for: request, from: data) }
    guard reply.isSuccess else {
      throw LookError.other("Could not use that (HTTP \(reply.statusCode)). \(reply.text.prefix(160))")
    }
    return reply
  }

  /// Lock in the user's guess for a look (POST /guess). The server refuses to change it later.
  func submitGuess(lookID: String, euros: Int) async throws {
    var request = try makeRequest(path: ["guess"], method: "POST", timeout: 15)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body = try JSONSerialization.data(withJSONObject: ["look_id": lookID, "guess_eur": euros])
    let reply = try await perform(request) { try await URLSession.shared.upload(for: request, from: body) }
    guard reply.isSuccess else {
      throw LookError.other("Could not lock in the guess (HTTP \(reply.statusCode)). \(reply.text.prefix(160))")
    }
  }

  private func makeRequest(path: [String], method: String, timeout: TimeInterval? = nil) throws -> URLRequest {
    guard var url = URL(string: baseURL), url.scheme != nil else { throw LookError.badServerURL(baseURL) }
    for part in path { url = url.appendingPathComponent(part) }
    var request = URLRequest(url: url, timeoutInterval: timeout ?? self.timeout)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private func perform(
    _ request: URLRequest, _ transport: () async throws -> (Data, URLResponse)
  ) async throws -> LookReply {
    let started = Date()
    do {
      let (data, response) = try await transport()
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let fields = Self.fields(data)
      return LookReply(
        statusCode: status, text: Self.render(data), elapsed: Date().timeIntervalSince(started),
        lookID: fields.lookID, priceStatus: fields.priceStatus,
        snapshot: (200..<300).contains(status) ? LookSnapshot.decode(data) : nil)
    } catch let error as URLError {
      switch error.code {
      case .timedOut: throw LookError.timedOut(seconds: Int(timeout))
      case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
        throw LookError.cannotReachServer(baseURL)
      default: throw LookError.other(error.localizedDescription)
      }
    }
  }

  private static func fields(_ data: Data) -> (lookID: String?, priceStatus: String?) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
    let price = object["price"] as? [String: Any]
    return (object["look_id"] as? String, price?["status"] as? String)
  }

  private static func render(_ data: Data) -> String {
    if data.isEmpty { return "(empty response)" }
    if let object = try? JSONSerialization.jsonObject(with: data),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      let text = String(data: pretty, encoding: .utf8)
    {
      return text
    }
    return String(data: data, encoding: .utf8) ?? "(\(data.count) bytes, not text)"
  }
}
