// Renders docs/icon.svg to a 1024×1024 PNG with WebKit, which draws the SVG drop-shadow filters.
// Usage: swift scripts/render-icon.swift docs/icon.svg docs/icon-1024.png
import AppKit
import WebKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: render-icon <in.svg> <out.png>\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let svg = try String(contentsOf: input, encoding: .utf8)

@MainActor final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let output: URL

    init(svg: String, output: URL) {
        self.output = output
        // The page is laid out in CSS points; a 512-point view at 2x backing gives 1024 pixels.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 512, height: 512))
        webView.setValue(false, forKey: "drawsBackground")
        super.init()
        webView.navigationDelegate = self
        let html = """
        <!doctype html><html><head><style>
        html,body{margin:0;padding:0;background:transparent}
        svg{display:block;width:512px;height:512px}
        </style></head><body>\(svg)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: 512, height: 512)
        configuration.snapshotWidth = 512 as NSNumber // points; 1024 px on a 2x screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            webView.takeSnapshot(with: configuration) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
                    FileHandle.standardError.write(Data("snapshot failed: \(String(describing: error))\n".utf8))
                    exit(1)
                }
                rep.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
                do {
                    try png.write(to: self.output)
                    print("wrote \(self.output.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                    exit(1)
                }
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let renderer = Renderer(svg: svg, output: output)
    withExtendedLifetime(renderer) { app.run() }
}
