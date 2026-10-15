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
    var totalElements: Int?
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
    var className: String?
    var rank: String?
    var isObscured: Bool?
    var inViewport: Bool?
    var disabled: Bool?
    var checked: Bool?
    var selected: Bool?
    var focused: Bool?
    var readOnly: Bool?
    var isInShadowRoot: Bool?
    var src: String?
    var alt: String?
    var href: String?
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
    var target: String? // e.g. "e1", "e2", or CSS selector fallback
    var text: String?
    var key: String? // "Enter", "Escape", "Tab", or chords "Meta+A", "Control+Enter"
    var direction: String? // "up", "down", "left", "right"
    var amount: CGFloat?
    var submit: Bool?
    var x: CGFloat?
    var y: CGFloat?
    var toX: CGFloat?
    var toY: CGFloat?
    var scrollDeltaY: CGFloat?
    var scrollDeltaX: CGFloat?
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
        scrollDeltaY: CGFloat? = nil,
        scrollDeltaX: CGFloat? = nil,
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
        self.scrollDeltaY = scrollDeltaY
        self.scrollDeltaX = scrollDeltaX
        self.optionValue = optionValue
        self.optionText = optionText
        self.modifiers = modifiers
    }

    enum CodingKeys: String, CodingKey {
        case action, type
        case target, elementId, selector
        case text, key, direction, amount, submit
        case x, y, toX, toY
        case scrollDeltaY, deltaY, scrollDeltaX, deltaX
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
        self.submit = try container.decodeIfPresent(Bool.self, forKey: .submit)
        self.x = try container.decodeIfPresent(CGFloat.self, forKey: .x)
        self.y = try container.decodeIfPresent(CGFloat.self, forKey: .y)
        self.toX = try container.decodeIfPresent(CGFloat.self, forKey: .toX)
        self.toY = try container.decodeIfPresent(CGFloat.self, forKey: .toY)

        let dy = try container.decodeIfPresent(CGFloat.self, forKey: .scrollDeltaY)
            ?? container.decodeIfPresent(CGFloat.self, forKey: .deltaY)
        let dx = try container.decodeIfPresent(CGFloat.self, forKey: .scrollDeltaX)
            ?? container.decodeIfPresent(CGFloat.self, forKey: .deltaX)
        self.scrollDeltaY = dy
        self.scrollDeltaX = dx

        if let dyVal = dy {
            self.amount = abs(dyVal)
            self.direction = dyVal >= 0 ? "down" : "up"
        } else if let dxVal = dx {
            self.amount = abs(dxVal)
            self.direction = dxVal >= 0 ? "right" : "left"
        } else {
            self.direction = try container.decodeIfPresent(String.self, forKey: .direction)
            self.amount = try container.decodeIfPresent(CGFloat.self, forKey: .amount)
        }

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
        try container.encodeIfPresent(scrollDeltaY, forKey: .scrollDeltaY)
        try container.encodeIfPresent(scrollDeltaX, forKey: .scrollDeltaX)
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
            getSemanticTree: function(options) {
                options = options || {};
                var limit = options.limit !== undefined ? Number(options.limit) : 100;
                var offset = options.offset !== undefined ? Number(options.offset) : 0;
                var viewportOnly = Boolean(options.viewportOnly);
                var includeText = options.includeText !== undefined ? Boolean(options.includeText) : true;

                this.elements = {};
                var results = [];
                var counter = 1;

                var vpW = window.innerWidth;
                var vpH = window.innerHeight;

                // Recursive collector penetrating open Shadow DOM roots and same-origin / srcdoc iframes
                function collectNodes(root, list) {
                    if (!root) return;
                    var selector = 'a, button, input, textarea, select, details, summary, h1, h2, h3, img, li, p, td, th, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="combobox"], [role="menuitem"], [role="tab"], [role="switch"], [role="option"], [role="heading"], [role="listitem"], [role="status"], [role="alert"], [role="cell"], [tabindex]:not([tabindex="-1"]), [contenteditable="true"], iframe';
                    try {
                        var found = root.querySelectorAll(selector);
                        for (var i = 0; i < found.length; i++) {
                            list.push(found[i]);
                        }
                        var all = root.querySelectorAll('*');
                        for (var j = 0; j < all.length; j++) {
                            if (all[j].shadowRoot) {
                                collectNodes(all[j].shadowRoot, list);
                            } else if (all[j].tagName === 'IFRAME') {
                                try {
                                    var fDoc = all[j].contentDocument || (all[j].contentWindow ? all[j].contentWindow.document : null);
                                    if (fDoc) collectNodes(fDoc, list);
                                } catch(e) {}
                            }
                        }
                    } catch(e) {}
                }

                // Sensitive field detection (passwords, credit cards, CVVs, SSNs, tokens)
                function isSensitiveField(el) {
                    if (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') return false;
                    if (el.type === 'password') return true;
                    var hint = (el.name + ' ' + el.id + ' ' + (el.autocomplete || '') + ' ' + (el.placeholder || '') + ' ' + (el.getAttribute('aria-label') || '')).toLowerCase();
                    var sensitive = ['card', 'cvv', 'cvc', 'ssn', 'social-security', 'secret', 'token', 'passcode', 'credit-card', 'cc-number'];
                    for (var s = 0; s < sensitive.length; s++) {
                        if (hint.indexOf(sensitive[s]) !== -1) return true;
                    }
                    return false;
                }

                // Resolve accessible label using ARIA, label tags, placeholder, title, adjacent labels, and text
                function getAccessibleLabel(el) {
                    try {
                        // Strict redaction of password and sensitive inputs: NEVER return value or prefilled text
                        if (isSensitiveField(el)) {
                            if (el.getAttribute('aria-label')) return el.getAttribute('aria-label').trim();
                            if (el.placeholder) return el.placeholder.trim();
                            if (el.id) {
                                var pwL = document.querySelector('label[for="' + el.id + '"]');
                                if (pwL) return (pwL.innerText || pwL.textContent || '').trim();
                            }
                            return '';
                        }

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
                        // Adjacent label ONLY for form controls (prevents <label> text bleeding onto unrelated links/buttons)
                        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
                            var prev = el.previousElementSibling;
                            var next = el.nextElementSibling;
                            var adjLabel = (prev && prev.tagName === 'LABEL') ? prev : ((next && next.tagName === 'LABEL') ? next : null);
                            if (adjLabel) {
                                var adjText = (adjLabel.innerText || adjLabel.textContent || '').trim();
                                if (adjText) return adjText;
                            }
                        }
                        if (el.placeholder) return el.placeholder.trim();
                        if (el.getAttribute('title')) return el.getAttribute('title').trim();
                        if (el.tagName === 'INPUT' && (el.type === 'submit' || el.type === 'button') && el.value) {
                            return String(el.value).trim();
                        }
                        var fallbackVal = isSensitiveField(el) ? '' : (el.value || '');
                        return (el.innerText || el.textContent || fallbackVal).trim();
                    } catch(e) {
                        return '';
                    }
                }

                // Extracts list ordinal index or rank (search results, table rows, ordered lists)
                function getItemRank(el) {
                    try {
                        var item = el.closest('li, tr, article, [role="listitem"]');
                        if (!item) return null;
                        var r = item.querySelector('.rank, [class*="rank"], [class*="index"]');
                        if (r) {
                            var num = (r.innerText || r.textContent || '').replace(/\\D/g, '');
                            if (num) return num;
                        }
                        if (item.tagName === 'LI' && item.parentElement && item.parentElement.tagName === 'OL') {
                            var idx = Array.prototype.indexOf.call(item.parentElement.children, item);
                            if (idx >= 0) return String(idx + 1);
                        }
                    } catch(e) {}
                    return null;
                }

                var allInteractive = [];
                collectNodes(document, allInteractive);

                for (var i = 0; i < allInteractive.length; i++) {
                    var el = allInteractive[i];
                    var rect = el.getBoundingClientRect();
                    var isInputToggle = (el.tagName === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio'));

                    // Geometry check: elements with zero size are non-rendered
                    if (!isInputToggle && (rect.width <= 0 || rect.height <= 0)) continue;

                    var style = window.getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden') continue;
                    if (parseFloat(style.opacity) < 0.05 && !isInputToggle) continue;
                    if (style.pointerEvents === 'none' && !isInputToggle) continue;

                    var text = getAccessibleLabel(el).replace(/\\s+/g, ' ').substring(0, 80);
                    var tag = el.tagName.toLowerCase();
                    var role = el.getAttribute('role') || tag;
                    var type = el.getAttribute('type') || null;

                    var isSensitive = isSensitiveField(el);
                    var val = null;
                    if (isSensitive) {
                        if (el.value) val = '[REDACTED]';
                    } else if (el.value !== undefined && el.value !== '') {
                        val = String(el.value).substring(0, 50);
                    }

                    var isHeading = (tag === 'h1' || tag === 'h2' || tag === 'h3' || el.getAttribute('role') === 'heading');
                    var isImg = (tag === 'img');
                    var isTextNode = (tag === 'li' || tag === 'p' || tag === 'td' || tag === 'th' || role === 'listitem' || role === 'status' || role === 'alert' || role === 'cell');

                    // Filter out meaningless whitespace links or empty non-interactive anchors
                    if ((tag === 'a' || tag === 'button') && !text && !val && !el.querySelector('img, svg')) {
                        continue;
                    }
                    if (isHeading && !text) {
                        continue;
                    }
                    if (isTextNode) {
                        if (!includeText || (!text && !val)) continue;
                        // Skip parent container if an interactive child already has identical text
                        var childControl = el.querySelector('a, button, input, textarea, select');
                        if (childControl) {
                            var cTxt = (childControl.innerText || childControl.textContent || '').trim();
                            var pTxt = (el.innerText || el.textContent || '').trim();
                            if (cTxt && pTxt === cTxt) continue;
                        }
                    }
                    var src = isImg ? (el.currentSrc || el.src || el.getAttribute('src') || null) : null;
                    var alt = isImg ? (el.alt || el.getAttribute('alt') || null) : null;
                    if (isImg && !src && !alt) {
                        continue;
                    }
                    if (isImg && !text && alt) {
                        text = alt.substring(0, 80);
                    }

                    // Assign persistent, deterministic id in document order
                    var id = 'e' + counter++;
                    this.elements[id] = el;
                    try { el.setAttribute('data-nomad-id', id); } catch(e) {}

                    // In-viewport check (top/bottom/left/right relative to viewport)
                    var inViewport = (rect.bottom >= 0 && rect.top <= vpH && rect.right >= 0 && rect.left <= vpW);

                    // Occlusion Hit-Testing (Center Point Check)
                    var isObscured = false;
                    var cx = Math.round(rect.left + rect.width / 2);
                    var cy = Math.round(rect.top + rect.height / 2);
                    if (cx >= 0 && cx <= vpW && cy >= 0 && cy <= vpH && !isInputToggle) {
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

                    var cls = (el.className && typeof el.className === 'string') ? el.className.trim().split(/\\s+/).slice(0, 2).join('.') : null;
                    var itemRank = getItemRank(el);

                    var disabled = Boolean(el.disabled || el.getAttribute('aria-disabled') === 'true');
                    var checked = Boolean(el.checked || el.getAttribute('aria-checked') === 'true');
                    var selected = Boolean(el.selected || el.getAttribute('aria-selected') === 'true');
                    var focused = Boolean(document.activeElement === el);
                    var readOnly = Boolean(el.readOnly || el.getAttribute('aria-readonly') === 'true');
                    var inShadow = Boolean(el.getRootNode && el.getRootNode() instanceof ShadowRoot);
                    var href = (tag === 'a' || tag === 'area') ? (el.getAttribute('href') || el.href || null) : null;

                    results.push({
                        id: id,
                        tag: tag,
                        role: role,
                        text: text,
                        value: val,
                        type: type,
                        className: cls,
                        rank: itemRank,
                        isObscured: isObscured,
                        inViewport: inViewport,
                        disabled: disabled,
                        checked: checked,
                        selected: selected,
                        focused: focused,
                        readOnly: readOnly,
                        isInShadowRoot: inShadow,
                        src: src,
                        alt: alt,
                        href: href,
                        bounds: {
                            x: Math.round(rect.left),
                            y: Math.round(rect.top),
                            width: Math.round(rect.width),
                            height: Math.round(rect.height)
                        }
                    });
                }

                // Filter elements for summary if viewportOnly is specified
                var summaryCandidates = results;
                if (viewportOnly) {
                    summaryCandidates = results.filter(function(item) { return item.inViewport; });
                }

                var totalCount = summaryCandidates.length;
                var pagedItems = summaryCandidates.slice(offset, offset + limit);

                // Build compact markdown semantic summary for LLM prompt ingestion
                var summaryLines = [
                    '[Page: ' + (document.title || 'Untitled') + ' | URL: ' + window.location.href + ']',
                    'Interactive Elements (' + pagedItems.length + ' of ' + totalCount + (totalCount > limit ? ' | pass limit/offset for more' : '') + '):'
                ];

                for (var j = 0; j < pagedItems.length; j++) {
                    var item = pagedItems[j];
                    var desc = '[' + item.id + ']';
                    if (item.rank) desc += ' #' + item.rank;
                    desc += ' <' + item.tag;
                    if (item.type) desc += ' type="' + item.type + '"';
                    if (item.role && item.role !== item.tag) desc += ' role="' + item.role + '"';
                    if (item.href) {
                        var h = item.href;
                        if (h.length > 50) h = h.substring(0, 47) + '...';
                        desc += ' href="' + h + '"';
                    }
                    if (item.src) {
                        var s = item.src;
                        if (s.length > 40) s = s.substring(0, 37) + '...';
                        desc += ' src="' + s + '"';
                    }
                    if (item.className) {
                        var c = item.className;
                        if (c.length > 25) c = c.substring(0, 22) + '...';
                        desc += ' class="' + c + '"';
                    }
                    if (item.text) desc += ' "' + item.text + '"';
                    if (item.value) desc += ' value="' + item.value + '"';
                    if (item.checked) desc += ' checked';
                    if (item.disabled) desc += ' disabled';
                    if (item.selected) desc += ' selected';
                    if (item.focused) desc += ' focused';
                    if (item.isInShadowRoot) desc += ' shadow';
                    if (!item.inViewport) desc += ' (offscreen)';
                    desc += '>';
                    if (item.isObscured) desc += ' (obscured)';
                    summaryLines.push(desc);
                }

                if (offset + limit < totalCount) {
                    summaryLines.push('[... and ' + (totalCount - (offset + limit)) + ' more elements. Call nomad_snapshot with offset=' + (offset + limit) + ']');
                }

                var fullSummary = summaryLines.join('\\n');
                var tokenEst = Math.round(fullSummary.length / 4);

                return {
                    title: document.title || '',
                    url: window.location.href,
                    viewportWidth: vpW,
                    viewportHeight: vpH,
                    totalElements: results.length,
                    elements: pagedItems,
                    summary: fullSummary,
                    tokenEstimate: tokenEst
                };
            },

            // 2. Dispatches synthetic and realistic user actions
            performAction: function(actionObj) {
                var action = actionObj.action || actionObj.type || '';
                var targetId = actionObj.target || actionObj.elementId || actionObj.selector;
                var el = null;

                if (targetId) {
                    if (this.elements && this.elements[targetId] && document.contains(this.elements[targetId])) {
                        el = this.elements[targetId];
                    } else {
                        try {
                            el = document.querySelector('[data-nomad-id="' + targetId + '"]') || document.querySelector(targetId);
                            if (el && this.elements) this.elements[targetId] = el;
                        } catch(e) {}

                        if (!el && document.activeElement && (document.activeElement.tagName === 'INPUT' || document.activeElement.tagName === 'TEXTAREA')) {
                            el = document.activeElement;
                        }

                        if (!el) {
                            function scanShadow(root) {
                                if (!root) return null;
                                var all = root.querySelectorAll('*');
                                for (var s = 0; s < all.length; s++) {
                                    if (all[s].shadowRoot) {
                                        try {
                                            var found = all[s].shadowRoot.querySelector(targetId) || all[s].shadowRoot.querySelector('[data-nomad-id="' + targetId + '"]');
                                            if (found) return found;
                                        } catch(e) {}
                                        var deeper = scanShadow(all[s].shadowRoot);
                                        if (deeper) return deeper;
                                    }
                                }
                                return null;
                            }
                            try { el = scanShadow(document); } catch(e) {}
                        }
                    }
                }

                if (targetId && !el && action !== 'scroll' && action !== 'press') {
                    return { success: false, message: 'Target element ' + targetId + ' not found or no longer in DOM.', elementId: targetId };
                }

                switch (action) {
                    case 'click':
                        if (el) {
                            el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                            el.focus();

                            // If el is a label, delegate directly to its associated form control
                            if (el.tagName === 'LABEL') {
                                var targetInput = el.htmlFor ? document.getElementById(el.htmlFor) : el.querySelector('input, select, textarea');
                                if (targetInput) el = targetInput;
                            }

                            // Pointer and mouse event simulation sequence
                            var pdown = new PointerEvent('pointerdown', { bubbles: true, cancelable: true, view: window });
                            var mdown = new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window });
                            var pup = new PointerEvent('pointerup', { bubbles: true, cancelable: true, view: window });
                            var mup = new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window });

                            el.dispatchEvent(pdown);
                            el.dispatchEvent(mdown);
                            el.dispatchEvent(pup);
                            el.dispatchEvent(mup);

                            // Native click triggers standard activation behavior (checkboxes, buttons, navigation)
                            try {
                                el.click();
                            } catch(e) {
                                el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
                            }

                            return { success: true, message: 'Clicked ' + (targetId || 'element'), elementId: targetId };
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
                        if (el.isContentEditable) {
                            try {
                                document.execCommand('selectAll', false, null);
                                document.execCommand('delete', false, null);
                            } catch(e) {
                                el.innerText = '';
                            }
                            el.dispatchEvent(new Event('input', { bubbles: true }));
                            return { success: true, message: 'Cleared value in ' + targetId, elementId: targetId };
                        }
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
                        if (el.isContentEditable) {
                            try {
                                document.execCommand('selectAll', false, null);
                                document.execCommand('insertText', false, textToType);
                            } catch(e) {
                                el.innerText = textToType;
                            }
                            el.dispatchEvent(new Event('input', { bubbles: true }));
                            if (actionObj.submit) {
                                var cEnterDown = new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true });
                                var cEnterUp = new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true });
                                el.dispatchEvent(cEnterDown);
                                el.dispatchEvent(cEnterUp);
                            }
                            return { success: true, message: 'Typed into ' + targetId, elementId: targetId };
                        }
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
                            var f = el.form || el.closest('form');
                            if (f) {
                                try {
                                    if (typeof f.requestSubmit === 'function') f.requestSubmit();
                                    else f.submit();
                                } catch(e) {}
                            }
                        }
                        return { success: true, message: 'Typed into ' + targetId, elementId: targetId };

                    case 'drag':
                        if (!el) return { success: false, message: 'No source element for drag action' };
                        el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                        var srcRect = el.getBoundingClientRect();
                        var startX = Math.round(srcRect.left + srcRect.width / 2);
                        var startY = Math.round(srcRect.top + srcRect.height / 2);
                        var destX = actionObj.toX !== undefined ? actionObj.toX : startX;
                        var destY = actionObj.toY !== undefined ? actionObj.toY : startY;

                        var dt = new DataTransfer();
                        el.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, clientX: startX, clientY: startY, dataTransfer: dt }));

                        var destEl = document.elementFromPoint(destX, destY) || el;
                        destEl.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, clientX: destX, clientY: destY, dataTransfer: dt }));
                        destEl.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, clientX: destX, clientY: destY, dataTransfer: dt }));
                        el.dispatchEvent(new DragEvent('dragend', { bubbles: true, cancelable: true, clientX: destX, clientY: destY, dataTransfer: dt }));

                        return { success: true, message: 'Dragged ' + (targetId || 'element') + ' to (' + destX + ', ' + destY + ')' };

                    case 'press':
                        var rawKey = actionObj.key || actionObj.text || 'Enter';
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

                        // If Enter is pressed, trigger form submit if inside a form
                        if (mainKey === 'Enter' || rawKey === 'Enter') {
                            var formNode = (targetNode && targetNode.form) || (targetNode && targetNode.closest ? targetNode.closest('form') : null);
                            if (formNode) {
                                try {
                                    if (typeof formNode.requestSubmit === 'function') {
                                        formNode.requestSubmit();
                                    } else {
                                        formNode.submit();
                                    }
                                } catch(e) {}
                            }
                        }
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
                        var dx = 0;
                        var dy = 0;
                        if (actionObj.scrollDeltaY !== undefined && actionObj.scrollDeltaY !== null) {
                            dy = Number(actionObj.scrollDeltaY) || 0;
                        } else if (actionObj.deltaY !== undefined && actionObj.deltaY !== null) {
                            dy = Number(actionObj.deltaY) || 0;
                        }
                        if (actionObj.scrollDeltaX !== undefined && actionObj.scrollDeltaX !== null) {
                            dx = Number(actionObj.scrollDeltaX) || 0;
                        } else if (actionObj.deltaX !== undefined && actionObj.deltaX !== null) {
                            dx = Number(actionObj.deltaX) || 0;
                        }

                        if (dx === 0 && dy === 0) {
                            var dir = actionObj.direction || 'down';
                            var amt = actionObj.amount !== undefined ? Number(actionObj.amount) : 400;
                            if (dir === 'down') dy = amt;
                            else if (dir === 'up') dy = -amt;
                            else if (dir === 'right') dx = amt;
                            else if (dir === 'left') dx = -amt;
                        }

                        window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
                        var desc = dy !== 0 ? (dy > 0 ? 'down by ' + dy + 'px' : 'up by ' + Math.abs(dy) + 'px') : (dx > 0 ? 'right by ' + dx + 'px' : 'left by ' + Math.abs(dx) + 'px');
                        return { success: true, message: 'Scrolled ' + desc };

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
                container.style.cssText = 'position:fixed;top:0;left:0;width:100vw;height:100vh;pointer-events:none;z-index:2147483647;';
                container.innerHTML = '<style>.__nb{position:fixed;background:#FF5500;color:#fff;font:bold 10px monospace;padding:1px 3px;border-radius:3px;box-shadow:0 1px 3px rgba(0,0,0,0.4);}</style>';

                for (var id in this.elements) {
                    var el = this.elements[id];
                    var rect = el.getBoundingClientRect();
                    if (rect.width <= 0 || rect.height <= 0) continue;

                    var badge = document.createElement('span');
                    badge.className = '__nb';
                    badge.textContent = id;
                    badge.style.left = Math.max(0, rect.left) + 'px';
                    badge.style.top = Math.max(0, rect.top - 12) + 'px';
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
                    var mutationCount = 0;
                    var resolved = false;

                    function done(res) {
                        if (resolved) return;
                        resolved = true;
                        if (maxTimer) clearTimeout(maxTimer);
                        if (timer) clearTimeout(timer);
                        if (observer) {
                            try { observer.disconnect(); } catch(e) {}
                        }
                        resolve(res);
                    }

                    var maxTimer = setTimeout(function() {
                        done({ success: false, reason: 'timeout', message: 'Exceeded max wait of ' + maxWait + 'ms (' + mutationCount + ' mutations)' });
                    }, maxWait);

                    function resetTimer() {
                        if (resolved) return;
                        if (timer) clearTimeout(timer);
                        timer = setTimeout(function() {
                            done({ success: true, message: 'DOM stabilized for ' + quiet + 'ms (' + mutationCount + ' mutations observed)', mutations: mutationCount });
                        }, quiet);
                    }

                    try {
                        observer = new MutationObserver(function(mutations) {
                            mutationCount += (mutations ? mutations.length : 1);
                            resetTimer();
                        });
                        observer.observe(document.documentElement || document.body, {
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
    /// Injects NomadDOMScript only if window.__nomad is not already initialized.
    @MainActor
    func ensureNomadScriptInjected() async {
        let isLoaded = (try? await webView.evaluateJavaScript("Boolean(window.__nomad)")) as? Bool ?? false
        if !isLoaded {
            _ = try? await webView.evaluateJavaScript(NomadDOMScript.core)
        }
    }

    /// Extracts a dense, token-efficient semantic tree and element index from the active page.
    @MainActor
    func getSemanticTree(limit: Int = 100, offset: Int = 0, viewportOnly: Bool = false, includeText: Bool = true) async throws -> NomadSnapshot {
        await ensureNomadScriptInjected()
        let opts: [String: Any] = ["limit": limit, "offset": offset, "viewportOnly": viewportOnly, "includeText": includeText]
        let optsData = (try? JSONSerialization.data(withJSONObject: opts)) ?? Data()
        let optsJSON = String(data: optsData, encoding: .utf8) ?? "{}"
        let jsonString = try await webView.evaluateJavaScript("JSON.stringify(window.__nomad.getSemanticTree(\(optsJSON)))") as? String ?? "{}"
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "NomadAgent", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse snapshot JSON"])
        }
        return try JSONDecoder().decode(NomadSnapshot.self, from: data)
    }

    /// Dispatches a browser action (click, hover, type, clear, scroll, keypress, select, highlight) on the active page.
    @MainActor
    func performAction(_ action: NomadAction) async throws -> NomadActionResult {
        await ensureNomadScriptInjected()
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
        let start = Date()
        let timeoutSeconds = Double(timeoutMs) / 1000.0
        while webView.isLoading && Date().timeIntervalSince(start) < timeoutSeconds {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        let elapsed = Int(Date().timeIntervalSince(start) * 1000.0)
        let remainingTimeout = max(50, timeoutMs - elapsed)
        if remainingTimeout <= 50 && timeoutMs > 50 {
            return ["success": false, "reason": "timeout", "message": "Exceeded max wait of \(timeoutMs)ms (page still loading)"]
        }
        await ensureNomadScriptInjected()
        let script = """
        if (!window.__nomad || !window.__nomad.waitForStability) {
            return { success: true, message: 'DOM ready' };
        }
        return await window.__nomad.waitForStability(quietMs, timeoutMs);
        """
        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.webView.callAsyncJavaScript(script, arguments: ["quietMs": quietMs, "timeoutMs": remainingTimeout], in: nil, in: .page) { result in
                        switch result {
                        case .success(let val):
                            if let dict = val as? [String: Any] {
                                continuation.resume(returning: dict)
                            } else {
                                continuation.resume(returning: ["success": true, "message": "DOM stabilized"])
                            }
                        case .failure(let error):
                            let nsErr = error as NSError
                            if nsErr.domain == "WKErrorDomain" && nsErr.code == 4 { // WKErrorJavaScriptExceptionOccurred during page navigation
                                continuation.resume(returning: ["success": true, "message": "Document navigated"])
                            } else {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(remainingTimeout + 300) * 1_000_000)
                return ["success": false, "reason": "timeout", "message": "Exceeded max wait of \(timeoutMs)ms"]
            }
            let firstResult = try await group.next()!
            group.cancelAll()
            return firstResult
        }
    }

    /// Captures a crisp screenshot directly from WebKit's in-memory compositing buffer (GPU RAM).
    /// If `labeled` is true, temporary visual index badges are overlaid to ground Vision LLMs.
    /// If `elementId` or `clip` is provided, captures only the cropped element/region.
    @MainActor
    func captureScreenshot(labeled: Bool = false, elementId: String? = nil, clip: CGRect? = nil) async throws -> NSImage {
        // Ensure pending layout, paint, and animation frames are flushed so WebKit doesn't snap a blank frame on SPAs/canvas
        _ = try? await webView.evaluateJavaScript("""
        new Promise(function(resolve) {
            if (document.body) { void document.body.offsetHeight; }
            resolve(true);
        })
        """)

        if labeled {
            await ensureNomadScriptInjected()
            _ = try? await webView.evaluateJavaScript("window.__nomad.getSemanticTree(); window.__nomad.showBadges();")
        }

        var targetRect: CGRect? = clip
        if targetRect == nil, let elId = elementId {
            await ensureNomadScriptInjected()
            let rectScript = """
            (function() {
                var el = window.__nomad && window.__nomad.elements && window.__nomad.elements['\(elId)'];
                if (!el) { el = document.querySelector('[data-nomad-id="\(elId)"]'); }
                if (el) {
                    var r = el.getBoundingClientRect();
                    return { x: r.left, y: r.top, width: r.width, height: r.height };
                }
                return null;
            })()
            """
            if let dict = (try? await webView.evaluateJavaScript(rectScript)) as? [String: Any],
               let x = (dict["x"] as? NSNumber)?.doubleValue,
               let y = (dict["y"] as? NSNumber)?.doubleValue,
               let w = (dict["width"] as? NSNumber)?.doubleValue,
               let h = (dict["height"] as? NSNumber)?.doubleValue,
               w > 0 && h > 0 {
                targetRect = CGRect(x: x, y: y, width: w, height: h)
            }
        }

        let config = WKSnapshotConfiguration()
        if let rect = targetRect {
            config.rect = rect
        }

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
