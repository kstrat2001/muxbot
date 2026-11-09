import SwiftUI

// MARK: - Look

/// The animals a bot can be. Every animal shares the same robot face (LED
/// eyes behind lens plates) and controller headset; only the head changes.
enum BotAnimal: String, Codable, CaseIterable, Sendable, Identifiable {
    case octopus, fox, otter, beaver, owl, cat, bear, rabbit, panda, raccoon, penguin, frog, dog, squirrel

    var id: String { rawValue }

    /// The animal's name, shown under it in the picker.
    var name: String {
        switch self {
        case .octopus: String(localized: "Octopus")
        case .fox: String(localized: "Fox")
        case .otter: String(localized: "Otter")
        case .beaver: String(localized: "Beaver")
        case .owl: String(localized: "Owl")
        case .cat: String(localized: "Cat")
        case .bear: String(localized: "Bear")
        case .rabbit: String(localized: "Rabbit")
        case .panda: String(localized: "Panda")
        case .raccoon: String(localized: "Raccoon")
        case .penguin: String(localized: "Penguin")
        case .frog: String(localized: "Frog")
        case .dog: String(localized: "Dog")
        case .squirrel: String(localized: "Squirrel")
        }
    }
}

/// What a bot's avatar is showing. Status is told by the face and motion,
/// never by words (words live in the accessibility label).
enum AvatarMood: CaseIterable, Sendable, Identifiable {
    case idle, thinking, running, needsYou, done

    var id: Self { self }

    /// The state's name, for the picker's preview row.
    var name: String {
        switch self {
        case .idle: String(localized: "Idle")
        case .thinking: String(localized: "Thinking")
        case .running: String(localized: "Working")
        case .needsYou: String(localized: "Needs you")
        case .done: String(localized: "Done")
        }
    }

    init(_ state: BotState) {
        switch state {
        case .ready: self = .idle
        case .working: self = .running
        case .needsYou: self = .needsYou
        }
    }
}

/// A bot's look: an animal, a main color and an LED eye color.
struct BotLook: Equatable, Sendable {
    var animal: BotAnimal
    var bodyHex: String
    var eyeHex: String

    /// Main colors offered when making a bot.
    static let bodyColors = ["5b5bd6", "2f6fb5", "0e9f8e", "3d9a4a", "e3a12a", "e0732d",
                             "c96b9b", "7b5fc7", "8a5a3c", "7c8494", "2b2f3a", "f1ede6"]
    /// Eye colors offered. Red is left out: red eyes mean "needs you".
    static let eyeColors = ["3fdcff", "5cf28a", "ffc23d", "ffffff", "ff7fd0", "b18cff"]

    /// The lead bot: the indigo octopus with cyan eyes (also the app icon).
    static let lead = BotLook(animal: .octopus, bodyHex: "5b5bd6", eyeHex: "3fdcff")

    /// A stable starting look for a bot that hasn't picked one, from its name.
    static func suggested(for name: String) -> BotLook {
        let known: [String: BotAnimal] = ["humancodereader": .owl, "darkmux": .raccoon,
                                          "personal brand": .fox, "daily update": .penguin]
        let hash = name.lowercased().unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        let animals = BotAnimal.allCases.filter { $0 != .octopus }
        let animal = known[name.lowercased()] ?? animals[Int(hash % UInt64(animals.count))]
        let body = bodyColors[Int((hash / 7) % UInt64(bodyColors.count))]
        return BotLook(animal: animal, bodyHex: body, eyeHex: eyeColors[0])
    }
}

extension Bot {
    /// The bot's chosen look, filling anything unset from its name.
    var look: BotLook {
        get {
            let base = BotLook.suggested(for: name)
            return BotLook(animal: BotAnimal(rawValue: avatarAnimal) ?? base.animal,
                           bodyHex: bodyColorHex.isEmpty ? base.bodyHex : bodyColorHex,
                           eyeHex: eyeColorHex.isEmpty ? base.eyeHex : eyeColorHex)
        }
        set {
            avatarAnimal = newValue.animal.rawValue
            bodyColorHex = newValue.bodyHex
            eyeColorHex = newValue.eyeHex
        }
    }
}

