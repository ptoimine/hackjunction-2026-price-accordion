//
// MoneyClient.swift
//
// GET /money/personas, POST /money/context, POST /coach. The look's price median is used server-side, so
// the phone only sends the look id and the customer it is coaching.
//

import Foundation

enum MoneyError: LocalizedError {
  case server(String)
  case unreadable
  case unreachable

  var errorDescription: String? {
    switch self {
    case .server(let message): return message
    case .unreadable: return "The coach's answer could not be read."
    case .unreachable: return "Cannot reach the server. Is it running, and is SERVER_URL current?"
    }
  }
}

struct MoneyClient: Sendable {
  var baseURL: String = Config.SERVER_URL
  var timeout: TimeInterval = 40

  func personas() async throws -> [Persona] {
    let data = try await send(path: "money/personas", method: "GET", body: nil)
    return try decoded(PersonaList.self, from: data).personas
  }

  /// What the look's price (its median) means for this customer. `customerID` nil = the server's default persona.
  func context(customerID: String?, lookID: String) async throws -> MoneyContextReply {
    var body: [String: Any] = ["look_id": lookID]
    if let customerID { body["customer_id"] = customerID }
    let data = try await send(path: "money/context", method: "POST", body: body)
    guard let reply = MoneyContextReply.decode(data) else { throw MoneyError.unreadable }
    return reply
  }

  func ask(customerID: String?, lookID: String?, question: String) async throws -> CoachReply {
    var body: [String: Any] = ["question": question]
    if let customerID { body["customer_id"] = customerID }
    if let lookID { body["look_id"] = lookID }
    let data = try await send(path: "coach", method: "POST", body: body)
    return try decoded(CoachReply.self, from: data)
  }

  // MARK: - Private

  private func decoded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let value = try? decoder.decode(type, from: data) else { throw MoneyError.unreadable }
    return value
  }

  private func send(path: String, method: String, body: [String: Any]?) async throws -> Data {
    guard var url = URL(string: baseURL), url.scheme != nil else { throw MoneyError.server("SERVER_URL is not a valid URL: \(baseURL)") }
    for part in path.split(separator: "/") { url = url.appendingPathComponent(String(part)) }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (data, response): (Data, URLResponse)
      if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        (data, response) = try await URLSession.shared.upload(for: request, from: JSONSerialization.data(withJSONObject: body))
      } else {
        (data, response) = try await URLSession.shared.data(for: request)
      }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(status) else { throw MoneyError.server(Self.message(from: data, status: status)) }
      return data
    } catch let error as MoneyError {
      throw error
    } catch let error as URLError {
      switch error.code {
      case .timedOut: throw MoneyError.server("The coach took too long to answer. Try again.")
      case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
        throw MoneyError.unreachable
      default: throw MoneyError.server(error.localizedDescription)
      }
    }
  }

  /// FastAPI errors are `{"detail": "text"}` or `{"detail": {"message": "text"}}`.
  static func message(from data: Data, status: Int) -> String {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if let text = object["detail"] as? String { return text }
      if let detail = object["detail"] as? [String: Any], let text = detail["message"] as? String { return text }
    }
    return "The server answered HTTP \(status)."
  }
}
