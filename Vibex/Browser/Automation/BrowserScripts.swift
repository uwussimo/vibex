import Foundation

/// JavaScript injected into every browser tab.
enum BrowserScripts {
    /// Captures console output, uncaught errors, fetch and XHR activity and posts them to the host.
    static let capture = #"""
    (() => {
      if (window.__vibexCapture) { return; }
      window.__vibexCapture = true;
      const post = (name, body) => {
        try { window.webkit.messageHandlers[name].postMessage(body); } catch (e) {}
      };
      const format = (args) => args.map((a) => {
        if (a instanceof Error) { return a.stack || a.message; }
        if (typeof a === 'object') { try { return JSON.stringify(a); } catch (e) { return String(a); } }
        return String(a);
      }).join(' ');
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = (...args) => {
          post('vibexConsole', { level, text: format(args).slice(0, 2000), ts: Date.now() });
          try { original.apply(console, args); } catch (e) {}
        };
      }
      // Media events don't bubble, so these listen on the way down. Both are for BrowserTab's sleep.
      let mediaReported = 0;
      const reportMedia = (event) => {
        const media = event.target;
        if (!(media instanceof HTMLMediaElement) || media.paused || Date.now() - mediaReported < 20000) { return; }
        mediaReported = Date.now();
        post('vibexMedia', {});
      };
      document.addEventListener('playing', reportMedia, true);
      document.addEventListener('timeupdate', reportMedia, true);
      let inputReported = false;
      document.addEventListener('input', () => {
        if (inputReported) { return; }
        inputReported = true;
        post('vibexInput', {});
      }, true);
      window.addEventListener('error', (event) => {
        post('vibexConsole', { level: 'error', text: `${event.message} (${event.filename}:${event.lineno})`, ts: Date.now() });
      });
      window.addEventListener('unhandledrejection', (event) => {
        const reason = event.reason && (event.reason.stack || event.reason.message || String(event.reason));
        post('vibexConsole', { level: 'error', text: `Unhandled rejection: ${reason}`, ts: Date.now() });
      });
      const originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = async (input, init) => {
          const started = performance.now();
          const url = typeof input === 'string' ? input : (input && input.url) || String(input);
          const method = (init && init.method) || (input && input.method) || 'GET';
          try {
            const response = await originalFetch(input, init);
            post('vibexNetwork', { method, url, status: response.status, ms: Math.round(performance.now() - started), type: 'fetch', ts: Date.now() });
            return response;
          } catch (error) {
            post('vibexNetwork', { method, url, status: 0, error: String(error), ms: Math.round(performance.now() - started), type: 'fetch', ts: Date.now() });
            throw error;
          }
        };
      }
      const open = XMLHttpRequest.prototype.open;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__vibex = { method, url: String(url) };
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        const started = performance.now();
        this.addEventListener('loadend', () => {
          const info = this.__vibex || {};
          post('vibexNetwork', { method: info.method || 'GET', url: info.url || '', status: this.status, ms: Math.round(performance.now() - started), type: 'xhr', ts: Date.now() });
        });
        return send.apply(this, arguments);
      };
    })();
    """#
}
