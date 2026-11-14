//
// GuessFlowTests.swift
//
// Tests for Look -> Guess -> Accordion: decoding what the server sends, where things sit on the
// accordion's axis, and the whole flow against a running server (skipped when none is reachable).
//

@testable import PriceSense
import UIKit
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

final class LookModelsTests: XCTestCase {
  private let json = """
    {"look_id":"abc123","status":"identified",
     "identification":{"kind":"car","make":"Honda","model":"HR-V","year_range":[2016,2022],"confidence":0.85,"description":"A grey SUV."},
     "price":{"status":"done","range":{"low":12980,"median":15700,"high":18860,"currency":"EUR","basis":"10th-90th percentile"},
              "sources":[{"domain":"auto1.fi","url":"https://auto1.fi/x","status":"ok","n_listings":46},{"domain":"kamux.fi","status":"timeout","n_listings":0}],
              "sources_total":6,"sources_done":6,"n_listings":35,"notes":["merged 9 adverts that appear on several sites"],
              "fetched_at":"2026-11-14T14:53:37+00:00","cached":false},
     "guess":{"guess_eur":18000,"result":{"guess_eur":18000,"gap_eur":2300,"gap_pct":14.6,"verdict":"high","in_range":true,"score":79,
              "summary":"You guessed €18,000. The real range is €13,000 to €18,900, median €15,700. You were inside the real range, 15% above the median."}},
     "image":{"format":"JPEG","width":576,"height":432,"bytes":60499},"model":"x","cached":false,"latency_s":1.9}
    """

  func testDecodesAFinishedLookWithAGuess() throws {
    let snapshot = try XCTUnwrap(LookSnapshot.decode(Data(json.utf8)))
    XCTAssertEqual(snapshot.lookId, "abc123")
    XCTAssertEqual(snapshot.identification.title, "Honda HR-V")
    XCTAssertEqual(snapshot.identification.years, "2016–2022")
    XCTAssertEqual(snapshot.price.range, .init(low: 12_980, median: 15_700, high: 18_860))
    XCTAssertTrue(snapshot.price.isDone)
    XCTAssertFalse(snapshot.price.isPending)
    XCTAssertEqual(snapshot.price.sources?.count, 2)
    XCTAssertEqual(snapshot.price.sources?.first?.nListings, 46)
    XCTAssertEqual(snapshot.guess?.result?.verdict, "high")
    XCTAssertEqual(snapshot.guess?.result?.score, 79)
    XCTAssertTrue(snapshot.guess?.result?.summary.hasPrefix("You guessed") == true)
  }

  func testDecodesAPendingLookWithoutAGuess() throws {
    let pending = #"{"look_id":"x","identification":{"kind":"car","make":"Honda","model":"HR-V","year_range":null,"confidence":0.9,"description":"d"},"price":{"status":"searching","range":null,"sources":[],"notes":[]},"guess":null}"#
    let snapshot = try XCTUnwrap(LookSnapshot.decode(Data(pending.utf8)))
    XCTAssertTrue(snapshot.price.isPending)
    XCTAssertNil(snapshot.price.range)
    XCTAssertNil(snapshot.guess)
    XCTAssertNil(snapshot.identification.years)
  }

  func testSkippedPriceHasNoPrice() throws {
    let skipped = #"{"look_id":"x","identification":{"kind":"other","make":null,"model":null,"confidence":0.9,"description":"A plant."},"price":{"status":"skipped","reason":"pricing is only built for cars so far","range":null}}"#
    let snapshot = try XCTUnwrap(LookSnapshot.decode(Data(skipped.utf8)))
    XCTAssertTrue(snapshot.price.hasNoPrice)
    XCTAssertEqual(snapshot.identification.title, "A plant.")  // no make/model: falls back to the description
  }

