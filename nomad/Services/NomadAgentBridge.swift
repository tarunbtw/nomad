//
//  NomadAgentBridge.swift
//  nomad
//
//  Created by tarun on 12/10/26.
//

import AppKit
import WebKit

// MARK: - Agent Data Models

/// Dense, token-efficient snapshot of interactive elements on a web page.
struct NomadSnapshot: Codable {
    let title: String
    let url: String
    let viewportWidth: CGFloat
    let viewportHeight: CGFloat
    let elements: [NomadElement]
    /// Pre-formatted dense semantic tree for LLM prompt ingestion (~300 tokens).
    let summary: String
    var tokenEstimate: Int?
}

/// A single interactive element discovered on the page.
struct NomadElement: Codable {
    let id: String
    let tag: String
    let role: String?
    let text: String
    let value: String?
    let type: String?
    let bounds: NomadBounds
    var isObscured: Bool?
    var disabled: Bool?
    var checked: Bool?
    var selected: Bool?
    var focused: Bool?
    var readOnly: Bool?
    var isInShadowRoot: Bool?
}

/// Bounding rectangle in viewport coordinates.
struct NomadBounds: Codable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

/// Action request issued by an AI agent or DevX tool.
struct NomadAction: Codable {
    var action: String // "click", "hover", "type", "clear", "press", "selectOption", "scroll", "drag", "highlight"
    var target: String? // e.g. "e1", "e2"
    var text: String?
    var key: String? // "Enter", "Escape", "Tab", or chords "Meta+A", "Control+Enter"
    var direction: String? // "up", "down", "left", "right"
    var amount: CGFloat?
    var submit: Bool?
    var x: CGFloat?
    var y: CGFloat?
    var toX: CGFloat?
    var toY: CGFloat?
    var optionValue: String?
    var optionText: String?
    var modifiers: [String]?

    init(
        action: String,
        target: String? = nil,
        text: String? = nil,
        key: String? = nil,
        direction: String? = nil,
        amount: CGFloat? = nil,
        submit: Bool? = nil,
        x: CGFloat? = nil,
        y: CGFloat? = nil,
        toX: CGFloat? = nil,
        toY: CGFloat? = nil,
        optionValue: String? = nil,
        optionText: String? = nil,
        modifiers: [String]? = nil
    ) {
        self.action = action
        self.target = target
        self.text = text
        self.key = key
        self.direction = direction
        self.amount = amount
        self.submit = submit
        self.x = x
        self.y = y
        self.toX = toX
        self.toY = toY
        self.optionValue = optionValue
        self.optionText = optionText
        self.modifiers = modifiers
    }

    enum CodingKeys: String, CodingKey {
        case action, type
        case target, elementId, selector
        case text, key, direction, amount, submit
        case x, y, toX, toY
        case optionValue, optionText, modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decodeIfPresent(String.self, forKey: .action)
            ?? container.decodeIfPresent(String.self, forKey: .type)
            ?? "click"
        self.target = try container.decodeIfPresent(String.self, forKey: .target)
            ?? container.decodeIfPresent(String.self, forKey: .elementId)
            ?? container.decodeIfPresent(String.self, forKey: .selector)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.key = try container.decodeIfPresent(String.self, forKey: .key)
        self.direction = try container.decodeIfPresent(String.self, forKey: .direction)
        self.amount = try container.decodeIfPresent(CGFloat.self, forKey: .amount)
        self.submit = try container.decodeIfPresent(Bool.self, forKey: .submit)
        self.x = try container.decodeIfPresent(CGFloat.self, forKey: .x)
        self.y = try container.decodeIfPresent(CGFloat.self, forKey: .y)
        self.toX = try container.decodeIfPresent(CGFloat.self, forKey: .toX)
        self.toY = try container.decodeIfPresent(CGFloat.self, forKey: .toY)
        self.optionValue = try container.decodeIfPresent(String.self, forKey: .optionValue)
        self.optionText = try container.decodeIfPresent(String.self, forKey: .optionText)
        self.modifiers = try container.decodeIfPresent([String].self, forKey: .modifiers)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(direction, forKey: .direction)
        try container.encodeIfPresent(amount, forKey: .amount)
        try container.encodeIfPresent(submit, forKey: .submit)
        try container.encodeIfPresent(x, forKey: .x)
        try container.encodeIfPresent(y, forKey: .y)
        try container.encodeIfPresent(toX, forKey: .toX)
        try container.encodeIfPresent(toY, forKey: .toY)
        try container.encodeIfPresent(optionValue, forKey: .optionValue)
        try container.encodeIfPresent(optionText, forKey: .optionText)
        try container.encodeIfPresent(modifiers, forKey: .modifiers)
    }
}

