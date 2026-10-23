import Foundation
import WebKit

/// The page a new browser tab opens on, served by Vibex itself at `vibex://newtab`: the dev servers
/// running on this Mac (refreshed every few seconds), and a few shortcuts. Replaces a blank page.
enum NewTabPage {
    static let scheme = "vibex"
    static let url = URL(string: "vibex://newtab")!
    static let serversURL = "vibex://newtab/servers"

    struct Server: Codable, Equatable, Sendable {
        var port: Int
        var process: String
        var url: String { "http://localhost:\(port)" }
    }

    static func isNewTab(_ url: URL?) -> Bool { url?.scheme == scheme }

    /// Ports macOS or Vibex itself listen on, which are never a project's dev server.
    nonisolated private static let ignoredPorts: Set<Int> = [5000, 7000, 5150]

    /// TCP ports this user's processes listen on, from `lsof`, minus apps' own helpers (Spotify,
    /// Discord, Figma…): a dev server's program lives outside an .app bundle. Fast enough to poll.
    @concurrent static func localServers() async -> [Server] {
        guard let data = try? Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-u", "\(getuid())", "-Fpcn"]) else { return [] }
        let listening = parseLsof(String(decoding: data, as: UTF8.self))
        guard !listening.isEmpty else { return [] }
        let pids = Set(listening.map(\.pid)).map(String.init).joined(separator: ",")
        let paths = (try? Shell.run("/bin/ps", ["-o", "pid=,comm=", "-p", pids])).map { parsePs(String(decoding: $0, as: UTF8.self)) } ?? [:]
        return listening
            .filter { isDevServer(command: $0.server.process, path: paths[$0.pid] ?? "") }
            .map(\.server)
    }

    /// Dev runtimes always count; otherwise a program inside an app bundle or the system's own
    /// folders (rapportd, ControlCenter) is a helper, not something the user is building.
    nonisolated static func isDevServer(command: String, path: String) -> Bool {
        let runtimes = ["node", "bun", "deno", "python", "ruby", "php", "java", "go", "dotnet", "beam.smp", "uvicorn", "gunicorn"]
        if runtimes.contains(where: { command.lowercased().hasPrefix($0) }) { return true }
        let systemFolders = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"]
        return !path.contains(".app/") && !systemFolders.contains(where: path.hasPrefix)
    }

    struct Listener: Equatable, Sendable {
        var pid: Int32
        var server: Server
    }

    /// `lsof -F` output: a `p<pid>` line, a `c<command>` line, then one `n<address>:<port>` per socket.
    nonisolated static func parseLsof(_ output: String) -> [Listener] {
        var byPort: [Int: Listener] = [:]
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            if line.hasPrefix("c") { command = String(line.dropFirst()) }
            guard line.hasPrefix("n"), let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) else { continue }
            guard port >= 1024, !ignoredPorts.contains(port) else { continue }
            byPort[port] = byPort[port] ?? Listener(pid: pid, server: Server(port: port, process: command))
        }
        return byPort.values.sorted { $0.server.port < $1.server.port }
    }

    /// `ps -o pid=,comm=` output: the pid, then the program's full path.
    nonisolated static func parsePs(_ output: String) -> [Int32: String] {
        var paths: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            paths[pid] = trimmed[space...].trimmingCharacters(in: .whitespaces)
        }
        return paths
    }

    static var html: String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>New Tab</title>
        <meta name="color-scheme" content="light dark">
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Google+Sans:wght@400..600&display=swap">
        <style>
          :root { --bg:#141416; --card:#1d1d21; --line:rgba(255,255,255,.08); --text:#f1f1f4; --muted:#8e8e98; --accent:#8194ff; --green:#3dd68c }
          @media (prefers-color-scheme: light) { :root { --bg:#f6f6f8; --card:#fff; --line:rgba(0,0,0,.08); --text:#18181d; --muted:#6a6a76; --accent:#4d63ff; --green:#1f9d55 } }
          * { box-sizing:border-box } html,body { margin:0; min-height:100%; background:var(--bg); color:var(--text); font:14px/1.5 "Google Sans",system-ui,sans-serif; -webkit-font-smoothing:antialiased }
          main { max-width:560px; margin:0 auto; padding:72px 24px }
          h1 { font-size:22px; font-weight:600; letter-spacing:-.02em; margin:0 0 4px } p { margin:0; color:var(--muted) }
          h2 { font-size:12px; font-weight:600; color:var(--muted); text-transform:uppercase; letter-spacing:.06em; margin:32px 0 10px }
          .list { display:grid; gap:8px }
          a.row { display:flex; align-items:center; gap:12px; padding:12px 14px; border-radius:12px; background:var(--card); border:1px solid var(--line); color:inherit; text-decoration:none; transition:border-color .15s ease, transform .12s ease }
          a.row:hover { border-color:var(--accent) } a.row:active { transform:scale(.99) }
          .dot { width:8px; height:8px; border-radius:50%; background:var(--green); flex:none }
          .row b { font-weight:500 } .row span { margin-left:auto; color:var(--muted); font-size:12.5px }
          .empty { padding:14px; border-radius:12px; border:1px dashed var(--line); color:var(--muted) }
          .grid { display:grid; grid-template-columns:repeat(4,1fr); gap:8px }
          .grid a { padding:14px 10px; text-align:center; border-radius:12px; background:var(--card); border:1px solid var(--line); color:inherit; text-decoration:none; font-weight:500 }
          .grid a:hover { border-color:var(--accent) }
          @media (prefers-reduced-motion: reduce) { a.row { transition:none } }
        </style></head><body><main>
          <h1>New Tab</h1>
          <p>Type a URL or search in the address bar, or pick something below.</p>
          <h2>Running on this Mac</h2>
          <div class="list" id="servers"><div class="empty">Looking for dev servers…</div></div>
          <h2>Shortcuts</h2>
          <div class="grid">
            <a href="https://www.netflix.com/browse">Netflix</a>
            <a href="https://www.youtube.com">YouTube</a>
            <a href="https://github.com">GitHub</a>
            <a href="https://skills.sh">skills.sh</a>
          </div>
        </main><script>
          const list = document.getElementById('servers');
          let last = '';
          async function refresh() {
            try {
              const servers = await (await fetch('\(serversURL)')).json();
              const key = JSON.stringify(servers);
              if (key === last) return;
              last = key;
              list.innerHTML = servers.length
                ? servers.map(s => `<a class="row" href="${s.url}"><i class="dot"></i><b>localhost:${s.port}</b><span>${s.process}</span></a>`).join('')
                : '<div class="empty">Nothing is listening on localhost yet. Start a dev server and it shows up here.</div>';
            } catch (e) {}
          }
          refresh();
          setInterval(() => { if (!document.hidden) refresh(); }, 3000);
        </script></body></html>
        """
    }
}

/// Serves `vibex://newtab` and the JSON list of local servers its script polls.
final class NewTabSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = NewTabSchemeHandler()
    private var stopped: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        if url.path == "/servers" {
            let id = ObjectIdentifier(task)
            Task {
                let servers = await NewTabPage.localServers()
                guard stopped.remove(id) == nil else { return }
                respond(task, url: url, type: "application/json", data: (try? JSONEncoder().encode(servers)) ?? Data("[]".utf8))
            }
        } else {
            respond(task, url: url, type: "text/html", data: Data(NewTabPage.html.utf8))
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, type: String, data: Data) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "\(type); charset=utf-8",
            "Cache-Control": "no-store",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
