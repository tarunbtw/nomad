//
//  WebKitPool.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import WebKit

/// Manages WebKit resources, configurations, and extension-readiness.
enum WebKitPool {
    /// Standard user-agent matching the system Safari version to prevent Google CAPTCHAs and compatibility warnings.
    static let customUserAgent: String = {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let safariVer = osVersion >= 26 ? "\(osVersion).0" : "\(osVersion + 3).0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVer) Safari/605.1.15"
    }()

    /// Creates a standardized WKWebViewConfiguration.
    /// Ready for WebExtensions (WKWebExtensionController) and custom user scripts.
    @MainActor
    static func makeConfiguration(isIncognito: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        if isIncognito {
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        }
        ExtensionManager.shared.attach(config)
        
        // Enable modern web preferences with full desktop mode
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        prefs.preferredContentMode = .desktop
        config.defaultWebpagePreferences = prefs
        
        // Developer extras for Web Inspector
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Do not throttle background tabs so agent automation, timers, and mutations run at full speed
        config.preferences.inactiveSchedulingPolicy = .none
        // Enable HTML5 video fullscreen expansion
        config.preferences.isElementFullscreenEnabled = true
        // Automatically upgrade known hosts to HTTPS
        config.upgradeKnownHostsToHTTPS = true
        
        // Use the configuration's userContentController directly so WebExtensions stay bound
        let ucc = config.userContentController
        ContentBlockerService.shared.attach(to: ucc)
        
        // Suppress horizontal elastic overscroll bounce
        let globalFixes = """
        (function() {
            const s = document.createElement('style');
            s.id = 'nomad-viewport-fixes';
            s.textContent = `
                html, body {
                    overscroll-behavior-x: none !important;
                }
            `;
            if (document.head) {
                document.head.appendChild(s);
            } else {
                document.addEventListener('DOMContentLoaded', () => {
                    if (document.head && !document.getElementById('nomad-viewport-fixes')) {
                        document.head.appendChild(s);
                    }
                });
            }
        })();
        """
        let userScript = WKUserScript(source: globalFixes, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        ucc.addUserScript(userScript)

        // Capture console output for Nomad DevX Console
        let consoleInterceptor = """
        (function() {
            if (window.__nomad_console_hooked) return;
            window.__nomad_console_hooked = true;
            const origLog = console.log;
            const origWarn = console.warn;
            const origError = console.error;
            function send(lvl, args) {
                try {
                    const str = Array.from(args).map(a => {
                        if (typeof a === 'object') {
                            try { return JSON.stringify(a); } catch(e) { return String(a); }
                        }
                        return String(a);
                    }).join(' ');
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadConsole) {
                        window.webkit.messageHandlers.nomadConsole.postMessage({ level: lvl, message: str });
                    }
                } catch(e) {}
            }
            function maskNative(fn, name) {
                try {
                    Object.defineProperty(fn, 'name', { value: name, configurable: true });
                    Object.defineProperty(fn, 'toString', {
                        value: function() { return 'function ' + name + '() { [native code] }'; },
                        configurable: true
                    });
                } catch(e) {}
            }
            console.log = function(...args) { origLog.apply(console, args); send('log', args); };
            console.warn = function(...args) { origWarn.apply(console, args); send('warn', args); };
            console.error = function(...args) { origError.apply(console, args); send('error', args); };
            maskNative(console.log, 'log');
            maskNative(console.warn, 'warn');
            maskNative(console.error, 'error');
        })();
        """
        ucc.addUserScript(WKUserScript(source: consoleInterceptor, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // Capture fetch and XMLHttpRequest network activity for Nomad DevX Network Tab
        let networkInterceptor = """
        (function() {
            if (window.__nomad_network_hooked) return;
            window.__nomad_network_hooked = true;

            function maskNative(fn, name) {
                try {
                    Object.defineProperty(fn, 'name', { value: name, configurable: true });
                    Object.defineProperty(fn, 'toString', {
                        value: function() { return 'function ' + name + '() { [native code] }'; },
                        configurable: true
                    });
                } catch(e) {}
            }

            function sendNet(entry) {
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadNetwork) {
                        window.webkit.messageHandlers.nomadNetwork.postMessage(entry);
                    }
                } catch(e) {}
            }

            // Hook window.fetch
            const origFetch = window.fetch;
            if (origFetch) {
                window.fetch = async function(...args) {
                    const startTime = performance.now();
                    let method = 'GET';
                    let url = '';
                    try {
                        if (typeof args[0] === 'string') {
                            url = args[0];
                        } else if (args[0] && args[0].url) {
                            url = args[0].url;
                            if (args[0].method) method = String(args[0].method).toUpperCase();
                        }
                        if (args[1] && args[1].method) {
                            method = String(args[1].method).toUpperCase();
                        }
                    } catch(e) {}

                    try {
                        const res = await origFetch.apply(this, args);
                        const duration = Math.round(performance.now() - startTime);
                        sendNet({
                            method: method,
                            url: url || (res ? res.url : ''),
                            status: res ? res.status : 200,
                            duration: duration,
                            type: 'fetch'
                        });
                        return res;
                    } catch(err) {
                        const duration = Math.round(performance.now() - startTime);
                        sendNet({
                            method: method,
                            url: url,
                            status: 0,
                            duration: duration,
                            type: 'fetch',
                            error: err ? err.message : 'Network error'
                        });
                        throw err;
                    }
                };
                maskNative(window.fetch, 'fetch');
            }

            // Hook XMLHttpRequest
            const origOpen = XMLHttpRequest.prototype.open;
            const origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                this.__nomad_method = (method || 'GET').toUpperCase();
                this.__nomad_url = url;
                return origOpen.apply(this, [method, url, ...rest]);
            };
            XMLHttpRequest.prototype.send = function(...args) {
                const startTime = performance.now();
                const xhr = this;
                this.addEventListener('loadend', function() {
                    const duration = Math.round(performance.now() - startTime);
                    sendNet({
                        method: xhr.__nomad_method || 'GET',
                        url: xhr.__nomad_url || '',
                        status: xhr.status || 0,
                        duration: duration,
                        type: 'xhr'
                    });
                }, { once: true });
                return origSend.apply(this, args);
            };
            maskNative(XMLHttpRequest.prototype.open, 'open');
            maskNative(XMLHttpRequest.prototype.send, 'send');
        })();
        """
        ucc.addUserScript(WKUserScript(source: networkInterceptor, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // Nomad Sub-Frame Script: Pierces cross-origin iframes (Stripe, OAuth, reCAPTCHA, embeds)
        // Injected with forMainFrameOnly: false at document start so nested execution contexts are captured immediately.
        let framePiercerScript = """
        (function() {
            if (window.__nomad_frame_injected) return;
            window.__nomad_frame_injected = true;

            // Only run agent message listener and element scanner inside subframes (window !== window.top)
            if (window !== window.top) {
                function scanFrameElements() {
                    var list = [];
                    var sel = 'a, button, input, textarea, select, details, summary, h1, h2, h3, h4, h5, h6, img, li, p, td, th, pre, code, blockquote, canvas, [draggable], [ondragstart], [ondrop], [id*="hit"], [id*="drag"], [id*="drop"], [class*="drag"], [class*="drop"], [class*="dropzone"], [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="combobox"], [role="menuitem"], [role="tab"], [role="switch"], [role="option"], [role="heading"], [role="listitem"], [role="status"], [role="alert"], [role="cell"], [tabindex]:not([tabindex="-1"]), [contenteditable="true"]';
                    try {
                        var found = document.querySelectorAll(sel);
                        var counter = 1;
                        for (var i = 0; i < found.length; i++) {
                            var el = found[i];
                            var rect = el.getBoundingClientRect();
                            if (rect.width <= 0 || rect.height <= 0) continue;
                            var style = window.getComputedStyle(el);
                            if (style.display === 'none' || style.visibility === 'hidden') continue;
                            
                            var id = el.getAttribute('data-nomad-id') || ('e' + (counter++));
                            el.setAttribute('data-nomad-id', id);
                            var tag = el.tagName.toLowerCase();
                            var domId = el.id ? String(el.id).trim() : null;
                            var text = (el.getAttribute('aria-label') || el.placeholder || el.innerText || el.textContent || '').trim().replace(/\\s+/g, ' ').substring(0, 120);
                            if (!text && (tag === 'input' || tag === 'select' || tag === 'textarea')) {
                                if (el.id) {
                                    var lbl = document.querySelector('label[for="' + el.id + '"]');
                                    if (lbl) text = (lbl.innerText || lbl.textContent || '').trim();
                                }
                                if (!text && el.closest) {
                                    var parentLbl = el.closest('label');
                                    if (parentLbl) {
                                        var cloned = parentLbl.cloneNode(true);
                                        var chInputs = cloned.querySelectorAll('input, select, textarea');
                                        for (var ci = 0; ci < chInputs.length; ci++) chInputs[ci].remove();
                                        text = (cloned.innerText || cloned.textContent || '').trim();
                                    }
                                }
                            }
                            if (!text && (tag === 'canvas' || el.draggable === true || el.id === 'hit')) {
                                text = domId ? ('#' + domId) : (tag === 'canvas' ? 'canvas' : '');
                            }
                            var val = (tag === 'input' || tag === 'textarea' || tag === 'select') ? String(el.value || '').substring(0, 50) : null;
                            var rawType = (el.type || el.getAttribute('type') || '').toLowerCase();
                            var isChecked = Boolean(
                                el.checked ||
                                el.getAttribute('aria-checked') === 'true' ||
                                (el.querySelector && el.querySelector('input') && (el.querySelector('input').checked || el.querySelector('input').getAttribute('aria-checked') === 'true'))
                            );
                            
                            list.push({
                                id: id,
                                tag: tag,
                                domId: domId,
                                role: el.getAttribute('role') || tag,
                                text: text,
                                value: val,
                                type: rawType || null,
                                checked: isChecked,
                                disabled: Boolean(el.disabled || el.getAttribute('aria-disabled') === 'true'),
                                selected: Boolean(el.selected || el.getAttribute('aria-selected') === 'true'),
                                readOnly: Boolean(el.readOnly || el.getAttribute('aria-readonly') === 'true'),
                                bounds: {
                                    x: Math.round(rect.left),
                                    y: Math.round(rect.top),
                                    width: Math.round(rect.width),
                                    height: Math.round(rect.height)
                                }
                            });
                        }
                    } catch(e) {}

                    // Fallback for raw text, JSON, or minimal bodies rendered in navigated subframes
                    if (list.length === 0 && document.body) {
                        try {
                            var bText = (document.body.innerText || document.body.textContent || '').trim().replace(/\\s+/g, ' ').substring(0, 200);
                            if (bText.length > 0) {
                                var br = document.body.getBoundingClientRect();
                                list.push({
                                    id: 'e1',
                                    tag: 'body',
                                    role: 'document',
                                    text: bText,
                                    value: null,
                                    type: null,
                                    checked: false,
                                    disabled: false,
                                    selected: false,
                                    readOnly: false,
                                    bounds: {
                                        x: Math.max(0, Math.round(br.left)),
                                        y: Math.max(0, Math.round(br.top)),
                                        width: Math.max(20, Math.round(br.width || window.innerWidth)),
                                        height: Math.max(20, Math.round(br.height || window.innerHeight))
                                    }
                                });
                            }
                        } catch(e) {}
                    }
                    return list;
                }

                function reportToTop(assignedId) {
                    try {
                        var fid = assignedId || window.__nomad_frame_id || null;
                        var elements = scanFrameElements();
                        var payload = {
                            type: '__nomad_frame_report',
                            frameId: fid,
                            url: window.location.href,
                            title: document.title || '',
                            elements: elements
                        };
                        try { window.top.postMessage(payload, '*'); } catch(e) {}
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadFrameBridge) {
                            try {
                                window.webkit.messageHandlers.nomadFrameBridge.postMessage({
                                    frameId: fid,
                                    url: window.location.href,
                                    title: document.title || '',
                                    elementCount: elements.length
                                });
                            } catch(e) {}
                        }
                        return payload;
                    } catch(e) {
                        return { type: '__nomad_frame_report', frameId: assignedId, url: '', title: '', elements: [] };
                    }
                }

                // Listen for scan requests and action execution dispatched from top frame
                window.addEventListener('message', function(e) {
                    if (!e.data || typeof e.data !== 'object') return;
                    if (e.data.type === '__nomad_frame_request_scan') {
                        if (e.data.frameId) {
                            window.__nomad_frame_id = e.data.frameId;
                        }
                        var fid = e.data.frameId || window.__nomad_frame_id || null;
                        var rep = reportToTop(fid);
                        if (e.ports && e.ports[0]) {
                            try { e.ports[0].postMessage({ success: true, count: rep.elements.length, frameId: fid, report: rep }); } catch(err) {}
                        }
                    } else if (e.data.type === '__nomad_frame_action') {
                        var targetId = e.data.target;
                        var actionObj = e.data.action || {};
                        var act = (actionObj.action || actionObj.type || 'click').toLowerCase();
                        var targetEl = document.querySelector('[data-nomad-id="' + targetId + '"]') || document.getElementById(targetId);
                        if (!targetEl) {
                            try {
                                e.source.postMessage({
                                    type: '__nomad_frame_action_result',
                                    actionId: e.data.actionId,
                                    result: { success: false, code: 'ELEMENT_NOT_FOUND', message: 'Element ' + targetId + ' not found in frame' }
                                }, '*');
                            } catch(err) {}
                            return;
                        }
                        try { targetEl.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } catch(err) {}
                        if (act === 'click') {
                            try { targetEl.focus(); } catch(err) {}
                            targetEl.click();
                            if (targetEl.tagName !== 'INPUT') {
                                var innerInput = targetEl.querySelector ? targetEl.querySelector('input') : null;
                                if (innerInput) {
                                    try { innerInput.focus(); } catch(err) {}
                                    innerInput.click();
                                }
                            }
                            reportToTop(window.__nomad_frame_id);
                        } else if (act === 'type') {
                            try { targetEl.focus(); } catch(err) {}
                            targetEl.value = actionObj.text || '';
                            targetEl.dispatchEvent(new Event('input', { bubbles: true }));
                            targetEl.dispatchEvent(new Event('change', { bubbles: true }));
                            if (actionObj.submit) {
                                targetEl.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
                                targetEl.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
                            }
                            reportToTop(window.__nomad_frame_id);
                        } else if (act === 'clear') {
                            try { targetEl.focus(); } catch(err) {}
                            targetEl.value = '';
                            targetEl.dispatchEvent(new Event('input', { bubbles: true }));
                            targetEl.dispatchEvent(new Event('change', { bubbles: true }));
                            reportToTop(window.__nomad_frame_id);
                        }
                        try {
                            e.source.postMessage({
                                type: '__nomad_frame_action_result',
                                actionId: e.data.actionId,
                                result: { success: true, message: 'Executed ' + act + ' on ' + targetId + ' in frame', elementId: targetId }
                            }, '*');
                        } catch(err) {}
                    }
                });

                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', function() { reportToTop(); });
                } else {
                    reportToTop();
                }
                window.addEventListener('load', function() { reportToTop(); });
                window.addEventListener('pageshow', function() { reportToTop(); });
            }
        })();
        """
        ucc.addUserScript(WKUserScript(source: framePiercerScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        return config
    }
}
