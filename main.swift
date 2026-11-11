import AppKit
import simd

typealias V = SIMD2<Float>

// MARK: - Random & noise

struct RNG {
    var s: UInt64
    init(seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return s
    }
    mutating func f() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * f() }
    mutating func seed32() -> UInt32 { UInt32(truncatingIfNeeded: next() >> 16) }
}

@inline(__always) func hash2(_ x: Int32, _ y: Int32, _ seed: UInt32) -> Float {
    var h = UInt32(bitPattern: x) &* 374761393 &+ UInt32(bitPattern: y) &* 668265263 &+ seed &* 2246822519
    h = (h ^ (h >> 13)) &* 1274126177
    h ^= h >> 16
    return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
}

@inline(__always) func vnoise(_ x: Float, _ y: Float, _ seed: UInt32) -> Float {
    let xf = x.rounded(.down), yf = y.rounded(.down)
    let xi = Int32(xf), yi = Int32(yf)
    var tx = x - xf, ty = y - yf
    tx = tx * tx * (3 - 2 * tx)
    ty = ty * ty * (3 - 2 * ty)
    let a = hash2(xi, yi, seed), b = hash2(xi &+ 1, yi, seed)
    let c = hash2(xi, yi &+ 1, seed), d = hash2(xi &+ 1, yi &+ 1, seed)
    return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty
}

@inline(__always) func fbm(_ x: Float, _ y: Float, _ seed: UInt32) -> Float {
    let a = vnoise(x, y, seed)
    let b = vnoise(x * 2.03 + 17, y * 2.03 + 5, seed &+ 101)
    let c = vnoise(x * 4.1 + 3, y * 4.1 + 29, seed &+ 202)
    return (a * 4 + b * 2 + c) / 7
}

@inline(__always) func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

@inline(__always) func distSeg(_ px: Float, _ py: Float, _ ax: Float, _ ay: Float, _ bx: Float, _ by: Float) -> Float {
    let abx = bx - ax, aby = by - ay
    let t = max(0, min(1, ((px - ax) * abx + (py - ay) * aby) / (abx * abx + aby * aby)))
    let dx = px - (ax + abx * t), dy = py - (ay + aby * t)
    return (dx * dx + dy * dy).squareRoot()
}

// MARK: - Canvas (grease amount per pixel, 0...1)

final class Canvas {
    let w: Int, h: Int
    let scale: Float            // pixels per point
    let a: UnsafeMutablePointer<Float>
    let tmp: UnsafeMutablePointer<Float>

    init(w: Int, h: Int, scale: Float) {
        self.w = w; self.h = h; self.scale = scale
        a = .allocate(capacity: w * h); a.initialize(repeating: 0, count: w * h)
        tmp = .allocate(capacity: w * h); tmp.initialize(repeating: 0, count: w * h)
    }
    deinit { a.deallocate(); tmp.deallocate() }

    func clear() { a.update(repeating: 0, count: w * h) }

    @inline(__always) func add(_ x: Int, _ y: Int, _ v: Float) {
        let i = y * w + x
        let o = a[i]
        a[i] = o + v - o * v
    }