/// Execution outcome of an action.
struct NomadActionResult: Codable {
    let success: Bool
    let message: String
    let elementId: String?
}

// MARK: - In-Page Perception & Action Engine (JavaScript Core)

enum NomadDOMScript {
    /// Injected JavaScript that parses visible interactive elements (including open Shadow DOM and iframes),
    /// performs occlusion hit-testing, formats a dense LLM-friendly semantic summary (~300 tokens),
    /// and executes reliable native-like actions (React 16+ prototype setters, hover, clear, key chords).
    public static let core = """
    (function() {
        if (window.__nomad) return;

        window.__nomad = {
            elements: {},

            // 1. Scans visible interactive targets across Light and Shadow DOM
            getSemanticTree: function() {
                this.elements = {};
                var results = [];
                var counter = 1;

                var vpW = window.innerWidth;
                var vpH = window.innerHeight;

                // Recursive collector penetrating open Shadow DOM roots
                function collectNodes(root, list) {
                    if (!root) return;
                    var selector = 'a, button, input, textarea, select, details, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="combobox"], [role="menuitem"], [role="tab"], [role="switch"], [role="option"], [tabindex]:not([tabindex="-1"]), iframe';
                    try {
                        var found = root.querySelectorAll(selector);
                        for (var i = 0; i < found.length; i++) {
                            list.push(found[i]);
                        }
                        var all = root.querySelectorAll('*');
                        for (var j = 0; j < all.length; j++) {
                            if (all[j].shadowRoot) {
                                collectNodes(all[j].shadowRoot, list);
                            }
                        }
                    } catch(e) {}
                }

                // Resolve accessible label using ARIA, label tags, placeholder, title, and text
                function getAccessibleLabel(el) {
                    try {
                        if (el.getAttribute('aria-label')) {
                            return el.getAttribute('aria-label').trim();
                        }
                        var labelledBy = el.getAttribute('aria-labelledby');
                        if (labelledBy) {
                            var ref = document.getElementById(labelledBy);
                            if (ref) return (ref.innerText || ref.textContent || '').trim();
                        }
                        if (el.id && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT')) {
                            var l = document.querySelector('label[for="' + el.id + '"]');
                            if (l) return (l.innerText || l.textContent || '').trim();
                        }
                        var parentLabel = el.closest('label');
                        if (parentLabel) {
                            var cloned = parentLabel.cloneNode(true);
                            var inputs = cloned.querySelectorAll('input, select, textarea');
                            for (var k = 0; k < inputs.length; k++) inputs[k].remove();
                            var txt = (cloned.innerText || cloned.textContent || '').trim();
                            if (txt) return txt;
                        }
                        if (el.placeholder) return el.placeholder.trim();
                        if (el.getAttribute('title')) return el.getAttribute('title').trim();
                        if (el.tagName === 'INPUT' && (el.type === 'submit' || el.type === 'button') && el.value) {
                            return String(el.value).trim();
                        }
                        return (el.innerText || el.textContent || el.value || '').trim();
                    } catch(e) {
                        return '';
                    }
                }

                var allInteractive = [];
                collectNodes(document, allInteractive);

                for (var i = 0; i < allInteractive.length; i++) {
                    var el = allInteractive[i];
                    var rect = el.getBoundingClientRect();

                    // Visibility checks: geometry and viewport boundary
                    if (rect.width <= 0 || rect.height <= 0) continue;
                    if (rect.bottom < -50 || rect.top > vpH + 50 || rect.right < -50 || rect.left > vpW + 50) continue;

                    var style = window.getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity) < 0.05) continue;
                    if (style.pointerEvents === 'none') continue;

                    var id = 'e' + counter++;
                    this.elements[id] = el;
                    try { el.setAttribute('data-nomad-id', id); } catch(e) {}

                    // Occlusion Hit-Testing (Center Point Check)
                    var isObscured = false;
                    var cx = Math.round(rect.left + rect.width / 2);
                    var cy = Math.round(rect.top + rect.height / 2);
                    if (cx >= 0 && cx <= vpW && cy >= 0 && cy <= vpH) {
                        try {
                            var topEl = document.elementFromPoint(cx, cy);
                            if (topEl && topEl !== el && !el.contains(topEl) && !topEl.contains(el)) {
                                var rootNode = el.getRootNode ? el.getRootNode() : null;
                                var host = (rootNode && rootNode.host) ? rootNode.host : null;
                                if (topEl !== host && (!host || !host.contains(topEl))) {
                                    isObscured = true;
                                }
                            }
                        } catch(e) {}
                    }

                    var text = getAccessibleLabel(el).replace(/\\s+/g, ' ').substring(0, 80);
                    var tag = el.tagName.toLowerCase();
                    var role = el.getAttribute('role') || tag;
                    var type = el.getAttribute('type') || null;
                    var val = (el.value !== undefined && el.value !== '' && el.type !== 'password') ? String(el.value).substring(0, 50) : null;

                    var disabled = Boolean(el.disabled || el.getAttribute('aria-disabled') === 'true');
                    var checked = Boolean(el.checked || el.getAttribute('aria-checked') === 'true');
                    var selected = Boolean(el.selected || el.getAttribute('aria-selected') === 'true');
                    var focused = Boolean(document.activeElement === el);
                    var readOnly = Boolean(el.readOnly || el.getAttribute('aria-readonly') === 'true');
                    var inShadow = Boolean(el.getRootNode && el.getRootNode() instanceof ShadowRoot);

                    results.push({
                        id: id,
                        tag: tag,
                        role: role,
                        text: text,
                        value: val,
                        type: type,
                        isObscured: isObscured,
                        disabled: disabled,
                        checked: checked,
                        selected: selected,
                        focused: focused,
                        readOnly: readOnly,
                        isInShadowRoot: inShadow,
                        bounds: {
                            x: Math.round(rect.left),
                            y: Math.round(rect.top),
                            width: Math.round(rect.width),
                            height: Math.round(rect.height)
                        }
                    });
                }

                // Build compact markdown semantic summary for LLM prompt ingestion (~300 tokens)
                var summaryLines = [
                    '[Page: ' + (document.title || 'Untitled') + ' | URL: ' + window.location.href + ']',
                    'Interactive Elements (' + results.length + '):'
                ];

                for (var j = 0; j < results.length; j++) {
                    var item = results[j];
                    var desc = '[' + item.id + '] <' + item.tag;
                    if (item.type) desc += ' type="' + item.type + '"';
                    if (item.role && item.role !== item.tag) desc += ' role="' + item.role + '"';
                    if (item.text) desc += ' "' + item.text + '"';
                    if (item.value) desc += ' value="' + item.value + '"';
                    if (item.checked) desc += ' checked';
                    if (item.disabled) desc += ' disabled';
                    if (item.selected) desc += ' selected';
                    if (item.focused) desc += ' focused';
                    if (item.isInShadowRoot) desc += ' shadow';
                    desc += '>';
                    if (item.isObscured) desc += ' (obscured)';
                    summaryLines.push(desc);
                }

                var fullSummary = summaryLines.join('\\n');
                var tokenEst = Math.round(fullSummary.length / 4);

                return {
                    title: document.title || '',
                    url: window.location.href,
                    viewportWidth: vpW,
                    viewportHeight: vpH,
                    elements: results,
                    summary: fullSummary,
                    tokenEstimate: tokenEst
                };
            },

            // 2. Dispatches synthetic and realistic user actions
            performAction: function(actionObj) {
                var action = actionObj.action || '';
                var targetId = actionObj.target;
                var el = targetId ? (this.elements[targetId] || document.querySelector('[data-nomad-id="' + targetId + '"]')) : null;

                if (targetId && !el) {
                    return { success: false, message: 'Target element ' + targetId + ' not found or no longer in DOM.', elementId: targetId };
                }

                switch (action) {
                    case 'click':
                        if (el) {
                            el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                            el.focus();
                            var pdown = new PointerEvent('pointerdown', { bubbles: true, cancelable: true, view: window });
                            var mdown = new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window });
                            var pup = new PointerEvent('pointerup', { bubbles: true, cancelable: true, view: window });
                            var mup = new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window });
                            var clk = new MouseEvent('click', { bubbles: true, cancelable: true, view: window });

                            el.dispatchEvent(pdown);
                            el.dispatchEvent(mdown);
                            el.dispatchEvent(pup);
                            el.dispatchEvent(mup);
                            el.dispatchEvent(clk);

                            if (el.tagName === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio')) {
                                el.dispatchEvent(new Event('change', { bubbles: true }));
                            }

                            if (el.tagName === 'A' && el.href && !el.href.startsWith('javascript:')) {
                                window.location.href = el.href;
                            }
                            return { success: true, message: 'Clicked ' + targetId, elementId: targetId };
                        } else if (actionObj.x !== undefined && actionObj.y !== undefined) {
                            var hit = document.elementFromPoint(actionObj.x, actionObj.y);
                            if (hit) {
                                hit.click();
                                return { success: true, message: 'Clicked coordinates (' + actionObj.x + ', ' + actionObj.y + ')' };
                            }
                            return { success: false, message: 'No element at coordinates (' + actionObj.x + ', ' + actionObj.y + ')' };
                        }
                        return { success: false, message: 'No target specified for click' };

                    case 'hover':
                        if (!el) return { success: false, message: 'No target element for hover action' };
                        el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                        el.dispatchEvent(new PointerEvent('pointerover', { bubbles: true, cancelable: true, view: window }));
                        el.dispatchEvent(new PointerEvent('pointerenter', { bubbles: false, cancelable: false, view: window }));
                        el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window }));
                        el.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, cancelable: true, view: window }));
                        return { success: true, message: 'Hovered over ' + targetId, elementId: targetId };

                    case 'clear':
                        if (!el) return { success: false, message: 'No target element for clear action' };
                        el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                        el.focus();
                        try {
                            var proto = el instanceof HTMLTextAreaElement ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
                            var setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
                            if (setter) { setter.call(el, ''); } else { el.value = ''; }
                        } catch(e) {
                            el.value = '';
                        }
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                        return { success: true, message: 'Cleared value in ' + targetId, elementId: targetId };

                    case 'type':
                        if (!el) return { success: false, message: 'No target element for type action' };
                        el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                        el.focus();
                        var textToType = actionObj.text || '';
                        try {
                            // React 16+ controlled component compatibility
                            var protoType = el instanceof HTMLTextAreaElement ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
                            var setterType = Object.getOwnPropertyDescriptor(protoType, 'value')?.set;
                            if (setterType) { setterType.call(el, textToType); } else { el.value = textToType; }
                        } catch(e) {
                            el.value = textToType;
                        }
                        el.dispatchEvent(new Event('input', { bubbles: true }));
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                        if (actionObj.submit) {
                            var enterDown = new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true });
                            var enterUp = new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true });
                            el.dispatchEvent(enterDown);
                            el.dispatchEvent(enterUp);
                            if (el.form) el.form.submit();
                        }
                        return { success: true, message: 'Typed into ' + targetId, elementId: targetId };

                    case 'press':
                        var rawKey = actionObj.key || 'Enter';
                        var targetNode = el || document.activeElement || document.body;

                        // Parse modifiers from chords like "Meta+A", "Control+Enter", "Shift+Tab"
                        var parts = rawKey.split('+');
                        var mainKey = parts[parts.length - 1];
                        var hasMeta = parts.includes('Meta') || parts.includes('Cmd') || parts.includes('Command');
                        var hasCtrl = parts.includes('Control') || parts.includes('Ctrl');
                        var hasShift = parts.includes('Shift');
                        var hasAlt = parts.includes('Alt') || parts.includes('Option');

                        var kopts = {
                            key: mainKey,
                            code: mainKey,
                            bubbles: true,
                            cancelable: true,
                            metaKey: hasMeta,
                            ctrlKey: hasCtrl,
                            shiftKey: hasShift,
                            altKey: hasAlt
                        };

                        var kdown = new KeyboardEvent('keydown', kopts);
                        var kup = new KeyboardEvent('keyup', kopts);
                        targetNode.dispatchEvent(kdown);
                        targetNode.dispatchEvent(kup);
                        return { success: true, message: 'Pressed key ' + rawKey };

                    case 'selectOption':
                        if (!el || el.tagName !== 'SELECT') {
                            return { success: false, message: 'Target ' + targetId + ' is not a <select> element' };
                        }
                        var desiredVal = actionObj.optionValue;
                        var desiredTxt = actionObj.optionText;
                        var matched = false;
                        for (var s = 0; s < el.options.length; s++) {
                            var opt = el.options[s];
                            if ((desiredVal && opt.value === desiredVal) || (desiredTxt && opt.text.trim() === desiredTxt.trim())) {
                                el.selectedIndex = s;
                                opt.selected = true;
                                matched = true;
                                break;
                            }
                        }
                        if (matched) {
                            el.dispatchEvent(new Event('input', { bubbles: true }));
                            el.dispatchEvent(new Event('change', { bubbles: true }));
                            return { success: true, message: 'Selected option in ' + targetId, elementId: targetId };
                        }
                        return { success: false, message: 'Option not found in ' + targetId };

                    case 'scroll':
                        var dir = actionObj.direction || 'down';
                        var amt = actionObj.amount || 400;
                        var dx = 0, dy = 0;
                        if (dir === 'down') dy = amt;
                        else if (dir === 'up') dy = -amt;
                        else if (dir === 'right') dx = amt;
                        else if (dir === 'left') dx = -amt;
                        window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
                        return { success: true, message: 'Scrolled ' + dir + ' by ' + amt + 'px' };

                    case 'highlight':
                        if (!el) return { success: false, message: 'No target element to highlight' };
                        this.showHighlight(el);
                        return { success: true, message: 'Highlighted ' + targetId, elementId: targetId };

                    default:
                        return { success: false, message: 'Unknown action: ' + action };
                }
            },

            // 3. Visual Element Highlighter for DevX & Inspection
            showHighlight: function(el) {
                var prev = document.getElementById('__nomad_highlight');
                if (prev) prev.remove();

                var rect = el.getBoundingClientRect();
                var div = document.createElement('div');
                div.id = '__nomad_highlight';
                div.style.position = 'fixed';
                div.style.left = (rect.left - 2) + 'px';
                div.style.top = (rect.top - 2) + 'px';
                div.style.width = (rect.width + 4) + 'px';
                div.style.height = (rect.height + 4) + 'px';
                div.style.border = '2px solid #FF5500';
                div.style.borderRadius = '4px';
                div.style.backgroundColor = 'rgba(255, 85, 0, 0.12)';
                div.style.pointerEvents = 'none';
                div.style.zIndex = '2147483646';
                div.style.transition = 'all 0.15s ease-out';
                document.body.appendChild(div);

                setTimeout(function() {
                    if (div.parentNode) div.remove();
                }, 3000);
            },

            // 4. Overlays indexed visual badges [e1], [e2] for Vision Model Screenshots
            showBadges: function() {
                this.hideBadges();
                var container = document.createElement('div');
                container.id = '__nomad_badges_layer';
                container.style.position = 'fixed';
                container.style.top = '0';
                container.style.left = '0';
                container.style.width = '100vw';
                container.style.height = '100vh';
                container.style.pointerEvents = 'none';
                container.style.zIndex = '2147483647';

                for (var id in this.elements) {
                    var el = this.elements[id];
                    var rect = el.getBoundingClientRect();
                    if (rect.width <= 0 || rect.height <= 0) continue;

                    var badge = document.createElement('span');
                    badge.textContent = id;
                    badge.style.position = 'fixed';
                    badge.style.left = Math.max(0, rect.left) + 'px';
                    badge.style.top = Math.max(0, rect.top - 12) + 'px';
                    badge.style.background = '#FF5500';
                    badge.style.color = '#FFFFFF';
                    badge.style.fontSize = '10px';
                    badge.style.fontWeight = 'bold';
                    badge.style.fontFamily = 'monospace';
                    badge.style.padding = '1px 3px';
                    badge.style.borderRadius = '3px';
                    badge.style.boxShadow = '0 1px 3px rgba(0,0,0,0.4)';
                    container.appendChild(badge);
                }
                document.body.appendChild(container);
            },

            hideBadges: function() {
                var layer = document.getElementById('__nomad_badges_layer');
                if (layer) layer.remove();
            },

            // 5. Waits for DOM mutation quiescence (stability)
            waitForStability: function(quietMs, timeoutMs) {
                return new Promise(function(resolve) {
                    var quiet = quietMs || 250;
                    var maxWait = timeoutMs || 5000;
                    var timer = null;
                    var observer = null;

                    var maxTimer = setTimeout(function() {
                        cleanup();
                        resolve({ success: false, reason: 'timeout', message: 'Exceeded max wait of ' + maxWait + 'ms' });
                    }, maxWait);

                    function resetTimer() {
                        if (timer) clearTimeout(timer);
                        timer = setTimeout(function() {
                            cleanup();
                            resolve({ success: true, message: 'DOM stabilized for ' + quiet + 'ms' });
                        }, quiet);
                    }

                    function cleanup() {
                        if (maxTimer) clearTimeout(maxTimer);
                        if (timer) clearTimeout(timer);
                        if (observer) observer.disconnect();
                    }

                    try {
                        observer = new MutationObserver(function() {
                            resetTimer();
                        });
                        observer.observe(document.body || document.documentElement, {
                            childList: true,
                            subtree: true,
                            attributes: true,
                            characterData: true
                        });
                    } catch(e) {}

                    resetTimer();
                });
            }
        };
    })();
    """
}

