import Foundation

/// The in-page half of browser automation: a compact accessibility-style snapshot with element refs,
/// and ref-based actions. Everything lives under `window.__vibex`.
enum SnapshotScript {
    static let source = #"""
    (() => {
      const V = (window.__vibex = window.__vibex || {});
      V.refs = new Map();
      const INTERACTIVE = new Set(['a', 'button', 'input', 'select', 'textarea', 'summary', 'option']);
      const ROLE_FOR_TAG = {
        a: 'link', button: 'button', input: 'textbox', select: 'combobox', textarea: 'textbox',
        h1: 'heading', h2: 'heading', h3: 'heading', h4: 'heading', h5: 'heading', h6: 'heading',
        img: 'img', nav: 'navigation', main: 'main', header: 'banner', footer: 'contentinfo', form: 'form',
        table: 'table', ul: 'list', ol: 'list', li: 'listitem', dialog: 'dialog', summary: 'button', video: 'video', audio: 'audio',
      };
      const clean = (s) => (s || '').replace(/\s+/g, ' ').trim();
      const isVisible = (el) => {
        if (!(el instanceof Element)) return false;
        const style = getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
        if (el.getAttribute('aria-hidden') === 'true') return false;
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      };
      const roleOf = (el) => {
        const explicit = el.getAttribute('role');
        if (explicit) return explicit;
        const tag = el.tagName.toLowerCase();
        if (tag === 'input') {
          const t = (el.getAttribute('type') || 'text').toLowerCase();
          if (t === 'checkbox' || t === 'radio') return t;
          if (t === 'submit' || t === 'button' || t === 'reset') return 'button';
          if (t === 'hidden') return null;
          return 'textbox';
        }
        if (tag === 'a' && !el.hasAttribute('href')) return null;
        return ROLE_FOR_TAG[tag] || null;
      };
      const isInteractive = (el) => {
        const tag = el.tagName.toLowerCase();
        if (INTERACTIVE.has(tag)) return tag !== 'a' || el.hasAttribute('href');
        const role = el.getAttribute('role');
        if (role && /button|link|checkbox|radio|tab|menuitem|option|switch|slider|textbox|combobox|searchbox/.test(role)) return true;
        if (el.hasAttribute('onclick') || el.hasAttribute('contenteditable')) return true;
        const ti = el.getAttribute('tabindex');
        return ti !== null && ti !== '-1';
      };
      const nameOf = (el) => {
        const aria = el.getAttribute('aria-label');
        if (aria) return clean(aria);
        const labelledBy = el.getAttribute('aria-labelledby');
        if (labelledBy) {
          const parts = labelledBy.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => clean(n.textContent));
          if (parts.join(' ')) return parts.join(' ');
        }
        const tag = el.tagName.toLowerCase();
        if (tag === 'img') return clean(el.getAttribute('alt') || el.getAttribute('title'));
        if (tag === 'input' || tag === 'textarea' || tag === 'select') {
          if (el.id) { const l = document.querySelector(`label[for="${CSS.escape(el.id)}"]`); if (l) return clean(l.textContent); }
          const wrapping = el.closest('label');
          if (wrapping) return clean(wrapping.textContent);
          return clean(el.getAttribute('placeholder') || el.getAttribute('name') || el.getAttribute('title'));
        }
        return clean(el.innerText || el.textContent).slice(0, 120);
      };
      const details = (el) => {
        const tag = el.tagName.toLowerCase();
        const out = [];
        if (tag === 'a' && el.href) out.push(`href=${el.getAttribute('href')}`);
        if (tag === 'input' || tag === 'textarea') {
          const t = (el.getAttribute('type') || 'text').toLowerCase();
          if (t === 'checkbox' || t === 'radio') out.push(el.checked ? 'checked' : 'unchecked');
          else if (t !== 'password' && el.value) out.push(`value=${JSON.stringify(el.value.slice(0, 60))}`);
          if (el.placeholder) out.push(`placeholder=${JSON.stringify(el.placeholder)}`);
        }
        if (tag === 'select') out.push(`value=${JSON.stringify(el.value)}`);
        if (el.disabled) out.push('disabled');
        if (el.getAttribute('aria-expanded')) out.push(`expanded=${el.getAttribute('aria-expanded')}`);
        if (el.getAttribute('aria-selected') === 'true') out.push('selected');
        if (/^h[1-6]$/.test(tag)) out.push(`level=${tag[1]}`);
        return out.length ? ' ' + out.join(' ') : '';
      };
      const lines = [];
      let counter = 0;
      const limit = 600;
      const budget = { chars: 40000 };
      const push = (depth, text) => {
        if (lines.length >= limit || budget.chars <= 0) return;
        const line = '  '.repeat(depth) + text;
        budget.chars -= line.length;
        lines.push(line);
      };
      const walk = (node, depth) => {
        if (lines.length >= limit) return;
        if (node.nodeType === Node.TEXT_NODE) {
          const text = clean(node.textContent);
          if (text && !isInteractive(node.parentElement)) push(depth, `text "${text.slice(0, 160)}"`);
          return;
        }
        if (node.nodeType !== Node.ELEMENT_NODE) return;
        const el = node;
        const tag = el.tagName.toLowerCase();
        if (['script', 'style', 'noscript', 'template', 'svg', 'path'].includes(tag)) return;
        if (!isVisible(el)) return;
        const role = roleOf(el);
        const interactive = isInteractive(el);
        let childDepth = depth;
        if (interactive || (role && role !== 'listitem' && role !== 'list') || tag === 'li') {
          const ref = `e${++counter}`;
          V.refs.set(ref, el);
          const name = nameOf(el);
          push(depth, `${role || tag} ${name ? JSON.stringify(name) : ''} [ref=${ref}]${details(el)}`.replace(/\s+\[/, ' ['));
          childDepth = depth + 1;
          if (interactive && tag !== 'li' && !el.querySelector('input,button,a[href],select,textarea')) return;
        }
        for (const child of el.childNodes) walk(child, childDepth);
      };
      push(0, `page "${clean(document.title)}" url=${location.href}`);
      walk(document.body, 1);
      if (lines.length >= limit) push(0, '… (truncated)');
      return lines.join('\n');
    })()
    """#

    static let actions = #"""
    (() => {
      const V = (window.__vibex = window.__vibex || {});
      V.refs = V.refs || new Map();
      V.el = (ref) => { const el = V.refs.get(ref); if (!el || !el.isConnected) throw new Error(`ref ${ref} is stale; call browser_snapshot again`); return el; };
      V.click = (ref) => {
        const el = V.el(ref);
        el.scrollIntoView({ block: 'center', inline: 'center' });
        const r = el.getBoundingClientRect();
        const x = r.left + r.width / 2, y = r.top + r.height / 2;
        const opts = { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window };
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
          el.dispatchEvent(type.startsWith('pointer') ? new PointerEvent(type, opts) : new MouseEvent(type, opts));
        }
        if (typeof el.focus === 'function') el.focus();
        return `clicked ${el.tagName.toLowerCase()}`;
      };
      V.type = (ref, text, submit) => {
        const el = V.el(ref);
        el.scrollIntoView({ block: 'center' });
        el.focus();
        if (el.isContentEditable) {
          document.execCommand('selectAll', false, null);
          document.execCommand('insertText', false, text);
        } else {
          const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) setter.set.call(el, text); else el.value = text;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        if (submit) {
          const key = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
          const prevented = !el.dispatchEvent(new KeyboardEvent('keydown', key));
          el.dispatchEvent(new KeyboardEvent('keyup', key));
          if (!prevented && el.form) el.form.requestSubmit();
        }
        return `typed ${text.length} chars`;
      };
      V.press = (key) => {
        const el = document.activeElement || document.body;
        const map = { enter: ['Enter', 13], escape: ['Escape', 27], tab: ['Tab', 9], backspace: ['Backspace', 8], space: [' ', 32], arrowdown: ['ArrowDown', 40], arrowup: ['ArrowUp', 38], arrowleft: ['ArrowLeft', 37], arrowright: ['ArrowRight', 39] };
        const [k, code] = map[key.toLowerCase()] || [key, key.length === 1 ? key.charCodeAt(0) : 0];
        const init = { key: k, code: k, keyCode: code, which: code, bubbles: true, cancelable: true };
        const prevented = !el.dispatchEvent(new KeyboardEvent('keydown', init));
        el.dispatchEvent(new KeyboardEvent('keyup', init));
        if (!prevented && k === 'Enter' && el.form) el.form.requestSubmit();
        return `pressed ${k}`;
      };
      V.scroll = (ref, dx, dy) => {
        if (ref) { V.el(ref).scrollBy({ left: dx, top: dy, behavior: 'instant' }); }
        else { window.scrollBy({ left: dx, top: dy, behavior: 'instant' }); }
        return `scrolled by ${dx},${dy}; scrollY=${Math.round(window.scrollY)}`;
      };
      V.text = () => (document.body && document.body.innerText || '').slice(0, 60000);
      return 'ok';
    })()
    """#
}