  func testDecodesAProductWithAVariantAndAUsedRange() throws {
    let json = #"""
      {"look_id":"p1","confirmed":true,
       "identification":{"kind":"phone","make":"Apple","model":"iPhone 15","variant":"128GB","year_range":null,"confidence":1.0,"description":"A phone."},
       "price":{"status":"done","price_basis":"new","range":{"low":599,"median":835,"high":949},
                "used_range":{"low":420,"median":480,"high":560},"sources":[],"notes":[]}}
      """#
    let snapshot = try XCTUnwrap(LookSnapshot.decode(Data(json.utf8)))
    XCTAssertEqual(snapshot.identification.variant, "128GB")
    XCTAssertTrue(snapshot.identification.isPriceable)
    XCTAssertEqual(snapshot.confirmed, true)
    XCTAssertEqual(snapshot.price.priceBasis, "new")
    XCTAssertEqual(snapshot.price.usedRange, .init(low: 420, median: 480, high: 560))
  }

  func testOnlyKnownKindsWithAMakeAndModelArePriceable() {
    func id(_ kind: String, _ make: String?, _ model: String?) -> LookSnapshot.Identification {
      .init(kind: kind, make: make, model: model, confidence: 0.9, description: "d")
    }
    XCTAssertTrue(id("headphones", "Sony", "WH-1000XM5").isPriceable)
    XCTAssertTrue(id("laptop", "Apple", "MacBook Air").isPriceable)
    XCTAssertFalse(id("headphones", nil, nil).isPriceable)  // the model could not tell which
    XCTAssertFalse(id("building", "x", "y").isPriceable)
    XCTAssertFalse(id("other", nil, nil).isPriceable)
  }

  func testAnyNamedItemIsPriceableWithoutABrand() throws {
    let json = #"{"look_id":"i1","identification":{"kind":"item","make":null,"model":"wooden dining chair","variant":null,"year_range":null,"search_fi":"tammi tuoli","confidence":0.6,"description":"A light oak chair."},"price":{"status":"searching","range":null,"sources":[],"notes":[]}}"#
    let snapshot = try XCTUnwrap(LookSnapshot.decode(Data(json.utf8)))
    XCTAssertTrue(snapshot.identification.isPriceable)
    XCTAssertEqual(snapshot.identification.title, "wooden dining chair")
    // exact-model kinds still need a brand, and an unnamed item cannot be priced
    XCTAssertFalse(LookSnapshot.Identification(kind: "phone", make: nil, model: "iPhone 15", confidence: 1, description: "").isPriceable)
    XCTAssertFalse(LookSnapshot.Identification(kind: "item", make: "IKEA", model: nil, confidence: 1, description: "").isPriceable)
  }

  func testGarbageDoesNotDecode() {
    XCTAssertNil(LookSnapshot.decode(Data("not json".utf8)))
    XCTAssertNil(LookSnapshot.decode(Data(#"{"detail":"Not Found"}"#.utf8)))
  }
}

final class AccordionGeometryTests: XCTestCase {
  func testBellowsOpenWideAroundTheGuessBeforeAnyRange() {
    let geo = AccordionGeometry(guess: 20_000, range: nil)
    XCTAssertEqual(geo.bandLow, 10_000, accuracy: 0.1)
    XCTAssertEqual(geo.bandHigh, 30_000, accuracy: 0.1)
    XCTAssertTrue(geo.domain.contains(20_000))
    XCTAssertEqual(geo.fraction(20_000), 0.5, accuracy: 0.1)  // the guess sits near the middle
  }

  func testBellowsSqueezeToTheRealRange() {
    let range = LookSnapshot.PriceRange(low: 12_980, median: 15_700, high: 18_860)
    let open = AccordionGeometry(guess: 20_000, range: nil)
    let squeezed = AccordionGeometry(guess: 20_000, range: range)
    XCTAssertEqual(squeezed.bandLow, 12_980)
    XCTAssertEqual(squeezed.bandHigh, 18_860)
    let openWidth = open.fraction(open.bandHigh) - open.fraction(open.bandLow)
    let squeezedWidth = squeezed.fraction(squeezed.bandHigh) - squeezed.fraction(squeezed.bandLow)
    XCTAssertLessThan(squeezedWidth, openWidth * 0.5, "the accordion must visibly squeeze")
  }

  func testAxisDoesNotJumpWhenTheRangeArrivesInsideTheOpenBand() {
    let range = LookSnapshot.PriceRange(low: 12_980, median: 15_700, high: 18_860)
    XCTAssertEqual(
      AccordionGeometry(guess: 20_000, range: nil).domain,
      AccordionGeometry(guess: 20_000, range: range).domain)
  }

  func testAxisGrowsWhenTheRealPriceIsFarFromTheGuess() {
    let far = LookSnapshot.PriceRange(low: 60_000, median: 70_000, high: 80_000)
    let geo = AccordionGeometry(guess: 10_000, range: far)
    XCTAssertTrue(geo.domain.contains(10_000))  // the guess stays on the axis
    XCTAssertTrue(geo.domain.contains(80_000))  // and so does the real range
    XCTAssertLessThan(geo.fraction(10_000), geo.fraction(60_000))
  }

  func testFractionIsMonotonicAndClamped() {
    let geo = AccordionGeometry(guess: 15_000, range: .init(low: 12_000, median: 15_000, high: 18_000))
    XCTAssertLessThan(geo.fraction(12_000), geo.fraction(15_000))
    XCTAssertLessThan(geo.fraction(15_000), geo.fraction(18_000))
    XCTAssertEqual(geo.fraction(-1_000_000), 0)
    XCTAssertEqual(geo.fraction(1_000_000_000), 1)
  }
}

@MainActor
final class GuessFlowTests: XCTestCase {
  private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while !condition() {
      if ContinuousClock.now > deadline { return false }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return true
  }

  /// The full flow with a real car photo: identify -> guess -> the server compares the guess with
  /// the final price range. Needs the server with Nemotron and Context.dev keys.
  func testGuessThenAccordionEndToEnd() async throws {
    var health = URLRequest(url: URL(string: Config.SERVER_URL + "/health")!, timeoutInterval: 3)
    health.httpMethod = "GET"
    do { _ = try await URLSession.shared.data(for: health) } catch {
      throw XCTSkip("Server not reachable at \(Config.SERVER_URL): \(error.localizedDescription)")
    }
    let data = try TestPhoto.real()
    let frame = try XCTUnwrap(UIImage(data: data))

    let look = LookViewModel()
    XCTAssertNil(look.lockedGuess)
    look.look(at: frame)

    func snapshot() -> LookSnapshot? {
      if case .result(let r) = look.state { return r.snapshot }
      return nil
    }

    // 1. the identification arrives (price still being looked up, or already cached)
    let identified = await waitUntil(60) { snapshot() != nil }
    XCTAssertTrue(identified, "no identification; state: \(look.state)")
    let first = try XCTUnwrap(snapshot())
    XCTAssertEqual(first.identification.kind, "car")
    XCTAssertFalse(first.price.hasNoPrice, "the car should be priceable: \(first.price)")
    XCTAssertNil(first.guess, "no guess has been locked in yet")

    // 2. a guess is refused until the user has said what it is (the price depends on the exact model)
    look.lockGuess(1_000)
    XCTAssertNil(look.lockedGuess)
    look.confirmIdentity()
    let confirmed = await waitUntil(15) { look.identityConfirmed }
    XCTAssertTrue(confirmed, "not confirmed: \(look.confirmError ?? "no error")")

    // 3. guess first
    look.lockGuess(18_000)
    let locked = await waitUntil(15) { look.lockedGuess == 18_000 }
    XCTAssertTrue(locked, "guess not locked: \(look.guessError ?? "no error")")
    look.lockGuess(5_000)  // a second guess must not replace the first
    XCTAssertEqual(look.lockedGuess, 18_000)

    // 4. the price settles and the server's comparison arrives
    let compared = await waitUntil(120) { snapshot()?.guess?.result != nil }
    XCTAssertTrue(compared, "no comparison; last price status: \(snapshot()?.price.status ?? "nil")")
    let final = try XCTUnwrap(snapshot())
    XCTAssertEqual(final.price.status, "done")
    let result = try XCTUnwrap(final.guess?.result)
    XCTAssertEqual(result.guessEur, 18_000)
    XCTAssertTrue(["close", "high", "low"].contains(result.verdict))
    XCTAssertTrue(result.summary.hasPrefix("You guessed"), result.summary)
    XCTAssertTrue((0...100).contains(result.score))
    let range = try XCTUnwrap(final.price.range)
    XCTAssertLessThan(range.low, range.median)
    XCTAssertLessThan(range.median, range.high)
    print("GUESS RESULT: \(result.summary) score=\(result.score)")

    // 4. the finished guess is kept for the Score screen, once
    let kept = ScoreStore.shared.entries.filter { $0.id == final.lookId }
    XCTAssertEqual(kept.count, 1)
    XCTAssertEqual(kept.first?.score, result.score)

    // 5. what the price means for the customer, and a grounded answer from the coach
    let money = MoneyClient()
    let context = try await money.context(customerID: nil, lookID: final.lookId)
    XCTAssertEqual(context.context.priceEur, range.median)
    XCTAssertFalse(context.context.summary.isEmpty)
    XCTAssertTrue(["leaks", "irregular", "regular"].contains(context.context.basket.id))
    let coach = try await money.ask(customerID: context.customerId, lookID: final.lookId, question: "Can I afford this?")
    XCTAssertFalse(coach.answer.isEmpty)
    print("COACH [\(coach.source)]: \(coach.answer)")
    ScoreStore.shared.clear()
  }

  /// The model can be wrong: the user corrects it, and the price lookup restarts for the right thing.
  /// (A car photo is "corrected" to headphones, which exercises POST /confirm with a product.)
  func testCorrectingTheIdentityRestartsThePriceLookup() async throws {
    var health = URLRequest(url: URL(string: Config.SERVER_URL + "/health")!, timeoutInterval: 3)
    health.httpMethod = "GET"
    do { _ = try await URLSession.shared.data(for: health) } catch {
      throw XCTSkip("Server not reachable at \(Config.SERVER_URL): \(error.localizedDescription)")
    }
    let data = try TestPhoto.real()
    let look = LookViewModel()
    look.look(at: try XCTUnwrap(UIImage(data: data)))

    func snapshot() -> LookSnapshot? {
      if case .result(let r) = look.state { return r.snapshot }
      return nil
    }
    let identified = await waitUntil(60) { snapshot() != nil }
    XCTAssertTrue(identified, "no identification; state: \(look.state)")

    look.submitIdentity(IdentityInput(kind: "headphones", make: "Sony", model: "WH-1000XM5"))
    let confirmed = await waitUntil(15) { look.identityConfirmed }
    XCTAssertTrue(confirmed, "not confirmed: \(look.confirmError ?? "no error")")
    let corrected = try XCTUnwrap(snapshot())
    XCTAssertEqual(corrected.identification.kind, "headphones")
    XCTAssertEqual(corrected.identification.make, "Sony")
    XCTAssertEqual(corrected.confirmed, true)

    let priced = await waitUntil(120) { snapshot()?.price.isDone == true }
    XCTAssertTrue(priced, "no product price; last status: \(snapshot()?.price.status ?? "nil")")
    let range = try XCTUnwrap(snapshot()?.price.range)
    XCTAssertLessThan(range.low, range.high + 1)
    XCTAssertTrue((100...1_000).contains(range.median), "implausible price for WH-1000XM5: \(range)")

    look.lockGuess(250)
    let locked = await waitUntil(15) { look.lockedGuess == 250 }
    XCTAssertTrue(locked, "guess not locked: \(look.guessError ?? "no error")")
    let compared = await waitUntil(30) { snapshot()?.guess?.result != nil }
    XCTAssertTrue(compared)
  }
}