// MARK: - Native Tab Agent Extensions

extension Tab {
    /// Extracts a dense, token-efficient semantic tree and element index from the active page.
    @MainActor
    func getSemanticTree() async throws -> NomadSnapshot {
        // Ensure core script is injected
        _ = try await webView.evaluateJavaScript(NomadDOMScript.core)
        let jsonString = try await webView.evaluateJavaScript("JSON.stringify(window.__nomad.getSemanticTree())") as? String ?? "{}"
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "NomadAgent", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse snapshot JSON"])
        }
        return try JSONDecoder().decode(NomadSnapshot.self, from: data)
    }

    /// Dispatches a browser action (click, hover, type, clear, scroll, keypress, select, highlight) on the active page.
    @MainActor
    func performAction(_ action: NomadAction) async throws -> NomadActionResult {
        _ = try await webView.evaluateJavaScript(NomadDOMScript.core)
        let actionData = try JSONEncoder().encode(action)
        guard let actionJSON = String(data: actionData, encoding: .utf8) else {
            throw NSError(domain: "NomadAgent", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode action JSON"])
        }
        let resultString = try await webView.evaluateJavaScript("JSON.stringify(window.__nomad.performAction(\(actionJSON)))") as? String ?? "{}"
        guard let resultData = resultString.data(using: .utf8) else {
            throw NSError(domain: "NomadAgent", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse action result JSON"])
        }
        return try JSONDecoder().decode(NomadActionResult.self, from: resultData)
    }

    /// Waits for DOM mutation quiescence (stability) on the active page.
    @MainActor
    func waitForStability(quietMs: Int = 250, timeoutMs: Int = 5000) async throws -> [String: Any] {
        _ = try await webView.evaluateJavaScript(NomadDOMScript.core)
        let script = "return await window.__nomad.waitForStability(quietMs, timeoutMs);"
        return try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: ["quietMs": quietMs, "timeoutMs": timeoutMs], in: nil, in: .page) { result in
                switch result {
                case .success(let val):
                    if let dict = val as? [String: Any] {
                        continuation.resume(returning: dict)
                    } else {
                        continuation.resume(returning: ["success": true, "message": "DOM stabilized"])
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Captures a crisp screenshot directly from WebKit's in-memory compositing buffer (GPU RAM).
    /// If `labeled` is true, temporary visual index badges are overlaid to ground Vision LLMs.
    @MainActor
    func captureScreenshot(labeled: Bool = false) async throws -> NSImage {
        if labeled {
            _ = try? await webView.evaluateJavaScript(NomadDOMScript.core)
            _ = try? await webView.evaluateJavaScript("window.__nomad.getSemanticTree(); window.__nomad.showBadges();")
        }

        let config = WKSnapshotConfiguration()
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            self.webView.takeSnapshot(with: config) { img, err in
                if let err = err {
                    continuation.resume(throwing: err)
                } else if let img = img {
                    continuation.resume(returning: img)
                } else {
                    continuation.resume(throwing: NSError(domain: "NomadAgent", code: -4, userInfo: [NSLocalizedDescriptionKey: "Snapshot returned nil"]))
                }
            }
        }

        if labeled {
            _ = try? await webView.evaluateJavaScript("window.__nomad.hideBadges();")
        }

        return image
    }
}

// MARK: - NSImage Image Helper

extension NSImage {
    /// Encodes NSImage to standard PNG data.
    var pngData: Data? {
        guard let tiffRepresentation = tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        return bitmapImage.representation(using: .png, properties: [:])
    }
}