    /// White haze (visible on dark content) + slight darkening (visible on light content).
    func makeImage(gain: Float) -> CGImage? {
        let n = w * h
        var px = [UInt8](repeating: 0, count: n * 4)
        px.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            for i in 0..<n {
                let v = a[i]
                if v <= 0.002 { continue }
                let aw = min(0.7, v * gain)
                let ad = min(0.5, v * gain * 0.5)
                let alpha = aw + ad * (1 - aw)
                let c = UInt8(aw * 255)
                p[i * 4] = c; p[i * 4 + 1] = c; p[i * 4 + 2] = c
                p[i * 4 + 3] = UInt8(alpha * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Fingerprint

/// cx, cy, rx in pixels. angle 0 = fingertip pointing up.
func stampPrint(_ cv: Canvas, cx: Float, cy: Float, rx: Float, angle: Float, strength: Float,
                forceSmear: Bool = false, rng: inout RNG) {
    let aspect = rng.range(1.2, 1.45)
    let seed = rng.seed32()
    let kind = rng.f()                       // loop / whorl / arch
    let side: Float = rng.f() < 0.5 ? -1 : 1
    let period = rng.range(0.062, 0.08)
    let coreX = rng.range(-0.12, 0.12), coreY = rng.range(-0.3, 0.05)
    let spiral: Float = rng.f() < 0.5 ? (rng.f() < 0.5 ? 1 : -1) : 0
    let smear: Float = (forceSmear || rng.f() < 0.3) ? rng.range(0.06, 0.25) : 0
    let smearA = rng.range(0, 2 * .pi)
    let sdx = cos(smearA) * smear, sdy = sin(smearA) * smear
    let n = smear > 0 ? 7 : 1
    let pcx = rng.range(-0.35, 0.35), pcy = rng.range(-0.4, 0.4)
    let phase0 = rng.range(0, 2 * .pi)
    let twoPi: Float = 2 * .pi

    @inline(__always) func sample(_ qx: Float, _ qy: Float) -> Float {
        let vy = qy / aspect
        let ux = qx * (1 - 0.12 * vy)
        let n1 = fbm(qx * 1.7 + 11, qy * 1.7 + 5, seed)
        let e = (ux * ux + vy * vy).squareRoot() + (n1 - 0.5) * 0.3
        if e >= 1.05 { return 0 }
        let edge = 1 - smoothstep(0.7, 1.05, e)
        let ppx = qx - pcx, ppy = vy - pcy
        let press = max(0, 1 - 0.45 * (ppx * ppx + ppy * ppy))
        let patch = 0.3 + 0.7 * smoothstep(0.3, 0.6, fbm(qx * 2.3 + 40, qy * 2.3 + 17, seed &+ 7))
        let wx = qx + (fbm(qx * 1.3 + 3, qy * 1.3 + 9, seed &+ 1) - 0.5) * 0.35
        let wy = qy + (fbm(qx * 1.3 + 23, qy * 1.3 + 31, seed &+ 2) - 0.5) * 0.35
        var d: Float
        if kind < 0.55 {
            d = distSeg(wx, wy, coreX, coreY, side * 1.5, 2.2)
        } else if kind < 0.85 {
            let ax = wx - coreX, ay = (wy - coreY) * 0.72
            d = (ax * ax + ay * ay).squareRoot() + spiral * atan2(ay, ax) * period / twoPi
        } else {
            d = wy + 0.55 * exp(-wx * wx * 2.5)
        }
        let thick = (fbm(qx * 4, qy * 4, seed &+ 3) - 0.5) * 0.3
        let c = 0.5 + 0.5 * cos(twoPi * d / period + phase0)
        var r = smoothstep(0.3 + thick, 0.7 + thick, c)
        let g = vnoise(qx * 38, qy * 38, seed &+ 4)
        r *= 0.55 + 0.45 * smoothstep(0.2, 0.45, g)
        return edge * press * patch * (0.14 + 0.86 * r)
    }

    let ca = cos(angle), sa = sin(angle)
    let R = rx * aspect * 1.15 + smear * rx
    let x0 = max(0, Int(cx - R)), x1 = min(cv.w - 1, Int(cx + R))
    let y0 = max(0, Int(cy - R)), y1 = min(cv.h - 1, Int(cy + R))
    if x0 > x1 || y0 > y1 { return }
    for y in y0...y1 {
        for x in x0...x1 {
            let dx = Float(x) - cx, dy = Float(y) - cy
            let lx = (dx * ca + dy * sa) / rx, ly = (-dx * sa + dy * ca) / rx
            var acc: Float = 0
            if n == 1 {
                acc = sample(lx, ly)
            } else {
                for k in 0..<n {
                    let t = Float(k) / Float(n - 1) - 0.5
                    acc += sample(lx + sdx * t, ly + sdy * t)
                }
                acc /= Float(n)
            }
            if acc > 0 { cv.add(x, y, min(1, acc * strength)) }
        }
    }
}

// MARK: - Swipe streak (finger dragged along a curve)

func swipe(_ cv: Canvas, _ p0: V, _ p1: V, _ p2: V, width: Float, strength: Float, rng: inout RNG) {
    let L = simd_length(p1 - p0) + simd_length(p2 - p1)
    let steps = max(2, Int(L * 2))
    let seed = rng.seed32()
    let hw = width / 2
    let ns = Int(hw * 2)
    var minx = cv.w, maxx = -1, miny = cv.h, maxy = -1
    for i in 0...steps {
        let t = Float(i) / Float(steps)
        let u = 1 - t
        let p = p0 * (u * u) + p1 * (2 * u * t) + p2 * (t * t)
        var tan = (p1 - p0) * (2 * u) + (p2 - p1) * (2 * t)
        let tl = simd_length(tan)
        if tl < 1e-4 { continue }
        tan /= tl
        let nrm = V(-tan.y, tan.x)
        let lf = smoothstep(0, 0.04, t) * pow(1 - t, 1.3)
        if lf <= 0 { continue }
        for j in -ns...ns {
            let s = Float(j) * 0.5
            let edge = 1 - smoothstep(0.55, 1, abs(s) / hw)
            let st = vnoise(s * 0.4 / cv.scale * 2 + 100, t * L * 0.012, seed)
            let st2 = vnoise(s * 0.11 + 7, t * L * 0.004, seed &+ 1)
            let v = edge * (0.15 + 0.85 * st * st) * (0.4 + 0.6 * st2) * lf * strength
            let q = p + nrm * s
            let xi = Int(q.x.rounded()), yi = Int(q.y.rounded())
            if xi < 0 || yi < 0 || xi >= cv.w || yi >= cv.h { continue }
            let idx = yi * cv.w + xi
            if v > cv.tmp[idx] { cv.tmp[idx] = v }
            if xi < minx { minx = xi }; if xi > maxx { maxx = xi }
            if yi < miny { miny = yi }; if yi > maxy { maxy = yi }
        }
    }
    if maxx < minx { return }
    for y in miny...maxy {
        for x in minx...maxx {
            let idx = y * cv.w + x
            let v = cv.tmp[idx]
            if v > 0 { cv.add(x, y, v); cv.tmp[idx] = 0 }
        }
    }
}

// MARK: - Soft greasy haze (palm / cheek / sleeve)

func haze(_ cv: Canvas, cx: Float, cy: Float, rx: Float, ry: Float, angle: Float, strength: Float, rng: inout RNG) {
    let seed = rng.seed32()
    let ca = cos(angle), sa = sin(angle)
    let R = max(rx, ry) * 1.6
    let x0 = max(0, Int(cx - R)), x1 = min(cv.w - 1, Int(cx + R))
    let y0 = max(0, Int(cy - R)), y1 = min(cv.h - 1, Int(cy + R))
    if x0 > x1 || y0 > y1 { return }
    for y in y0...y1 {
        for x in x0...x1 {
            let dx = Float(x) - cx, dy = Float(y) - cy
            let lx = (dx * ca + dy * sa) / rx, ly = (-dx * sa + dy * ca) / ry
            let e2 = lx * lx + ly * ly
            if e2 > 2.4 { continue }
            let g = exp(-2.2 * e2)
            let blot = smoothstep(0.3, 0.75, fbm(lx * 1.6 + 9, ly * 1.6 + 4, seed))
            let streak = vnoise(lx * 2.0, ly * 26, seed &+ 5)
            let v = g * (0.25 + 0.75 * blot) * (0.55 + 0.45 * streak) * strength
            if v > 0.003 { cv.add(x, y, v) }
        }
    }
}

// MARK: - Scene

func addCluster(_ cv: Canvas, at c: V, rng: inout RNG) {
    let s = cv.scale
    let r = rng.f()
    let count = r < 0.4 ? 1 : (r < 0.7 ? 2 : (r < 0.9 ? 3 : 4))
    let ang = rng.range(-0.6, 0.6)
    let lateral = V(cos(ang), sin(ang)), tip = V(sin(ang), -cos(ang))
    let baseR = rng.range(22, 33) * s
    let arc: [Float] = [0, 0.55, 0.65, 0.1]
    let strength = rng.range(0.55, 1.0)
    for k in 0..<count {
        let rx = baseR * rng.range(0.88, 1.08)
        let off = (Float(k) - Float(count - 1) / 2) * baseR * rng.range(2.1, 2.5)
        let p = c + lateral * off + tip * (arc[k] * baseR * rng.range(0.6, 1.3))
        stampPrint(cv, cx: p.x, cy: p.y, rx: rx, angle: ang + rng.range(-0.15, 0.15),
                   strength: strength * rng.range(0.75, 1.1), rng: &rng)
    }
}

func buildScene(_ cv: Canvas, density: Float, rng: inout RNG) {
    let s = cv.scale
    let W = Float(cv.w), H = Float(cv.h)

    // big soft smears
    for _ in 0..<Int(5 * density) {
        haze(cv, cx: rng.range(0, W), cy: rng.range(0, H),
             rx: rng.range(90, 260) * s, ry: rng.range(50, 130) * s,
             angle: rng.range(-0.8, 0.8), strength: rng.range(0.1, 0.24), rng: &rng)
    }

    // somebody tried to wipe it with a sleeve
    if rng.f() < 0.8 {
        var p = V(rng.range(0.15, 0.5) * W, rng.range(0.2, 0.6) * H)
        var dir: Float = 1
        for _ in 0..<Int(rng.range(2, 5)) {
            let len = rng.range(260, 520) * s
            let q = p + V(dir * len, rng.range(30, 70) * s)
            let mid = (p + q) * 0.5 + V(0, rng.range(-70, 20) * s)
            swipe(cv, p, mid, q, width: rng.range(90, 150) * s, strength: rng.range(0.2, 0.32), rng: &rng)
            p = q; dir = -dir
        }
    }

    // scroll / drag swipes
    for _ in 0..<Int(7 * density) {
        let p0 = V(rng.range(0.08, 0.92) * W, rng.range(0.15, 0.9) * H)
        let len = rng.range(140, 480) * s
        let a: Float = rng.f() < 0.65 ? (rng.f() < 0.5 ? -.pi / 2 : .pi / 2) + rng.range(-0.3, 0.3)
                                       : (rng.f() < 0.5 ? 0 : .pi) + rng.range(-0.35, 0.35)
        let d = V(cos(a), sin(a))
        let p2 = p0 + d * len
        let mid = (p0 + p2) * 0.5 + V(-d.y, d.x) * (rng.range(-0.18, 0.18) * len)
        let w = rng.range(34, 52) * s
        if rng.f() < 0.6 {
            stampPrint(cv, cx: p0.x, cy: p0.y, rx: w * 0.55, angle: rng.range(-0.5, 0.5),
                       strength: rng.range(0.5, 0.8), forceSmear: true, rng: &rng)
        }
        swipe(cv, p0, mid, p2, width: w, strength: rng.range(0.3, 0.55), rng: &rng)
    }

    // taps
    for _ in 0..<Int(16 * density) {
        let r = rng.f()
        var c: V
        if r < 0.25 { c = V(rng.range(0.1, 0.9) * W, H - rng.range(20, 110) * s) }          // Dock
        else if r < 0.4 { c = V(rng.range(0.02, 0.98) * W, rng.range(8, 60) * s) }           // menu bar
        else if r < 0.55 { c = V((0.5 + rng.range(-0.18, 0.18)) * W, (0.5 + rng.range(-0.18, 0.18)) * H) }
        else { c = V(rng.range(0.04, 0.96) * W, rng.range(0.06, 0.94) * H) }
        addCluster(cv, at: c, rng: &rng)
    }

    // thumbs on the edges (opening the lid, adjusting the screen)
    for _ in 0..<Int(rng.range(3, 6) * density) {
        let r = rng.f()
        let rx = rng.range(36, 46) * s
        var c: V; var ang: Float
        if r < 0.5 { c = V(rng.range(0.15, 0.85) * W, rng.range(-8, 28) * s); ang = .pi }
        else if r < 0.75 { c = V(rng.range(-8, 28) * s, rng.range(0.2, 0.8) * H); ang = .pi / 2 }
        else { c = V(W - rng.range(-8, 28) * s, rng.range(0.2, 0.8) * H); ang = -.pi / 2 }
        stampPrint(cv, cx: c.x, cy: c.y, rx: rx, angle: ang + rng.range(-0.35, 0.35),
                   strength: rng.range(0.7, 1.0), rng: &rng)
    }
}

// MARK: - Preview mode (renders a PNG instead of running the app)

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--preview" {
    let w = 2400, h = 1500
    let cv = Canvas(w: w, h: h, scale: 2)
    var rng = RNG(seed: 7)
    buildScene(cv, density: 1, rng: &rng)
    let img = cv.makeImage(gain: 0.2)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let grad = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1),
                                                     CGColor(red: 0.16, green: 0.1, blue: 0.3, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
    // a made-up desktop: menu bar, one dark and one light window, a dock
    func box(_ r: CGRect, _ radius: CGFloat, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }
    func mockWindow(_ r: CGRect, body: CGFloat, bar: CGFloat, text: CGFloat) {
        box(r.insetBy(dx: -2, dy: -2), 26, CGColor(gray: 0, alpha: 0.35))
        box(r, 24, CGColor(gray: body, alpha: 1))
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 24, cornerHeight: 24, transform: nil))
        ctx.clip()
        ctx.setFillColor(CGColor(gray: bar, alpha: 1))
        ctx.fill(CGRect(x: r.minX, y: r.maxY - 76, width: r.width, height: 76))
        ctx.restoreGState()
        let dots: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.37, 0.34), (1, 0.74, 0.18), (0.16, 0.78, 0.25)]
        for (i, d) in dots.enumerated() {
            ctx.setFillColor(CGColor(red: d.0, green: d.1, blue: d.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: r.minX + 30 + CGFloat(i) * 40, y: r.maxY - 50, width: 24, height: 24))
        }
        var y = r.maxY - 150
        var k = 0
        while y > r.minY + 60 {
            let wdt = r.width * [0.78, 0.62, 0.84, 0.4, 0.7][k % 5]
            box(CGRect(x: r.minX + 50, y: y, width: wdt - 50, height: 18), 9, CGColor(gray: text, alpha: 1))
            y -= 52; k += 1
        }
    }
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.3))
    ctx.fill(CGRect(x: 0, y: h - 50, width: w, height: 50))
    mockWindow(CGRect(x: 160, y: 330, width: 1150, height: 880), body: 0.12, bar: 0.17, text: 0.24)
    mockWindow(CGRect(x: 1180, y: 480, width: 1040, height: 800), body: 0.96, bar: 0.9, text: 0.84)
    box(CGRect(x: 700, y: 24, width: 1000, height: 130), 40, CGColor(gray: 1, alpha: 0.16))
    for i in 0..<9 {
        let hue = CGFloat(i) / 9
        box(CGRect(x: 730 + CGFloat(i) * 106, y: 42, width: 92, height: 92), 22,
            NSColor(hue: hue, saturation: 0.55, brightness: 0.9, alpha: 1).cgColor)
    }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