extension Color {
    /// "5b5bd6" → Color. Invalid input is gray.
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x808080
        self.init(red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}

// MARK: - View

/// A bot's character: its animal, colors and mood, drawn from vector shapes
/// on a 100 × 100 grid and animated (blink, think, scan, pulse). Still when
/// Reduce Motion is on.
struct BotAvatarView: View {
    let look: BotLook
    var mood: AvatarMood = .idle
    var size: CGFloat = 32
    /// The bot's id, so its idle blink has its own timing (bots never blink
    /// in unison). Without one, the look picks the timing.
    var blinkId: UUID? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Dark mode's rim around the silhouette, so the face's dark parts (and a
    /// dark body color) stand out from a dark background.
    static let rim = Color.white.opacity(0.38)

    private var schedule: BlinkSchedule {
        blinkId.map(BlinkSchedule.init(id:)) ?? BlinkSchedule(seed: BlinkSchedule.stableHash("\(look.animal)\(look.bodyHex)\(look.eyeHex)"))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { [schedule, colorScheme] ctx, canvas in
                let dark = colorScheme == .dark
                let painter = AvatarPainter(look: look, mood: mood, t: t, still: reduceMotion, blink: schedule, dark: dark)
                if dark {
                    // The rim traces the whole silhouette: drawn as one layer,
                    // so inner edges don't glow.
                    ctx.addFilter(.shadow(color: Self.rim, radius: max(0.8, canvas.width / 70)))
                }
                ctx.drawLayer { layer in
                    layer.scaleBy(x: canvas.width / 100, y: canvas.height / 100)
                    var drawn = layer
                    painter.paint(&drawn)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Painter

/// Draws one frame. Coordinates are the 100 × 100 grid of the design page.
struct AvatarPainter {
    let look: BotLook
    let mood: AvatarMood
    let t: Double
    var still = false
    var blink = BlinkSchedule(seed: 1)
    /// Dark mode: the headset is drawn lighter so it doesn't vanish into a
    /// dark background (the silhouette also gets a rim; see BotAvatarView).
    var dark = false

    private static let muzzle = Color(hex: "fff4e8")
    private static let ink = Color(hex: "1d1f27")
    static let headsetHex = "2b2f3a"
    /// The headset in dark mode: at least 3:1 against every dark background
    /// the app draws avatars on (checked in ContrastTests).
    static let headsetDarkHex = "70768a"
    private var headset: Color { Color(hex: dark ? Self.headsetDarkHex : Self.headsetHex) }
    private static let pink = Color(hex: "ff9fb0")
    private static let nosePink = Color(hex: "ff8fa0")
    private static let beak = Color(hex: "f2b632")
    private static let need = Color(hex: "e5484d")

    private var body: Color { Color(hex: look.bodyHex) }
    private var led: Color { mood == .needsYou ? Self.need : Color(hex: look.eyeHex) }

    /// Eye height, mouth height (nil: the animal has a beak or teeth) and
    /// headset height for each animal.
    private var eyeY: CGFloat { look.animal == .frog ? 40 : look.animal == .octopus ? 48 : 50 }
    private var mouthY: CGFloat? {
        switch look.animal {
        case .octopus: 62
        case .fox: 74
        case .otter, .raccoon: 76
        case .dog: 75
        case .squirrel: 74
        case .cat: 72
        case .bear: 75
        case .rabbit, .panda: 73
        case .frog: 72
        case .beaver, .owl, .penguin: nil
        }
    }
    private var headsetY: CGFloat { look.animal == .octopus ? 46 : 55 }

    func paint(_ ctx: inout GraphicsContext) {
        var c = ctx
        if mood == .running, !still {
            c.translateBy(x: 0, y: -3 * (0.5 - 0.5 * cos(t * 2 * .pi / 1.2)))
        }
        drawHead(&c)
        drawHeadset(&c)
        drawOverHeadset(&c)
        drawFace(&c)
        drawBadge(&ctx)
    }

    // MARK: Shapes

    private func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    private func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, rotate: Double = 0) -> Path {
        let p = Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
        guard rotate != 0 else { return p }
        let tr = CGAffineTransform(translationX: x, y: y).rotated(by: rotate * .pi / 180).translatedBy(x: -x, y: -y)
        return p.applying(tr)
    }
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }
    private func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var p = Path()
        p.addLines(pts.map { CGPoint(x: $0.0, y: $0.1) })
        p.closeSubpath()
        return p
    }
    private func line(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: a.0, y: a.1))
        p.addLine(to: CGPoint(x: b.0, y: b.1))
        return p
    }
    private func quad(_ a: (CGFloat, CGFloat), _ ctl: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: a.0, y: a.1))
        p.addQuadCurve(to: CGPoint(x: b.0, y: b.1), control: CGPoint(x: ctl.0, y: ctl.1))
        return p
    }
    private func stroke(_ ctx: inout GraphicsContext, _ p: Path, _ color: Color, _ width: CGFloat, opacity: Double = 1) {
        ctx.stroke(p, with: .color(color.opacity(opacity)),
                   style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
    private func fill(_ ctx: inout GraphicsContext, _ p: Path, _ color: Color, opacity: Double = 1) {
        ctx.fill(p, with: .color(color.opacity(opacity)))
    }
    /// A filled shape with a rounded outline in the same color (soft ears).
    private func soft(_ ctx: inout GraphicsContext, _ p: Path, _ color: Color, _ width: CGFloat) {
        fill(&ctx, p, color)
        stroke(&ctx, p, color, width)
    }
    private func whiskers(_ ctx: inout GraphicsContext, y: CGFloat, inner: CGFloat, drop: CGFloat) {
        let lines: [((CGFloat, CGFloat), (CGFloat, CGFloat))] = [
            ((inner, y), (18, y)), ((inner, y + 4), (19, y + 4 + drop)),
            ((100 - inner, y), (82, y)), ((100 - inner, y + 4), (81, y + 4 + drop)),
        ]
        for (a, b) in lines {
            stroke(&ctx, line(a, b), Self.ink, 1.6, opacity: 0.5)
        }
    }

    // MARK: Head

    private func drawHead(_ ctx: inout GraphicsContext) {
        let c = body, m = Self.muzzle, k = Self.ink
        switch look.animal {
        case .octopus:
            for (i, x) in [CGFloat(22), 36, 50, 64, 78].enumerated() {
                stroke(&ctx, quad((x, 66), (x + (i % 2 == 1 ? 4 : -4), 78), (x, 88)), c, 9)
            }
            fill(&ctx, ellipse(50, 46, 32, 30), c)
            fill(&ctx, circle(36, 30, 3), m, opacity: 0.5)
            fill(&ctx, circle(64, 26, 2.2), m, opacity: 0.5)
        case .fox:
            soft(&ctx, poly([(22, 40), (28, 10), (46, 30)]), c, 4)
            soft(&ctx, poly([(78, 40), (72, 10), (54, 30)]), c, 4)
            fill(&ctx, poly([(29, 18), (33, 30), (40, 31)]), k, opacity: 0.35)
            fill(&ctx, poly([(71, 18), (67, 30), (60, 31)]), k, opacity: 0.35)
            fill(&ctx, circle(50, 54, 32), c)
            var muzzle = Path()
            muzzle.move(to: CGPoint(x: 22, y: 58))
            muzzle.addQuadCurve(to: CGPoint(x: 78, y: 58), control: CGPoint(x: 50, y: 50))
            muzzle.addQuadCurve(to: CGPoint(x: 50, y: 88), control: CGPoint(x: 70, y: 88))
            muzzle.addQuadCurve(to: CGPoint(x: 22, y: 58), control: CGPoint(x: 30, y: 88))
            fill(&ctx, muzzle, m)
            fill(&ctx, ellipse(50, 68, 4.5, 3.2), k)
        case .otter:
            fill(&ctx, circle(24, 34, 8), c)
            fill(&ctx, circle(76, 34, 8), c)
            fill(&ctx, circle(50, 56, 32), c)
            fill(&ctx, ellipse(50, 70, 17, 12), m)
            fill(&ctx, ellipse(50, 64, 5, 3.5), k)
            whiskers(&ctx, y: 68, inner: 32, drop: 4)
        case .beaver:
            fill(&ctx, circle(25, 32, 7), c)
            fill(&ctx, circle(75, 32, 7), c)
            fill(&ctx, circle(50, 55, 32), c)
            fill(&ctx, ellipse(50, 68, 15, 10), m)
            fill(&ctx, rect(45, 74, 10, 9, 2), .white)
            stroke(&ctx, rect(45, 74, 10, 9, 2), k, 1.4)
            stroke(&ctx, line((50, 74), (50, 83)), k, 1.2)
            fill(&ctx, ellipse(50, 64, 5, 3.5), k)
        case .owl:
            soft(&ctx, poly([(22, 36), (20, 14), (38, 28)]), c, 4)
            soft(&ctx, poly([(78, 36), (80, 14), (62, 28)]), c, 4)
            fill(&ctx, circle(50, 55, 32), c)
            fill(&ctx, circle(38, 50, 14), m)
            fill(&ctx, circle(62, 50, 14), m)
            stroke(&ctx, quad((38, 76), (50, 84), (62, 76)), m, 3, opacity: 0.5)
            soft(&ctx, poly([(45, 62), (55, 62), (50, 71)]), Self.beak, 2)
        case .cat:
            soft(&ctx, poly([(22, 42), (26, 16), (44, 30)]), c, 5)
            soft(&ctx, poly([(78, 42), (74, 16), (56, 30)]), c, 5)
            fill(&ctx, poly([(28, 24), (30, 32), (37, 31)]), Self.pink)
            fill(&ctx, poly([(72, 24), (70, 32), (63, 31)]), Self.pink)
            fill(&ctx, circle(50, 56, 32), c)
            soft(&ctx, poly([(46, 64), (54, 64), (50, 68)]), Self.nosePink, 1.5)
            whiskers(&ctx, y: 66, inner: 30, drop: 3)
        case .bear:
            fill(&ctx, circle(24, 30, 11), c)
            fill(&ctx, circle(76, 30, 11), c)
            fill(&ctx, circle(24, 30, 5), m, opacity: 0.7)
            fill(&ctx, circle(76, 30, 5), m, opacity: 0.7)
            fill(&ctx, circle(50, 56, 32), c)
            fill(&ctx, ellipse(50, 70, 14, 11), m)
            fill(&ctx, ellipse(50, 65, 5.5, 4), k)
        case .rabbit:
            fill(&ctx, ellipse(38, 18, 8, 20), c)
            fill(&ctx, ellipse(62, 18, 8, 20), c)
            fill(&ctx, ellipse(38, 18, 3.5, 14), Self.pink)
            fill(&ctx, ellipse(62, 18, 3.5, 14), Self.pink)
            fill(&ctx, circle(50, 57, 31), c)
            fill(&ctx, ellipse(50, 71, 12, 9), m)
            fill(&ctx, ellipse(50, 66, 4, 3), Self.nosePink)
        case .panda:
            fill(&ctx, circle(24, 30, 11), c)
            fill(&ctx, circle(76, 30, 11), c)
            fill(&ctx, circle(50, 56, 32), m)
            fill(&ctx, ellipse(37, 52, 13, 11, rotate: -20), c)
            fill(&ctx, ellipse(63, 52, 13, 11, rotate: 20), c)
            fill(&ctx, ellipse(50, 66, 5, 3.5), k)
        case .raccoon:
            soft(&ctx, poly([(20, 40), (24, 16), (42, 30)]), c, 6)
            soft(&ctx, poly([(80, 40), (76, 16), (58, 30)]), c, 6)
            fill(&ctx, circle(50, 56, 32), c)
            var mask = Path()
            mask.move(to: CGPoint(x: 20, y: 50))
            mask.addQuadCurve(to: CGPoint(x: 80, y: 50), control: CGPoint(x: 50, y: 34))
            mask.addQuadCurve(to: CGPoint(x: 50, y: 58), control: CGPoint(x: 76, y: 62))
            mask.addQuadCurve(to: CGPoint(x: 20, y: 50), control: CGPoint(x: 24, y: 62))
            fill(&ctx, mask, k, opacity: 0.55)
            fill(&ctx, ellipse(50, 72, 14, 10), m)
            fill(&ctx, ellipse(50, 66, 5, 3.5), k)
        case .penguin:
            fill(&ctx, circle(50, 55, 32), c)
            var face = Path()
            face.move(to: CGPoint(x: 50, y: 44))
            face.addCurve(to: CGPoint(x: 26, y: 56), control1: CGPoint(x: 40, y: 30), control2: CGPoint(x: 22, y: 40))
            face.addCurve(to: CGPoint(x: 50, y: 84), control1: CGPoint(x: 28, y: 72), control2: CGPoint(x: 40, y: 84))
            face.addCurve(to: CGPoint(x: 74, y: 56), control1: CGPoint(x: 60, y: 84), control2: CGPoint(x: 72, y: 72))
            face.addCurve(to: CGPoint(x: 50, y: 44), control1: CGPoint(x: 78, y: 40), control2: CGPoint(x: 60, y: 30))
            fill(&ctx, face, m)
            soft(&ctx, poly([(44, 63), (56, 63), (50, 70)]), Color(hex: "f2a032"), 2)
        case .dog:
            fill(&ctx, circle(50, 55, 31), c)
            fill(&ctx, ellipse(62, 47, 12, 10), k, opacity: 0.15)
            fill(&ctx, ellipse(50, 70, 15, 11), m)
            var tongue = Path()
            tongue.move(to: CGPoint(x: 45.5, y: 76.5))
            tongue.addQuadCurve(to: CGPoint(x: 50, y: 85.5), control: CGPoint(x: 45.5, y: 85.5))
            tongue.addQuadCurve(to: CGPoint(x: 54.5, y: 76.5), control: CGPoint(x: 54.5, y: 85.5))
            tongue.closeSubpath()
            fill(&ctx, tongue, Self.nosePink)
            stroke(&ctx, line((50, 78), (50, 82)), Color(hex: "e0607a"), 1)
            fill(&ctx, ellipse(50, 64, 6, 4.5), k)
        case .squirrel:
            fill(&ctx, ellipse(84, 36, 14, 24, rotate: 25), c)
            fill(&ctx, ellipse(86, 34, 6, 16, rotate: 25), m, opacity: 0.35)
            soft(&ctx, poly([(24, 36), (28, 10), (42, 28)]), c, 5)
            soft(&ctx, poly([(76, 36), (72, 10), (58, 28)]), c, 5)
            fill(&ctx, circle(50, 56, 32), c)
            fill(&ctx, ellipse(31, 68, 8, 6), m)
            fill(&ctx, ellipse(69, 68, 8, 6), m)
            fill(&ctx, ellipse(50, 71, 10, 8), m)
            fill(&ctx, ellipse(50, 65, 4, 3), k)
        case .frog:
            fill(&ctx, circle(36, 38, 15), c)
            fill(&ctx, circle(64, 38, 15), c)
            fill(&ctx, ellipse(50, 62, 35, 26), c)
            fill(&ctx, circle(26, 68, 4), Self.nosePink, opacity: 0.5)
            fill(&ctx, circle(74, 68, 4), Self.nosePink, opacity: 0.5)
        }
    }

    // MARK: Headset

    private func drawHeadset(_ ctx: inout GraphicsContext) {
        let y = headsetY, h = headset
        let micY = mouthY ?? eyeY + 20
        var band = Path()
        band.addRelativeArc(center: CGPoint(x: 50, y: y), radius: 37, startAngle: .degrees(180), delta: .degrees(180))
        stroke(&ctx, band, h, 5)
        fill(&ctx, rect(8, y - 11, 13, 22, 6), h)
        fill(&ctx, rect(79, y - 11, 13, 22, 6), h)
        fill(&ctx, rect(11, y - 6, 3, 12, 1.5), body, opacity: 0.8)
        stroke(&ctx, quad((16, y + 9), (18, micY + 6), (36, micY + 3)), h, 3)
        fill(&ctx, rect(34, micY - 1, 9, 7, 3.5), h)
        let lamp: Color = switch mood {
        case .needsYou: Self.need
        case .running, .done: Color(hex: "3ad07a")
        case .idle, .thinking: Color(hex: "7a8090")
        }
        fill(&ctx, circle(85.5, y, 2.6), lamp)
    }

    /// Parts that sit over the headset band (a dog's floppy ears).
    private func drawOverHeadset(_ ctx: inout GraphicsContext) {
        guard look.animal == .dog else { return }
        for (x, angle) in [(CGFloat(27), 48.0), (73, -48)] {
            fill(&ctx, ellipse(x, 34, 10, 17, rotate: angle), body)
            fill(&ctx, ellipse(x, 34, 10, 17, rotate: angle), Self.ink, opacity: 0.22)
        }
    }

    // MARK: Face

    private func plate(_ ctx: inout GraphicsContext, _ x: CGFloat) {
        let p = rect(x - 10, eyeY - 9, 20, 18, 6)
        fill(&ctx, p, Self.ink)
        stroke(&ctx, p, .white, 1.5, opacity: 0.25)
    }

    /// A lens plate with a glowing LED pupil, offset by (dx, dy).
    private func eye(_ ctx: inout GraphicsContext, _ x: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0, r: CGFloat = 5) {
        plate(&ctx, x)
        let pupil = rect(x + dx - r * 0.75, eyeY + dy - r, r * 1.5, r * 2, r * 0.75)
        ctx.drawLayer { glow in
            glow.addFilter(.blur(radius: 2))
            glow.fill(pupil, with: .color(led.opacity(0.5)))
        }
        fill(&ctx, pupil, led)
    }

    /// Scales a group around a point (blink, pulse).
    private func scaled(_ ctx: GraphicsContext, x: CGFloat, y: CGFloat, sx: CGFloat, sy: CGFloat) -> GraphicsContext {
        var c = ctx
        c.translateBy(x: x, y: y)
        c.scaleBy(x: sx, y: sy)
        c.translateBy(x: -x, y: -y)
        return c
    }

    private func drawFace(_ ctx: inout GraphicsContext) {
        let k = Self.ink
        switch mood {
        case .idle:
            // Reduce Motion: no blinking at all.
            let open: CGFloat = still ? 1 : blink.openness(at: t)
            var eyes = scaled(ctx, x: 50, y: eyeY, sx: 1, sy: open)
            eye(&eyes, 38)
            eye(&eyes, 62)
            smile(&ctx)
        case .thinking:
            eye(&ctx, 38, dx: 2, dy: -2.5)
            eye(&ctx, 62, dx: 2, dy: -2.5)
            if let my = mouthY { stroke(&ctx, line((45, my + 1), (55, my + 1)), k, 2.4) }
        case .running:
            let dx: CGFloat = still ? 0 : 5 * sin(t * 2 * .pi / 2.8)
            var scan = ctx
            scan.translateBy(x: dx, y: 0)
            plate(&scan, 38)
            plate(&scan, 62)
            fill(&scan, rect(31, eyeY - 2, 14, 4, 2), led)
            fill(&scan, rect(55, eyeY - 2, 14, 4, 2), led)
            smile(&ctx)
        case .needsYou:
            let s: CGFloat = still ? 1 : 1 + 0.12 * (0.5 - 0.5 * cos(t * 2 * .pi))
            var eyes = scaled(ctx, x: 50, y: eyeY, sx: s, sy: s)
            eye(&eyes, 38, r: 6)
            eye(&eyes, 62, r: 6)
            if let my = mouthY { fill(&ctx, ellipse(50, my + 1, 3.5, 4), k) }
        case .done:
            plate(&ctx, 38)
            plate(&ctx, 62)
            stroke(&ctx, quad((32, eyeY + 3), (38, eyeY - 6), (44, eyeY + 3)), led, 3.2)
            stroke(&ctx, quad((56, eyeY + 3), (62, eyeY - 6), (68, eyeY + 3)), led, 3.2)
            if let my = mouthY {
                var grin = quad((42, my - 1), (50, my + 8), (58, my - 1))
                grin.closeSubpath()
                fill(&ctx, grin, k)
            }
            fill(&ctx, circle(28, eyeY + 11, 4), Self.nosePink, opacity: 0.6)
            fill(&ctx, circle(72, eyeY + 11, 4), Self.nosePink, opacity: 0.6)
        }
    }

    private func smile(_ ctx: inout GraphicsContext) {
        guard let my = mouthY else { return }
        stroke(&ctx, quad((44, my), (50, my + 5), (56, my)), Self.ink, 2.4)
    }

    // MARK: Badge

    private func drawBadge(_ ctx: inout GraphicsContext) {
        switch mood {
        case .thinking:
            for (i, (x, y, r)) in [(CGFloat(82), CGFloat(14), CGFloat(3)), (90, 8, 3.5), (97, 3, 2.5)].enumerated() {
                let wave = still ? 1 : max(0, sin(t * 2 * .pi / 1.2 - Double(i) * 1.05))
                fill(&ctx, circle(x, y, r), body, opacity: 0.25 + 0.75 * wave)
            }
        case .needsYou:
            fill(&ctx, circle(84, 16, 10), Self.need)
            fill(&ctx, rect(82.5, 9.5, 3, 9, 1.5), .white)
            fill(&ctx, circle(84, 22, 1.7), .white)
        default:
            break
        }
    }
}

// MARK: - Picker

/// Choose a bot's animal, main color and eye color, with a live preview.
/// The face being previewed in the picker: the look, and the state shown.
/// The state is for trying faces out only; it's never saved on the bot.
struct AvatarPreview: Equatable {
    var look: BotLook
    var mood: AvatarMood = .idle

    /// Another animal, in the same state, so animals compare side by side.
    mutating func pick(_ animal: BotAnimal) { look.animal = animal }
    mutating func show(_ mood: AvatarMood) { self.mood = mood }
}

struct BotLookPicker: View {
    @Binding var look: BotLook
    /// The state the big face previews (New bot shows its own big face).
    @Binding var mood: AvatarMood
    /// Off when the screen shows its own big preview (New bot).
    var showsPreview = true
    private let columns = [GridItem(.adaptive(minimum: 64), spacing: Spacing.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if showsPreview {
                HStack {
                    Spacer()
                    BotAvatarView(look: look, mood: mood, size: 120)
                    Spacer()
                }
            }
            moods
            LazyVGrid(columns: columns, spacing: Spacing.sm) {
                ForEach(BotAnimal.allCases) { animal in
                    let picked = look.animal == animal
                    Button { var p = preview; p.pick(animal); look = p.look } label: {
                        VStack(spacing: 2) {
                            BotAvatarView(look: BotLook(animal: animal, bodyHex: look.bodyHex, eyeHex: look.eyeHex), size: 44)
                            Text(animal.name)
                                .font(AppFont.caption(picked ? .semibold : .regular))
                                .foregroundStyle(picked ? Color.primary : Color.secondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: CornerRadius.sm).strokeBorder(picked ? Color.primary : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(animal.name)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            swatches("Main color", BotLook.bodyColors, selected: look.bodyHex) { look.bodyHex = $0 }
            swatches("Eye color", BotLook.eyeColors, selected: look.eyeHex) { look.eyeHex = $0 }
        }
    }

    private var preview: AvatarPreview { AvatarPreview(look: look, mood: mood) }

    /// The states the face can show; tap one to preview it. Reduce Motion
    /// shows each state's still face.
    private var moods: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Preview a state").font(AppFont.caption(.semibold)).foregroundStyle(Color.secondaryText)
            // One row of five, each the same width, so none drops to a
            // line of its own.
            HStack(spacing: Spacing.xs) {
                ForEach(AvatarMood.allCases) { state in
                    let on = mood == state
                    Button { var p = preview; p.show(state); mood = p.mood } label: {
                        Text(state.name)
                            .font(AppFont.caption(on ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xs + 1)
                            .background(Capsule().fill(on ? Color.brandBlue.opacity(0.2) : Color.secondary.opacity(0.1)))
                            .overlay(Capsule().strokeBorder(on ? Color.brandBlue : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Preview \(state.name)"))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private func swatches(_ title: String, _ hexes: [String], selected: String, pick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(AppFont.caption(.semibold)).foregroundStyle(Color.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Even rows (12 as 12, 6 or 4 per row as width allows): never one
            // swatch on a line of its own.
            EvenGrid(spacing: Spacing.sm) {
                ForEach(Array(hexes.enumerated()), id: \.element) { index, hex in
                    Button { pick(hex) } label: {
                        Circle().fill(Color(hex: hex))
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1))
                            .frame(width: 24, height: 24)
                            .padding(3)
                            .overlay(Circle().strokeBorder(selected == hex ? Color.primary : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(index + 1)")
                    .accessibilityAddTraits(selected == hex ? .isSelected : [])
                }
            }
        }
    }
}

#Preview("Roster") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))]) {
            ForEach(BotAnimal.allCases) { animal in
                BotAvatarView(look: BotLook(animal: animal, bodyHex: "5b5bd6", eyeHex: "3fdcff"), size: 72)
            }
        }
        HStack {
            ForEach(AvatarMood.allCases, id: \.self) { mood in
                BotAvatarView(look: .lead, mood: mood, size: 56)
            }
        }
    }
    .padding()
}

// MARK: - Blink timing

/// When one bot blinks while idle: its own phase and a jittered interval of
/// 4 to 9 seconds, with an occasional double blink, all derived from the
/// bot's id with a stable hash (`hashValue` changes every launch), so each
/// bot keeps its rhythm and bots never blink in unison.
struct BlinkSchedule: Equatable, Sendable {
    struct Blink: Equatable { var time: Double; var isSecond: Bool }

    let seed: UInt64
    /// Average gap; each blink is jittered ±2.5 s, so gaps run 4 to 9 s.
    private static let slot = 6.5, jitter = 1.25, closed = 0.15, doubleGap = 0.35, doubleChance = 0.15

    init(seed: UInt64) { self.seed = seed }
    init(id: UUID) {
        self.seed = withUnsafeBytes(of: id.uuid) { Self.fnv1a(Array($0)) }
    }

    static func stableHash(_ text: String) -> UInt64 { fnv1a(Array(text.utf8)) }

    private static func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }

    /// A stable pseudo-random number in 0..<1 for slot `n` and stream `k`.
    private func random(_ n: Int64, _ k: UInt64) -> Double {
        var z = seed &+ UInt64(bitPattern: n) &* 0x9e37_79b9_7f4a_7c15 &+ k &* 0xd1b5_4a32_d192_ed03
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    private var phase: Double { random(0, 7) * Self.slot }

    private func blinks(inSlot n: Int64) -> [Blink] {
        let first = Double(n) * Self.slot + phase + (random(n, 1) * 2 - 1) * Self.jitter
        var out = [Blink(time: first, isSecond: false)]
        if random(n, 2) < Self.doubleChance { out.append(Blink(time: first + Self.doubleGap, isSecond: true)) }
        return out
    }

    /// Every blink starting in `from..<to`, in order.
    func blinks(from: Double, to: Double) -> [Blink] {
        let lo = Int64(((from - phase) / Self.slot).rounded(.down)) - 1
        let hi = Int64(((to - phase) / Self.slot).rounded(.up)) + 1
        return (lo...hi).flatMap(blinks(inSlot:)).filter { $0.time >= from && $0.time < to }
    }

    /// 1 when the eyes are open, 0.1 while they blink.
    func openness(at t: Double) -> CGFloat {
        let n = Int64(((t - phase) / Self.slot).rounded(.down))
        for slot in (n - 1)...(n + 1) {
            for b in blinks(inSlot: slot) where t >= b.time && t < b.time + Self.closed { return 0.1 }
        }
        return 1
    }
}
