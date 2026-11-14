//
// HUDRenderer.swift
//
// Draws the whole 600 x 600 screens for the Meta Ray-Ban Display as one UIImage each. The display
// API only places components side by side (no layering, one root view at a time), so a reticle with
// an animation on top of it has to be composed here and sent as a single image.
//
// Rules from design/glasses (HUD_ASSETS.md): pure black = transparent, bright colours only,
// outlines not panels, no smoothing, keep the centre clear while aiming, text in the margins.
//
// Every number shown comes from the server (CLAUDE.md rule 2); this file only draws it.
//

import UIKit

@MainActor
enum HUDRenderer {
  static let size = CGSize(width: 600, height: 600)

  enum Palette {
    static let cyan = UIColor(red: 0, green: 1, blue: 1, alpha: 1)
    static let magenta = UIColor(red: 1, green: 0, blue: 1, alpha: 1)
    static let yellow = UIColor(red: 1, green: 0.88, blue: 0, alpha: 1)
    static let lime = UIColor(red: 0.49, green: 1, blue: 0, alpha: 1)
    static let orange = UIColor(red: 1, green: 0.56, blue: 0, alpha: 1)
    static let red = UIColor(red: 1, green: 0.25, blue: 0.25, alpha: 1)
    static let white = UIColor.white
  }

  // MARK: - Canvas