// MARK: - App

final class Overlay {
    let screen: NSScreen
    let window: NSWindow
    let canvas: Canvas

    init(screen: NSScreen) {
        self.screen = screen
        let sc = Float(screen.backingScaleFactor)
        canvas = Canvas(w: Int(Float(screen.frame.width) * sc), h: Int(Float(screen.frame.height) * sc), scale: sc)
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
    }

    func show(_ image: CGImage?, fade: Bool) {
        guard let layer = window.contentView?.layer else { return }
        if fade {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.8
            layer.add(t, forKey: "fade")
        }
        layer.contents = image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var overlays: [Overlay] = []
    var statusItem: NSStatusItem!
    let work = DispatchQueue(label: "smudge.render", qos: .userInitiated)
    var clickMonitor: Any?
    var rng = RNG(seed: UInt64(Date().timeIntervalSince1970 * 1000))

    let levels: [(title: String, gain: Float, density: Float)] = [
        ("Light Touch", 0.09, 0.6), ("Everyday Grime", 0.15, 1.0), ("After a Kebab", 0.24, 1.9),
    ]
    var level: Int {
        get { UserDefaults.standard.object(forKey: "level") as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "level") }
    }
    var clickPrints: Bool {
        get { UserDefaults.standard.bool(forKey: "clickPrints") }
        set { UserDefaults.standard.set(newValue, forKey: "clickPrints") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "👆"
        rebuildMenu()
        rebuildOverlays()
        updateClickMonitor()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func rebuildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Smudge Again", action: #selector(regenerate), keyEquivalent: "r").target = self
        m.addItem(withTitle: "Touch Some More", action: #selector(addMore), keyEquivalent: "").target = self
        m.addItem(withTitle: "Wipe Screen", action: #selector(wipe), keyEquivalent: "").target = self
        m.addItem(.separator())
        for (i, l) in levels.enumerated() {
            let it = m.addItem(withTitle: l.title, action: #selector(setLevel(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; it.state = i == level ? .on : .off
        }
        m.addItem(.separator())
        let c = m.addItem(withTitle: "Fingerprint on Every Click", action: #selector(toggleClicks), keyEquivalent: "")
        c.target = self; c.state = clickPrints ? .on : .off
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    func rebuildOverlays() {
        overlays.forEach { $0.window.close() }
        overlays = NSScreen.screens.map { Overlay(screen: $0) }
        regenerate()
    }

    @objc func screensChanged() { rebuildOverlays() }

    func render(_ o: Overlay, fade: Bool, _ draw: @escaping (Canvas, inout RNG) -> Void) {
        let gain = levels[level].gain
        var r = RNG(seed: rng.next())
        work.async {
            draw(o.canvas, &r)
            let img = o.canvas.makeImage(gain: gain)
            DispatchQueue.main.async { o.show(img, fade: fade) }
        }
    }

    @objc func regenerate() {
        let density = levels[level].density
        for o in overlays {
            render(o, fade: true) { cv, r in cv.clear(); buildScene(cv, density: density, rng: &r) }
        }
    }

    @objc func addMore() {
        for o in overlays {
            render(o, fade: true) { cv, r in
                for _ in 0..<6 {
                    addCluster(cv, at: V(r.range(0.05, 0.95) * Float(cv.w), r.range(0.05, 0.95) * Float(cv.h)), rng: &r)
                }
            }
        }
    }

    @objc func wipe() {
        for o in overlays { render(o, fade: true) { cv, _ in cv.clear() } }
    }

    @objc func setLevel(_ sender: NSMenuItem) {
        level = sender.tag
        rebuildMenu()
        regenerate()
    }

    @objc func toggleClicks() {
        clickPrints.toggle()
        rebuildMenu()
        updateClickMonitor()
    }

    func updateClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        guard clickPrints else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.printAtMouse()
        }
    }

    func printAtMouse() {
        let loc = NSEvent.mouseLocation
        guard let o = overlays.first(where: { $0.screen.frame.contains(loc) }) else { return }
        let f = o.screen.frame
        let sc = o.canvas.scale
        let x = Float(loc.x - f.minX) * sc, y = Float(f.maxY - loc.y) * sc
        render(o, fade: false) { cv, r in
            stampPrint(cv, cx: x + r.range(-4, 4) * sc, cy: y + r.range(-2, 10) * sc, rx: r.range(22, 30) * sc,
                       angle: r.range(-0.5, 0.5), strength: r.range(0.6, 1.0), rng: &r)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
