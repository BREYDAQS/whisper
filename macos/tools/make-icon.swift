// Generator ikony aplikacji z jednego źródła: icon.svg w katalogu repo
// (maskotka Breydaqs, ta sama ikona co w wersji na Windows); bez SVG —
// icon.png.
//
//   swift macos/tools/make-icon.swift [--master plik.png]
//
// Wynik trafia do macos/Resources/AppIcon.icns i jest w repo, więc zwykły
// build go nie generuje. `--master` zapisuje dodatkowo kwadrat 1024 px bez
// marginesu — z niego `cargo tauri icon` robi ikony Windows.
//
// SVG rysujemy wektorowo w docelowym rozmiarze — ostre na każdym. PNG ma
// ~300 px, a ikony potrzebują 1024: grafika jest czysto czarno-biała, więc
// po powiększeniu krawędzie wyostrzamy krzywą na kanałach.

import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let repo = root.deletingLastPathComponent()
let svg = repo.appendingPathComponent("icon.svg")
let isVector = FileManager.default.fileExists(atPath: svg.path)
let source = isVector ? svg : repo.appendingPathComponent("icon.png")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

guard let image = NSImage(contentsOf: source), image.size.width > 0 else {
    fatalError("Brak \(source.path)")
}

/// Kafel `size`×`size`, grafika wpisana w środek na `inset` boku (reszta
/// przezroczysta), skalowana wysoką jakością i wyostrzona.
func render(size: Int, inset: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let side = CGFloat(size) * inset
    // Źródło nie jest idealnym kwadratem (294×295): wpisujemy dłuższy bok.
    let scale = side / max(image.size.width, image.size.height)
    let w = image.size.width * scale, h = image.size.height * scale
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()

    // Wyostrzenie tylko powiększanego PNG: smoothstep wokół połowy jasności.
    if !isVector, scale > 1.5, let data = ctx.data {
        let px = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        func sharpen(_ v: Double) -> Double {
            let t = min(max((v - 0.3) / 0.4, 0), 1)
            return t * t * (3 - 2 * t)
        }
        for i in stride(from: 0, to: size * size * 4, by: 4) {
            let a = Double(px[i + 3]) / 255
            guard a > 0 else { continue }
            let na = sharpen(a)
            for c in 0..<3 {
                // kanały są przemnożone przez alfę — odwracamy, ostrzymy, mnożymy z nową
                let v = min(Double(px[i + c]) / 255 / a, 1)
                px[i + c] = UInt8((sharpen(v) * na * 255).rounded())
            }
            px[i + 3] = UInt8((na * 255).rounded())
        }
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// macOS: siatka Apple — kafel 824 w płótnie 1024, żeby ikona w Docku miała
// ten sam rozmiar co inne aplikacje.
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        write(render(size: base * scale, inset: 824.0 / 1024.0),
              to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! task.run()
task.waitUntilExit()
print("Zapisano \(output.path) (źródło: \(source.lastPathComponent))")

// Pasek menu: obraz-szablon (liczy się tylko alfa, kolor daje system).
// Bezczynna — sama maskotka (jasne linie, kadr na głowę); nasłuch — pełny
// kafel z maskotką wyciętą (ciemne pola). Jak dawniej circle / circle.fill.
func menuBar(px: Int, active: Bool) -> CGImage {
    let tile = render(size: px, inset: active ? 1 : 295.0 / 212.0)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(tile, in: CGRect(x: 0, y: 0, width: px, height: px))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: px * px * 4)
    for i in stride(from: 0, to: px * px * 4, by: 4) {
        let a = Double(p[i + 3]) / 255
        guard a > 0 else { continue }
        // grafika czarno-biała: R = jasność; tło #08090A nie jest czarne — próg
        let lum = min(max((Double(p[i]) / 255 / a - 0.1) / 0.8, 0), 1)
        let alpha = (active ? 1 - lum : lum) * a
        let v = UInt8((alpha * 255).rounded())
        (p[i], p[i + 1], p[i + 2], p[i + 3]) = (v, v, v, v)
    }
    return ctx.makeImage()!
}
for active in [false, true] {
    let name = active ? "MenuBarIconActive" : "MenuBarIcon"
    for scale in [1, 2] {
        let url = root.appendingPathComponent("Resources/\(name)\(scale == 2 ? "@2x" : "").png")
        write(menuBar(px: 18 * scale, active: active), to: url)
        print("Zapisano \(url.path)")
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--master"), CommandLine.arguments.count > i + 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    write(render(size: 1024, inset: 1), to: url)
    print("Zapisano \(url.path)")
}