  static func render(_ draw: (CGContext) -> Void) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
      let ctx = renderer.cgContext
      ctx.setFillColor(UIColor.black.cgColor)
      ctx.fill(CGRect(origin: .zero, size: size))
      ctx.interpolationQuality = .none  // pixel art: never smooth
      draw(ctx)
    }
  }

  @discardableResult
  static func text(
    _ string: String, in rect: CGRect, size: CGFloat, color: UIColor = Palette.white,
    align: NSTextAlignment = .center, maxLines: Int = 0
  ) -> CGFloat {
    let font = UIFont(name: "Menlo-Bold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .bold)
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineBreakMode = .byWordWrapping
    style.maximumLineHeight = size * 1.2
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
    let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
    var area = rect
    if maxLines > 0 { area.size.height = min(rect.height, size * 1.2 * CGFloat(maxLines)) }
    (string as NSString).draw(with: area, options: options, attributes: attributes, context: nil)
    return (string as NSString).boundingRect(with: area.size, options: options, attributes: attributes, context: nil).height
  }

  private static func line(_ ctx: CGContext, _ points: [CGPoint], color: UIColor, width: CGFloat) {
    guard let first = points.first else { return }
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(width)
    ctx.setLineJoin(.miter)
    ctx.setLineCap(.butt)
    ctx.setShouldAntialias(false)
    ctx.move(to: first)
    points.dropFirst().forEach { ctx.addLine(to: $0) }
    ctx.strokePath()
    ctx.setShouldAntialias(true)
  }

  // MARK: - Hardware test pattern

  /// Shows what the lens really displays: the visible edge (a white frame on the very edge of the
  /// 600 x 600 canvas: if you cannot see all four sides, the corners are clipped), a 100 px grid,
  /// the centre, and a row of the palette colours to judge brightness and contrast.
  static func testPattern() -> UIImage {
    render { ctx in
      ctx.setShouldAntialias(false)
      ctx.setStrokeColor(Palette.cyan.withAlphaComponent(0.45).cgColor)
      ctx.setLineWidth(1)
      for i in stride(from: 100, to: 600, by: 100) {
        ctx.move(to: CGPoint(x: i, y: 0)); ctx.addLine(to: CGPoint(x: i, y: 600))
        ctx.move(to: CGPoint(x: 0, y: i)); ctx.addLine(to: CGPoint(x: 600, y: i))
      }
      ctx.strokePath()
      ctx.setStrokeColor(Palette.white.cgColor)
      ctx.setLineWidth(4)
      ctx.stroke(CGRect(x: 2, y: 2, width: 596, height: 596))
      line(ctx, [CGPoint(x: 280, y: 300), CGPoint(x: 320, y: 300)], color: Palette.yellow, width: 3)
      line(ctx, [CGPoint(x: 300, y: 280), CGPoint(x: 300, y: 320)], color: Palette.yellow, width: 3)
      for (i, colour) in [Palette.cyan, Palette.magenta, Palette.yellow, Palette.lime, Palette.orange, Palette.red, Palette.white].enumerated() {
        ctx.setFillColor(colour.cgColor)
        ctx.fill(CGRect(x: 50 + i * 70, y: 400, width: 60, height: 40))
      }
      ctx.setShouldAntialias(true)
      text("TL", in: CGRect(x: 8, y: 8, width: 80, height: 30), size: 24, color: Palette.white, align: .left)
      text("TR", in: CGRect(x: 512, y: 8, width: 80, height: 30), size: 24, color: Palette.white, align: .right)
      text("BL", in: CGRect(x: 8, y: 562, width: 80, height: 30), size: 24, color: Palette.white, align: .left)
      text("BR", in: CGRect(x: 512, y: 562, width: 80, height: 30), size: 24, color: Palette.white, align: .right)
      text("600 x 600 · PRICE SENSE", in: CGRect(x: 60, y: 180, width: 480, height: 40), size: 26, color: Palette.cyan, maxLines: 1)
      text("Can you read this at the edge?", in: CGRect(x: 60, y: 480, width: 480, height: 80), size: 22, color: Palette.white, maxLines: 2)
    }
  }

  // MARK: - Aiming

  /// The aim screen: reticle, the crop-zone animation in the middle, camera icon top left, coin top
  /// right, one line of text in the bottom margin.
  static func aim(
    zone: UIImage?, streaming: Bool, coin: UIImage? = nil, caption: String? = nil,
    captionColor: UIColor = Palette.cyan
  ) -> UIImage {
    render { _ in
      HUDSprites.reticle.draw(in: CGRect(x: 44, y: 44, width: 512, height: 512))
      zone?.draw(in: CGRect(x: 172, y: 172, width: 256, height: 256))
      if streaming { HUDSprites.cameraIcon.draw(in: CGRect(x: 6, y: 6, width: 32, height: 32)) }
      coin?.draw(in: CGRect(x: 562, y: 6, width: 32, height: 32))
      if let caption {
        text(caption, in: CGRect(x: 40, y: 556, width: 520, height: 40), size: 26, color: captionColor, maxLines: 1)
      }
    }
  }

  // MARK: - Cards

  /// A text card: optional thumbnail of what was captured, a headline and two lines of detail.
  static func card(
    label: String? = nil, title: String, detail: String? = nil, footer: String? = nil,
    accent: UIColor = Palette.cyan, thumbnail: UIImage? = nil, coin: UIImage? = nil, body: String? = nil
  ) -> UIImage {
    render { ctx in
      if let label { text(label, in: CGRect(x: 20, y: 18, width: 560, height: 40), size: 28, color: accent, maxLines: 1) }
      var y: CGFloat = 70
      if let thumbnail {
        let box = CGRect(x: 212, y: y, width: 176, height: 176)
        aspectFit(thumbnail, in: box)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(4)
        ctx.stroke(box.insetBy(dx: -4, dy: -4))
        y += 200
      } else {
        y = 150
      }
      let titleSize: CGFloat = title.count > 26 ? 38 : 48
      let used = text(title, in: CGRect(x: 30, y: y, width: 540, height: 170), size: titleSize, maxLines: 3)
      var next = y + used + 14
      if let detail {
        let height = text(detail, in: CGRect(x: 30, y: next, width: 540, height: 100), size: 28, color: accent, maxLines: 3)
        next += height + 14
      }
      // what the model says it sees: a longer sentence or two, small, in the space above the footer
      if let body {
        text(body, in: CGRect(x: 30, y: next, width: 540, height: max(40, 540 - next)), size: 22, color: Palette.white, maxLines: 6)
      }
      if let footer { text(footer, in: CGRect(x: 20, y: 548, width: 560, height: 46), size: 24, color: Palette.yellow, maxLines: 2) }
      coin?.draw(in: CGRect(x: 562, y: 6, width: 32, height: 32))
    }
  }

  private static func aspectFit(_ image: UIImage, in box: CGRect) {
    guard image.size.width > 0, image.size.height > 0 else { return }
    let scale = min(box.width / image.size.width, box.height / image.size.height)
    let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    image.draw(in: CGRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height))
  }

  // MARK: - Guess dial

  static func guess(value: Int, title: String, hint: String) -> UIImage {
    render { ctx in
      text(title, in: CGRect(x: 20, y: 24, width: 560, height: 40), size: 28, color: Palette.cyan, maxLines: 1)
      text("YOUR GUESS", in: CGRect(x: 20, y: 130, width: 560, height: 40), size: 32, color: Palette.magenta, maxLines: 1)

      let number = Money.euros(value)
      let fontSize = min(100, 540 / (CGFloat(max(number.count, 1)) * 0.62))
      text(number, in: CGRect(x: 20, y: 250, width: 560, height: 120), size: fontSize, color: Palette.yellow, maxLines: 1)

      // up and down arrows: the dial turns both ways
      for (index, up) in [true, false].enumerated() {
        let cy: CGFloat = index == 0 ? 205 : 415
        let tip = up ? cy - 22 : cy + 22
        let base = up ? cy + 14 : cy - 14
        ctx.setFillColor(Palette.cyan.cgColor)
        ctx.move(to: CGPoint(x: 300, y: tip))
        ctx.addLine(to: CGPoint(x: 270, y: base))
        ctx.addLine(to: CGPoint(x: 330, y: base))
        ctx.closePath()
        ctx.fillPath()
      }
      text(hint, in: CGRect(x: 20, y: 500, width: 560, height: 90), size: 24, color: Palette.white, maxLines: 3)
    }
  }

  // MARK: - Accordion

  /// What the accordion screen needs. `bandLow` and `bandHigh` are the eased, on-screen ends of the
  /// bellows (they squeeze towards the real range over a few frames).
  struct AccordionState {
    var title: String
    var guess: Int
    var range: LookSnapshot.PriceRange?
    var bandLow: Double
    var bandHigh: Double
    var done: Bool
    var result: LookSnapshot.GuessResult?
    var status: String?
    var usedRange: LookSnapshot.PriceRange?
    var coin: UIImage?
  }

  static func accordion(_ state: AccordionState) -> UIImage {
    let geometry = AccordionGeometry(guess: state.guess, range: state.range)
    let left: CGFloat = 40
    let right: CGFloat = 560
    func x(_ euros: Double) -> CGFloat { left + CGFloat(geometry.fraction(euros)) * (right - left) }

    return render { ctx in
      text(state.title, in: CGRect(x: 20, y: 16, width: 540, height: 40), size: 28, color: Palette.cyan, maxLines: 1)
      state.coin?.draw(in: CGRect(x: 562, y: 6, width: 32, height: 32))

      let top: CGFloat = 250
      let bottom: CGFloat = 330
      let x1 = x(state.bandLow)
      let x2 = x(state.bandHigh)

      // axis
      line(ctx, [CGPoint(x: left, y: bottom + 18), CGPoint(x: right, y: bottom + 18)], color: Palette.cyan.withAlphaComponent(0.55), width: 2)

      // the bellows: an outlined box with pleats. Squeezing packs the pleats closer together.
      let pleats = 18
      var zigzag: [CGPoint] = []
      for i in 0...pleats {
        zigzag.append(CGPoint(x: x1 + (x2 - x1) * CGFloat(i) / CGFloat(pleats), y: i % 2 == 0 ? top : bottom))
      }
      line(ctx, zigzag, color: Palette.yellow, width: 3)
      ctx.setStrokeColor(Palette.cyan.cgColor)
      ctx.setLineWidth(4)
      ctx.stroke(CGRect(x: x1, y: top, width: max(x2 - x1, 2), height: bottom - top))

      // the real range's ends and the median
      if let range = state.range, state.done || state.bandHigh - state.bandLow < Double(range.high - range.low) * 1.2 {
        let m = x(Double(range.median))
        line(ctx, [CGPoint(x: m, y: top - 16), CGPoint(x: m, y: bottom + 16)], color: Palette.white, width: 6)
        text(Money.euros(range.median), in: CGRect(x: m - 100, y: bottom + 28, width: 200, height: 30), size: 26, color: Palette.white, maxLines: 1)
        // low ends at the left end of the bellows, high starts at the right end, so they never collide
        text(Money.euros(range.low), in: CGRect(x: max(0, x1 - 130), y: bottom + 60, width: 130, height: 26), size: 20, color: Palette.cyan, align: .right, maxLines: 1)
        text(Money.euros(range.high), in: CGRect(x: min(470, x2), y: bottom + 60, width: 130, height: 26), size: 20, color: Palette.cyan, align: .left, maxLines: 1)
      }

      // the user's guess: a marker above the bar (lime inside the real range, orange outside, magenta while unknown)
      let gx = x(Double(state.guess))
      let colour = state.result.map { $0.inRange ? Palette.lime : Palette.orange } ?? Palette.magenta
      ctx.setFillColor(colour.cgColor)
      ctx.move(to: CGPoint(x: gx, y: top - 4))
      ctx.addLine(to: CGPoint(x: gx - 16, y: top - 34))
      ctx.addLine(to: CGPoint(x: gx + 16, y: top - 34))
      ctx.closePath()
      ctx.fillPath()
      let labelX = min(max(gx - 110, 10), 380)
      text("YOU \(Money.euros(state.guess))", in: CGRect(x: labelX, y: top - 74, width: 220, height: 34), size: 26, color: colour, maxLines: 1)

      // verdict and summary once the server has compared guess and price; otherwise the status line
      if let result = state.result {
        let verdictColor = result.verdict == "close" || result.inRange ? Palette.lime : Palette.orange
        text(verdict(result), in: CGRect(x: 20, y: 120, width: 560, height: 56), size: 46, color: verdictColor, maxLines: 1)
        text("SCORE \(result.score)", in: CGRect(x: 20, y: 440, width: 560, height: 40), size: 34, color: Palette.yellow, maxLines: 1)
        text(result.summary, in: CGRect(x: 20, y: 484, width: 560, height: 110), size: 20, color: Palette.white, maxLines: 4)
      } else {
        text(state.status ?? "READING PRICES…", in: CGRect(x: 20, y: 130, width: 560, height: 50), size: 30, color: Palette.yellow, maxLines: 1)
        if let used = state.usedRange {
          text("USED \(Money.euros(used.low))–\(Money.euros(used.high))", in: CGRect(x: 20, y: 470, width: 560, height: 34), size: 26, color: Palette.cyan, maxLines: 1)
        }
      }
    }
  }

  /// "35% LOW", "15% HIGH", "SPOT ON! 2% OFF".
  static func verdict(_ result: LookSnapshot.GuessResult) -> String {
    let pct = Int(abs(result.gapPct).rounded())
    switch result.verdict {
    case "close": return "SPOT ON! \(pct)% OFF"
    case "high": return "\(pct)% HIGH"
    default: return "\(pct)% LOW"
    }
  }
}
