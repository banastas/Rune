// Renders a page at a fixed size to a PNG with WebKit, offscreen: for scripts/make-brand.sh.
// (Headless Brave hung at its first screenshot, 2026-10-08; WebKit is on every Mac.)
//
//   swift scripts/brand/render.swift <file.html#fragment> <width> <height> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 5, let width = Int(args[2]), let height = Int(args[3]) else {
    FileHandle.standardError.write(Data("usage: render.swift <file.html#fragment> <width> <height> <out.png>\n".utf8))
    exit(2)
}
let parts = args[1].split(separator: "#", maxSplits: 1).map(String.init)
let file = URL(fileURLWithPath: parts[0]).standardizedFileURL
var components = URLComponents(url: file, resolvingAgainstBaseURL: false)!
components.fragment = parts.count > 1 ? parts[1] : nil
let output = URL(fileURLWithPath: args[4])

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    let view: WKWebView
    init(width: Int, height: Int) {
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        super.init()
        view.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Fonts and the page's script: a moment after the load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            config.snapshotWidth = NSNumber(value: Int(webView.bounds.width))   // 1 pixel a point
            webView.takeSnapshot(with: config) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write(Data("snapshot failed: \(String(describing: error))\n".utf8))
                    exit(1)
                }
                do { try png.write(to: output) } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
                exit(0)
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("load failed: \(error)\n".utf8)); exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = MainActor.assumeIsolated { Renderer(width: width, height: height) }
MainActor.assumeIsolated {
    // The page reads its fonts from site/fonts: the repository's root readable.
    _ = renderer.view.loadFileURL(components.url!, allowingReadAccessTo: file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
}
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { FileHandle.standardError.write(Data("timed out\n".utf8)); exit(1) }
app.run()
