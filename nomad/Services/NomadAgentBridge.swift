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
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Action request issued by an AI agent or DevX tool.
struct NomadAction: Codable {
    var action: String = "click" // "click", "hover", "type", "clear", "press", "selectOption", "scroll", "drag", "highlight", "upload"
    var target: String? // e.g. "e1", "e2", or CSS selector fallback
    var text: String?
    var key: String? // "Enter", "Escape", "Tab", or chords "Meta+A", "Control+Enter"
    var direction: String? // "up", "down", "left", "right"
    var amount: CGFloat?
    var submit: Bool?
    var blur: Bool?
    var change: Bool?
    var force: Bool?
    var x: CGFloat?
    var y: CGFloat?
    var toX: CGFloat?
    var toY: CGFloat?
    var scrollDeltaY: CGFloat?
    var scrollDeltaX: CGFloat?
    var optionValue: String?
    var optionText: String?
    var modifiers: [String]?
    var paths: [String]?
    var files: [String]?

    var resolvedPaths: [String] {
        if let paths = paths, !paths.isEmpty { return paths }
        if let files = files, !files.isEmpty { return files }
        return []
    }

    init(action: String = "click", target: String? = nil, text: String? = nil, key: String? = nil, direction: String? = nil, amount: CGFloat? = nil, submit: Bool? = nil, blur: Bool? = nil, change: Bool? = nil, force: Bool? = nil, x: CGFloat? = nil, y: CGFloat? = nil, toX: CGFloat? = nil, toY: CGFloat? = nil, scrollDeltaY: CGFloat? = nil, scrollDeltaX: CGFloat? = nil, optionValue: String? = nil, optionText: String? = nil, modifiers: [String]? = nil, paths: [String]? = nil, files: [String]? = nil) {
        self.action = action
        self.target = target
        self.text = text
        self.key = key
        self.direction = direction
        self.amount = amount
        self.submit = submit
        self.blur = blur
        self.change = change
        self.force = force
        self.x = x
        self.y = y
        self.toX = toX
        self.toY = toY
        self.scrollDeltaY = scrollDeltaY
        self.scrollDeltaX = scrollDeltaX
        self.optionValue = optionValue
        self.optionText = optionText
        self.modifiers = modifiers
        self.paths = paths
        self.files = files ?? paths
    }

    enum CodingKeys: String, CodingKey {
        case action, type, target, elementId, selector, text, key, direction, amount
        case submit, blur, change, force, x, y, toX, toY
        case scrollDeltaY, deltaY, scrollDeltaX, deltaX, optionValue, optionText, modifiers
        case paths, path, files, file
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let rawAction = (try c.decodeIfPresent(String.self, forKey: .action) ?? c.decodeIfPresent(String.self, forKey: .type))?.trimmingCharacters(in: .whitespacesAndNewlines), !rawAction.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing required 'type' or 'action' field in action object"))
        }
        let validActions: Set<String> = ["click", "hover", "type", "clear", "press", "selectoption", "scroll", "drag", "highlight", "upload"]
        guard validActions.contains(rawAction.lowercased()) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown action type '\(rawAction)'"))
        }
        self.action = rawAction
        self.target = try c.decodeIfPresent(String.self, forKey: .target) ?? c.decodeIfPresent(String.self, forKey: .elementId) ?? c.decodeIfPresent(String.self, forKey: .selector)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.key = try c.decodeIfPresent(String.self, forKey: .key)
        self.submit = try c.decodeIfPresent(Bool.self, forKey: .submit)
        self.blur = try c.decodeIfPresent(Bool.self, forKey: .blur)
        self.change = try c.decodeIfPresent(Bool.self, forKey: .change)
        self.force = try c.decodeIfPresent(Bool.self, forKey: .force)
        self.x = try c.decodeIfPresent(CGFloat.self, forKey: .x)
        self.y = try c.decodeIfPresent(CGFloat.self, forKey: .y)
        self.toX = try c.decodeIfPresent(CGFloat.self, forKey: .toX)
        self.toY = try c.decodeIfPresent(CGFloat.self, forKey: .toY)
        let dy = try c.decodeIfPresent(CGFloat.self, forKey: .scrollDeltaY) ?? c.decodeIfPresent(CGFloat.self, forKey: .deltaY)
        let dx = try c.decodeIfPresent(CGFloat.self, forKey: .scrollDeltaX) ?? c.decodeIfPresent(CGFloat.self, forKey: .deltaX)
        self.scrollDeltaY = dy
        self.scrollDeltaX = dx
        self.amount = dy != nil ? abs(dy!) : (dx != nil ? abs(dx!) : try c.decodeIfPresent(CGFloat.self, forKey: .amount))
        self.direction = dy != nil ? (dy! >= 0 ? "down" : "up") : (dx != nil ? (dx! >= 0 ? "right" : "left") : try c.decodeIfPresent(String.self, forKey: .direction))
        self.optionValue = try c.decodeIfPresent(String.self, forKey: .optionValue)
        self.optionText = try c.decodeIfPresent(String.self, forKey: .optionText)
        self.modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers)

        var collectedPaths: [String] = []
        if let arr = try? c.decodeIfPresent([String].self, forKey: .paths) {
            collectedPaths.append(contentsOf: arr)
        } else if let single = try? c.decodeIfPresent(String.self, forKey: .paths) {
            collectedPaths.append(single)
        }
        if let arr = try? c.decodeIfPresent([String].self, forKey: .files) {
            collectedPaths.append(contentsOf: arr)
        } else if let single = try? c.decodeIfPresent(String.self, forKey: .files) {
            collectedPaths.append(single)
        }
        if let single = try? c.decodeIfPresent(String.self, forKey: .path) {
            collectedPaths.append(single)
        }
        if let single = try? c.decodeIfPresent(String.self, forKey: .file) {
            collectedPaths.append(single)
        }
        let unique = Array(NSOrderedSet(array: collectedPaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })) as? [String] ?? []
        self.paths = unique.isEmpty ? nil : unique
        self.files = self.paths
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(target, forKey: .target)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encodeIfPresent(direction, forKey: .direction)
        try c.encodeIfPresent(amount, forKey: .amount)
        try c.encodeIfPresent(submit, forKey: .submit)
        try c.encodeIfPresent(blur, forKey: .blur)
        try c.encodeIfPresent(change, forKey: .change)
        try c.encodeIfPresent(force, forKey: .force)
        try c.encodeIfPresent(x, forKey: .x)
        try c.encodeIfPresent(y, forKey: .y)
        try c.encodeIfPresent(toX, forKey: .toX)
        try c.encodeIfPresent(toY, forKey: .toY)
        try c.encodeIfPresent(scrollDeltaY, forKey: .scrollDeltaY)
        try c.encodeIfPresent(scrollDeltaX, forKey: .scrollDeltaX)
        try c.encodeIfPresent(optionValue, forKey: .optionValue)
        try c.encodeIfPresent(optionText, forKey: .optionText)
        try c.encodeIfPresent(modifiers, forKey: .modifiers)
        try c.encodeIfPresent(paths, forKey: .paths)
        try c.encodeIfPresent(files, forKey: .files)
    }
}


/// Execution outcome of an action.
struct NomadActionResult: Codable {
    let success: Bool
    var message: String
    var elementId: String? = nil
    var obscured: Bool? = nil
    var interceptedBy: String? = nil
    var healed: Bool? = nil
    var staleRef: Bool? = nil
    var code: String? = nil
    var stack: String? = nil
    var error: String? = nil
    var files: [String]? = nil
    var count: Int? = nil

    init(success: Bool, message: String, elementId: String? = nil, obscured: Bool? = nil, interceptedBy: String? = nil, healed: Bool? = nil, staleRef: Bool? = nil, code: String? = nil, stack: String? = nil, error: String? = nil, files: [String]? = nil, count: Int? = nil) {
        self.success = success
        self.message = message
        self.elementId = elementId
        self.obscured = obscured
        self.interceptedBy = interceptedBy
        self.healed = healed
        self.staleRef = staleRef
        self.code = code
        self.stack = stack
        self.error = error
        self.files = files
        self.count = count
    }
}

// MARK: - In-Page Perception & Action Engine (JavaScript Core)

enum NomadDOMScript {
    /// Injected JavaScript that parses visible interactive elements (including open Shadow DOM and iframes),
    /// performs occlusion hit-testing, formats a dense LLM-friendly semantic summary (~300 tokens),
    /// and executes reliable native-like actions (React 16+ prototype setters, hover, clear, key chords).
    public static let core = """
    (function() {
        if (window.__nomad) return;

        // Validates whether an element is truly editable for typing or clearing
        function isTextEditable(node) {
            if (!node) return false;
            if (node.isContentEditable) return true;
            var t = node.tagName ? node.tagName.toLowerCase() : '';
            if (t === 'textarea') return !node.readOnly && !node.disabled;
            if (t === 'input') {
                var it = (node.type || 'text').toLowerCase();
                var nonTextTypes = ['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'range', 'color', 'hidden'];
                if (nonTextTypes.indexOf(it) !== -1) return false;
                return !node.readOnly && !node.disabled;
            }
            return false;
        }

        window.__nomad = {
            elements: {},
            isTextEditable: isTextEditable,

            // Viewport-relative bounding rect accounting for parent frame offsets
            getElementViewportRect: function(element) {
                if (!element) return { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
                var r = element.getBoundingClientRect();
                var curWin = (element.ownerDocument && element.ownerDocument.defaultView) ? element.ownerDocument.defaultView : window;
                var x = r.left;
                var y = r.top;
                try {
                    while (curWin && curWin !== window && curWin.frameElement) {
                        var fr = curWin.frameElement.getBoundingClientRect();
                        x += fr.left;
                        y += fr.top;
                        curWin = curWin.parent;
                    }
                } catch(e) {}
                return {
                    left: x,
                    top: y,
                    right: x + r.width,
                    bottom: y + r.height,
                    width: r.width,
                    height: r.height
                };
            },

            // Checks whether an element is connected to the live DOM tree, even inside nested frames
            isNodeConnected: function(node) {
                if (!node) return false;
                if (typeof node.isConnected === 'boolean') {
                    if (!node.isConnected) return false;
                    var doc = node.ownerDocument;
                    if (doc && doc !== document && doc.defaultView && doc.defaultView.frameElement) {
                        return this.isNodeConnected(doc.defaultView.frameElement);
                    }
                    return true;
                }
                var root = node.getRootNode ? node.getRootNode() : null;
                return root === document;
            },

            // Searches for an element by ID/selector across document, open Shadow DOM, and nested iframes
            findInTree: function(root, sel) {
                if (!root) return null;
                try {
                    var found = root.querySelector('[data-nomad-id="' + sel + '"]') || root.querySelector(sel);
                    if (found) return found;
                } catch(e) {}
                try {
                    var all = root.querySelectorAll('*');
                    for (var i = 0; i < all.length; i++) {
                        var n = all[i];
                        if (n.shadowRoot) {
                            var sFound = this.findInTree(n.shadowRoot, sel);
                            if (sFound) return sFound;
                        } else if (n.tagName === 'IFRAME') {
                            try {
                                var fDoc = n.contentDocument || (n.contentWindow ? n.contentWindow.document : null);
                                if (fDoc) {
                                    var iFound = this.findInTree(fDoc, sel);
                                    if (iFound) return iFound;
                                }
                            } catch(err) {}
                        }
                    }
                } catch(e) {}
                return null;
            },

            // 1. Scans visible interactive targets across Light and Shadow DOM and iframes
            getSemanticTree: function(options) {
                options = options || {};
                var limit = options.limit !== undefined ? Number(options.limit) : 100;
                var offset = options.offset !== undefined ? Number(options.offset) : 0;
                var viewportOnly = Boolean(options.viewportOnly);
                var includeText = options.includeText !== undefined ? Boolean(options.includeText) : true;

                if (!this.elements) this.elements = {};
                if (!this.elementSignatures) this.elementSignatures = {};
                for (var oldId in this.elements) {
                    if (!this.isNodeConnected(this.elements[oldId])) {
                        delete this.elements[oldId];
                    }
                }
                var results = [];
                var counter = 1;

                if (document.body) { void document.body.offsetHeight; }
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

                // Pre-scan existing elements to preserve identity across DOM mutations
                var assignedIds = {};
                var maxIdNum = 0;
                for (var oldK in this.elements) {
                    var nOld = parseInt(oldK.substring(1), 10);
                    if (!isNaN(nOld) && nOld > maxIdNum) maxIdNum = nOld;
                    assignedIds[oldK] = this.elements[oldK];
                }
                for (var k = 0; k < allInteractive.length; k++) {
                    var exId = allInteractive[k].getAttribute('data-nomad-id');
                    if (exId && exId.indexOf('e') === 0) {
                        var n = parseInt(exId.substring(1), 10);
                        if (!isNaN(n) && n > 0 && !assignedIds[exId]) {
                            assignedIds[exId] = allInteractive[k];
                            if (n > maxIdNum) maxIdNum = n;
                        }
                    }
                }
                var nextCounter = maxIdNum + 1;

                for (var i = 0; i < allInteractive.length; i++) {
                    var el = allInteractive[i];
                    var rect = this.getElementViewportRect(el);
                    var isInputToggle = (el.tagName === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio'));

                    // Geometry check: elements with zero size are non-rendered
                    if (!isInputToggle && (rect.width <= 0 || rect.height <= 0)) continue;

                    var elWin = (el.ownerDocument && el.ownerDocument.defaultView) || window;
                    var style = elWin.getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden') continue;
                    if (parseFloat(style.opacity) < 0.05 && !isInputToggle) continue;
                    if (style.pointerEvents === 'none' && !isInputToggle) continue;

                    var text = getAccessibleLabel(el).replace(/\\s+/g, ' ').substring(0, 80);
                    var tag = el.tagName.toLowerCase();
                    var role = el.getAttribute('role') || tag;
                    var type = el.getAttribute('type') || null;

                    var isSensitive = isSensitiveField(el);
                    var val = null;
                    var hasFormValue = (tag === 'input' || tag === 'textarea' || tag === 'select' || tag === 'option' || (tag === 'button' && el.type === 'submit'));
                    if (hasFormValue) {
                        if (isSensitive) {
                            if (el.value) val = '[REDACTED]';
                        } else if (el.value !== undefined && el.value !== '') {
                            val = String(el.value).substring(0, 50);
                        }
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

                    // Assign persistent, identity-stable id
                    var id = el.getAttribute('data-nomad-id');
                    if (!id || assignedIds[id] !== el) {
                        id = 'e' + (nextCounter++);
                        assignedIds[id] = el;
                        try { el.setAttribute('data-nomad-id', id); } catch(e) {}
                    }
                    this.elements[id] = el;
                    this.elementSignatures[id] = {
                        tag: tag,
                        id: el.id || null,
                        name: el.getAttribute('name') || null,
                        type: type,
                        role: role,
                        className: (el.className && typeof el.className === 'string') ? el.className.trim() : null,
                        text: text,
                        value: val,
                        placeholder: el.placeholder || null,
                        ariaLabel: el.getAttribute('aria-label') || null,
                        testId: el.getAttribute('data-testid') || null,
                        ordinal: i
                    };

                    // In-viewport check (top/bottom/left/right relative to viewport)
                    var inViewport = (rect.bottom >= 0 && rect.top <= vpH && rect.right >= 0 && rect.left <= vpW);

                    // Occlusion Hit-Testing (Center Point Check)
                    var isObscured = false;
                    var cx = Math.round(rect.left + rect.width / 2);
                    var cy = Math.round(rect.top + rect.height / 2);
                    if (cx >= 0 && cx <= vpW && cy >= 0 && cy <= vpH && !isInputToggle) {
                        try {
                            var topEl = document.elementFromPoint(cx, cy);
                            var curFrame = (el.ownerDocument && el.ownerDocument.defaultView) ? el.ownerDocument.defaultView.frameElement : null;
                            if (curFrame && topEl === curFrame) {
                                var localRect = el.getBoundingClientRect();
                                var lcx = Math.round(localRect.left + localRect.width / 2);
                                var lcy = Math.round(localRect.top + localRect.height / 2);
                                var innerTop = el.ownerDocument.elementFromPoint(lcx, lcy);
                                if (innerTop && innerTop !== el && !el.contains(innerTop) && !innerTop.contains(el)) {
                                    isObscured = true;
                                }
                            } else if (topEl && topEl !== el && !el.contains(topEl) && !topEl.contains(el)) {
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
                    var inShadow = Boolean(el.getRootNode && el.getRootNode().host);
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

                var pageUrl = window.location.href || '';
                var displayUrl = pageUrl;
                if (displayUrl.indexOf('data:') === 0) {
                    var comma = displayUrl.indexOf(',');
                    var mime = comma > 0 ? displayUrl.substring(0, comma) : 'data:text/html';
                    displayUrl = mime + ';length=' + pageUrl.length;
                } else if (displayUrl.length > 200) {
                    displayUrl = displayUrl.substring(0, 197) + '...';
                }

                // Build compact markdown semantic summary for LLM prompt ingestion
                var summaryLines = [
                    '[Page: ' + (document.title || 'Untitled') + ' | URL: ' + displayUrl + ']',
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
                    url: displayUrl,
                    viewportWidth: vpW,
                    viewportHeight: vpH,
                    totalElements: results.length,
                    elements: pagedItems,
                    summary: fullSummary,
                    tokenEstimate: tokenEst
                };
            },

            // Resolves a replacement node for a stale reference when DOM changes occurred without intermediate snapshot
            selfHealElement: function(targetId, action) {
                if (!targetId) return null;
                var oldEl = (this.elements && this.elements[targetId]) || null;
                var sig = (this.elementSignatures && this.elementSignatures[targetId]) || null;

                var tag = (sig && sig.tag) || (oldEl && oldEl.tagName && oldEl.tagName.toLowerCase()) || null;
                var domId = (sig && sig.id) || (oldEl && oldEl.id) || null;
                var name = (sig && sig.name) || (oldEl && oldEl.getAttribute && oldEl.getAttribute('name')) || null;
                var testId = (sig && sig.testId) || (oldEl && oldEl.getAttribute && oldEl.getAttribute('data-testid')) || null;
                var ariaLabel = (sig && sig.ariaLabel) || (oldEl && oldEl.getAttribute && oldEl.getAttribute('aria-label')) || null;
                var text = (sig && sig.text) || (oldEl && (oldEl.innerText || oldEl.textContent || '').trim().replace(/\\s+/g, ' ')) || null;
                var placeholder = (sig && sig.placeholder) || (oldEl && oldEl.placeholder) || null;
                var type = (sig && sig.type) || (oldEl && oldEl.getAttribute && oldEl.getAttribute('type')) || null;
                var role = (sig && sig.role) || (oldEl && oldEl.getAttribute && oldEl.getAttribute('role')) || null;
                var className = (sig && sig.className) || (oldEl && oldEl.className && typeof oldEl.className === 'string' ? oldEl.className.trim() : null);

                var requiresInput = (action === 'type' || action === 'clear');
                var requiresSelect = (action === 'selectoption');

                // If the action requires a text-editable control, but the element signature was snapshotted
                // as a non-editable tag (e.g. <img>, <a>, <p>, <h1>), NEVER attempt to heal it into an input!
                if (requiresInput && tag) {
                    var isSigEditable = (tag === 'input' || tag === 'textarea' || (sig && sig.isContentEditable));
                    if (!isSigEditable) return null;
                    if (tag === 'input' && type) {
                        var nonText = ['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'range', 'color', 'hidden'];
                        if (nonText.indexOf(type.toLowerCase()) !== -1) return null;
                    }
                }
                if (requiresSelect && tag && tag !== 'select') {
                    return null;
                }

                // Fast path 1: query by element ID
                if (domId) {
                    try {
                        var byId = document.getElementById(domId);
                        if (byId && this.isNodeConnected(byId)) {
                            if ((!requiresInput || isTextEditable(byId)) &&
                                (!requiresSelect || byId.tagName.toLowerCase() === 'select')) {
                                return byId;
                            }
                        }
                    } catch(e) {}
                }
                // Fast path 2: query by data-testid
                if (testId) {
                    try {
                        var byTest = document.querySelector('[data-testid="' + CSS.escape(testId) + '"]');
                        if (byTest && this.isNodeConnected(byTest)) {
                            if ((!requiresInput || isTextEditable(byTest)) &&
                                (!requiresSelect || byTest.tagName.toLowerCase() === 'select')) {
                                return byTest;
                            }
                        }
                    } catch(e) {}
                }
                // Fast path 3: query by name and tag
                if (name && tag) {
                    try {
                        var byName = document.querySelectorAll(tag + '[name="' + CSS.escape(name) + '"]');
                        for (var ni = 0; ni < byName.length; ni++) {
                            var bn = byName[ni];
                            if (this.isNodeConnected(bn)) {
                                if ((!requiresInput || isTextEditable(bn)) &&
                                    (!requiresSelect || bn.tagName.toLowerCase() === 'select')) {
                                    return bn;
                                }
                            }
                        }
                    } catch(e) {}
                }
                // Fast path 4: query by aria-label and tag
                if (ariaLabel && tag) {
                    try {
                        var byAria = document.querySelectorAll(tag + '[aria-label="' + CSS.escape(ariaLabel) + '"]');
                        for (var ai = 0; ai < byAria.length; ai++) {
                            var ba = byAria[ai];
                            if (this.isNodeConnected(ba)) {
                                if ((!requiresInput || isTextEditable(ba)) &&
                                    (!requiresSelect || ba.tagName.toLowerCase() === 'select')) {
                                    return ba;
                                }
                            }
                        }
                    } catch(e) {}
                }

                // Scored search across candidates in the live document
                var selector = tag || (requiresInput ? 'input, textarea, [contenteditable="true"]' : (requiresSelect ? 'select' : 'a, button, input, textarea, select, details, summary, [role="button"], [role="link"], [contenteditable="true"]'));
                var candidates = [];
                try {
                    var found = document.querySelectorAll(selector);
                    for (var ci = 0; ci < found.length; ci++) {
                        var cand = found[ci];
                        if (this.isNodeConnected(cand)) {
                            if (requiresInput && !isTextEditable(cand)) continue;
                            if (requiresSelect && cand.tagName.toLowerCase() !== 'select') continue;
                            candidates.push(cand);
                        }
                    }
                } catch(e) {}

                var bestEl = null;
                var bestScore = -1;

                for (var k = 0; k < candidates.length; k++) {
                    var c = candidates[k];
                    var score = 0;
                    var cTag = c.tagName.toLowerCase();
                    if (tag && cTag === tag) score += 20;
                    if (domId && c.id === domId) score += 50;
                    if (name && c.getAttribute('name') === name) score += 35;
                    if (testId && c.getAttribute('data-testid') === testId) score += 50;
                    if (type && c.getAttribute('type') === type) score += 20;
                    if (role && c.getAttribute('role') === role) score += 20;
                    if (placeholder && c.placeholder === placeholder) score += 25;
                    if (ariaLabel && c.getAttribute('aria-label') === ariaLabel) score += 30;

                    var cText = (c.innerText || c.textContent || '').trim().replace(/\\s+/g, ' ');
                    if (text && cText === text) {
                        score += 40;
                    } else if (text && cText && (cText.indexOf(text) !== -1 || text.indexOf(cText) !== -1)) {
                        score += 20;
                    }

                    if (className && c.className && typeof c.className === 'string') {
                        if (c.className.trim() === className) score += 15;
                        else if (c.className.indexOf(className) !== -1) score += 10;
                    }

                    if (score > bestScore) {
                        bestScore = score;
                        bestEl = c;
                    }
                }

                if (bestScore >= 35 && bestEl) {
                    return bestEl;
                }

                // Positional guessing (candidates[n - 1]) is intentionally removed.
                // Ref-shifts that lack semantic signature match must fail cleanly with STALE_REF.
                return null;
            },

            // 2. Dispatches synthetic and realistic user actions
            performAction: function(actionObj) {
                try {
                    var action = (actionObj.action || actionObj.type || '').trim().toLowerCase();
                    var targetId = actionObj.target || actionObj.elementId || actionObj.selector;
                    var el = null;
                    var wasHealed = false;

                    if (!action) {
                        return { success: false, code: 'INVALID_ACTION', message: "Missing required 'type' or 'action' field" };
                    }

                    if (targetId) {
                        if (this.elements && this.elements[targetId] && this.isNodeConnected(this.elements[targetId])) {
                            el = this.elements[targetId];
                        } else {
                            el = this.findInTree(document, targetId);
                            if (el && this.elements) this.elements[targetId] = el;
                        }

                        // Validate compatibility with the requested action
                        var sig = (this.elementSignatures && this.elementSignatures[targetId]) || null;
                        var isIncompatible = false;
                        if (el) {
                            var elTag = el.tagName ? el.tagName.toLowerCase() : '';
                            if (action === 'type' || action === 'clear') {
                                if (!isTextEditable(el)) isIncompatible = true;
                            } else if (action === 'selectoption') {
                                if (elTag !== 'select') isIncompatible = true;
                            }
                        }

                    // In-place self-healing for stale node references or incompatible nodes
                    if ((!el || isIncompatible) && this.selfHealElement) {
                        var healed = this.selfHealElement(targetId, action);
                        if (healed) {
                            el = healed;
                            wasHealed = true;
                            isIncompatible = false;
                            if (!this.elements) this.elements = {};
                            this.elements[targetId] = el;
                            try { el.setAttribute('data-nomad-id', targetId); } catch(e) {}
                        }
                    }

                    // If still incompatible after healing attempt, explicitly report STALE_REF
                    if (el && isIncompatible) {
                        var currentDesc = '<' + (el.tagName ? el.tagName.toLowerCase() : 'element') + '>';
                        var expectedDesc = (sig && sig.tag) ? '<' + sig.tag + '>' : 'an editable control';
                        return {
                            success: false,
                            staleRef: true,
                            code: 'STALE_REF',
                            message: "Stale element reference '" + targetId + "': target was snapshotted as " + expectedDesc + " but currently resolves to " + currentDesc + " which is incompatible with '" + action + "'. The DOM shifted or reloaded. Please call nomad_snapshot to get fresh element refs.",
                            elementId: targetId
                        };
                    }
                }

                var targetRequiredActions = ['type', 'clear', 'selectoption', 'drag', 'highlight', 'upload'];
                if (targetRequiredActions.indexOf(action) !== -1 && !targetId) {
                    return { success: false, code: 'MISSING_TARGET', message: 'No target element specified for ' + action + ' action' };
                }

                if (targetId && !el && action !== 'scroll' && action !== 'press') {
                    return {
                        success: false,
                        staleRef: true,
                        code: 'STALE_REF',
                        message: "Target element '" + targetId + "' not found or no longer in DOM. Please re-snapshot the page.",
                        elementId: targetId
                    };
                }

                var actionOutcome = (function(self) {
                    switch (action) {
                    case 'click':
                        if (el) {
                            if (el.ownerDocument && el.ownerDocument !== document && el.ownerDocument.defaultView && el.ownerDocument.defaultView.frameElement) {
                                try { el.ownerDocument.defaultView.frameElement.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } catch(e) {}
                            }
                            el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                            try { el.focus(); } catch(e) {}

                            // If el is a label, delegate directly to its associated form control
                            if (el.tagName === 'LABEL') {
                                var targetInput = el.htmlFor ? (el.ownerDocument ? el.ownerDocument.getElementById(el.htmlFor) : document.getElementById(el.htmlFor)) : el.querySelector('input, select, textarea');
                                if (targetInput) el = targetInput;
                            }

                            var elDoc = el.ownerDocument || document;
                            var elWin = elDoc.defaultView || window;

                            var targetToClick = el;
                            var wasObscured = false;
                            var interceptorTag = null;

                            // Occlusion hit-testing: unless force: true, clicks hit what is physically on top
                            if (!actionObj.force) {
                                try {
                                    var rectC = el.getBoundingClientRect();
                                    var cxC = Math.round(rectC.left + rectC.width / 2);
                                    var cyC = Math.round(rectC.top + rectC.height / 2);
                                    var topEl = elDoc.elementFromPoint(cxC, cyC);
                                    if (topEl && topEl !== el && !el.contains(topEl) && !topEl.contains(el)) {
                                        var rootNode = el.getRootNode ? el.getRootNode() : null;
                                        var host = (rootNode && rootNode.host) ? rootNode.host : null;
                                        if (topEl !== host && (!host || !host.contains(topEl))) {
                                            wasObscured = true;
                                            interceptorTag = topEl.tagName ? topEl.tagName.toLowerCase() : 'overlay';
                                            targetToClick = topEl;
                                        }
                                    }
                                } catch(e) {}
                            }

                            // Pointer and mouse event simulation sequence
                            var pdown = new elWin.PointerEvent('pointerdown', { bubbles: true, cancelable: true, view: elWin });
                            var mdown = new elWin.MouseEvent('mousedown', { bubbles: true, cancelable: true, view: elWin });
                            var pup = new elWin.PointerEvent('pointerup', { bubbles: true, cancelable: true, view: elWin });
                            var mup = new elWin.MouseEvent('mouseup', { bubbles: true, cancelable: true, view: elWin });

                            targetToClick.dispatchEvent(pdown);
                            targetToClick.dispatchEvent(mdown);
                            targetToClick.dispatchEvent(pup);
                            targetToClick.dispatchEvent(mup);

                            // Native click triggers standard activation behavior (checkboxes, buttons, navigation)
                            try {
                                targetToClick.click();
                            } catch(e) {
                                targetToClick.dispatchEvent(new elWin.MouseEvent('click', { bubbles: true, cancelable: true, view: elWin }));
                            }

                            if (wasObscured) {
                                return {
                                    success: true,
                                    message: 'Clicked point of ' + (targetId || 'element') + ' (intercepted by <' + interceptorTag + '>)',
                                    elementId: targetId,
                                    obscured: true,
                                    interceptedBy: interceptorTag
                                };
                            }

                            return { success: true, message: 'Clicked ' + (targetId || 'element'), elementId: targetId };
                        } else if (actionObj.x !== undefined && actionObj.y !== undefined) {
                            var hit = document.elementFromPoint(actionObj.x, actionObj.y);
                            if (hit) {
                                hit.click();
                                return { success: true, message: 'Clicked coordinates (' + actionObj.x + ', ' + actionObj.y + ')' };
                            }
                            return { success: false, code: 'ELEMENT_NOT_FOUND', message: 'No element at coordinates (' + actionObj.x + ', ' + actionObj.y + ')' };
                        }
                        return { success: false, code: 'MISSING_TARGET', message: 'No target element or coordinates specified for click action' };

                    case 'hover':
                        if (!el) return { success: false, code: 'MISSING_TARGET', message: 'No target element for hover action' };
                        if (el.ownerDocument && el.ownerDocument !== document && el.ownerDocument.defaultView && el.ownerDocument.defaultView.frameElement) {
                            try { el.ownerDocument.defaultView.frameElement.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } catch(e) {}
                        }
                        el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                        var elDocH = el.ownerDocument || document;
                        var elWinH = elDocH.defaultView || window;
                        el.dispatchEvent(new elWinH.PointerEvent('pointerover', { bubbles: true, cancelable: true, view: elWinH }));
                        el.dispatchEvent(new elWinH.PointerEvent('pointerenter', { bubbles: false, cancelable: false, view: elWinH }));
                        el.dispatchEvent(new elWinH.MouseEvent('mouseover', { bubbles: true, cancelable: true, view: elWinH }));
                        el.dispatchEvent(new elWinH.MouseEvent('mousemove', { bubbles: true, cancelable: true, view: elWinH }));
                        return { success: true, message: 'Hovered over ' + targetId, elementId: targetId };

                    case 'clear':
                        if (!el) return { success: false, code: 'MISSING_TARGET', message: 'No target element for clear action' };
                        if (!isTextEditable(el)) {
                            return { success: false, code: 'NOT_EDITABLE', message: 'Target element <' + el.tagName.toLowerCase() + '> is not an input or editable element' };
                        }
                        if (el.ownerDocument && el.ownerDocument !== document && el.ownerDocument.defaultView && el.ownerDocument.defaultView.frameElement) {
                            try { el.ownerDocument.defaultView.frameElement.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } catch(e) {}
                        }
                        el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                        try { el.focus(); } catch(e) {}
                        var elDocC = el.ownerDocument || document;
                        var elWinC = elDocC.defaultView || window;
                        if (el.isContentEditable) {
                            try {
                                elDocC.execCommand('selectAll', false, null);
                                elDocC.execCommand('delete', false, null);
                            } catch(e) {
                                el.innerText = '';
                            }
                            el.dispatchEvent(new (elWinC.Event || Event)('input', { bubbles: true }));
                            return { success: true, message: 'Cleared value in ' + targetId, elementId: targetId };
                        }
                        var clearTag = el.tagName ? el.tagName.toUpperCase() : '';
                        try {
                            var protoC = (clearTag === 'TEXTAREA') ? ((elWinC.HTMLTextAreaElement && elWinC.HTMLTextAreaElement.prototype) || window.HTMLTextAreaElement.prototype) : ((elWinC.HTMLInputElement && elWinC.HTMLInputElement.prototype) || window.HTMLInputElement.prototype);
                            var descC = Object.getOwnPropertyDescriptor(protoC, 'value');
                            var setterC = descC && descC.set;
                            if (setterC) { setterC.call(el, ''); } else { el.value = ''; }
                        } catch(e) {
                            el.value = '';
                        }
                        el.dispatchEvent(new (elWinC.Event || Event)('input', { bubbles: true }));
                        el.dispatchEvent(new (elWinC.Event || Event)('change', { bubbles: true }));
                        return { success: true, message: 'Cleared value in ' + targetId, elementId: targetId };

                    case 'type':
                        if (!el) return { success: false, code: 'MISSING_TARGET', message: 'No target element for type action' };
                        if (!isTextEditable(el)) {
                            return { success: false, code: 'NOT_EDITABLE', message: 'Target element <' + el.tagName.toLowerCase() + '> is not editable or an input control' };
                        }
                        if (el.ownerDocument && el.ownerDocument !== document && el.ownerDocument.defaultView && el.ownerDocument.defaultView.frameElement) {
                            try { el.ownerDocument.defaultView.frameElement.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } catch(e) {}
                        }
                        el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                        try { el.focus(); } catch(e) {}
                        var typeTag = el.tagName ? el.tagName.toUpperCase() : '';
                        var hasExplicitText = actionObj.text !== undefined && actionObj.text !== null;
                        var textToType = hasExplicitText ? String(actionObj.text) : '';
                        var shouldUpdateValue = hasExplicitText && (textToType.length > 0 || actionObj.clear === true || !actionObj.submit);
                        var elDocT = el.ownerDocument || document;
                        var elWinT = elDocT.defaultView || window;
                        if (el.isContentEditable) {
                            if (shouldUpdateValue) {
                                try {
                                    elDocT.execCommand('selectAll', false, null);
                                    elDocT.execCommand('insertText', false, textToType);
                                } catch(e) {
                                    el.innerText = textToType;
                                }
                                el.dispatchEvent(new (elWinT.Event || Event)('input', { bubbles: true }));
                            }
                            if (actionObj.submit) {
                                var cEnterDown = new (elWinT.KeyboardEvent || KeyboardEvent)('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true });
                                var cEnterUp = new (elWinT.KeyboardEvent || KeyboardEvent)('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true });
                                el.dispatchEvent(cEnterDown);
                                el.dispatchEvent(cEnterUp);
                            }
                            var ceMsg = shouldUpdateValue ? ('Typed into ' + (targetId || 'element')) : ('Submitted ' + (targetId || 'element'));
                            return { success: true, message: ceMsg, elementId: targetId };
                        }
                        if (shouldUpdateValue) {
                            try {
                                // React 16+ controlled component compatibility
                                var protoType = (typeTag === 'TEXTAREA') ? ((elWinT.HTMLTextAreaElement && elWinT.HTMLTextAreaElement.prototype) || window.HTMLTextAreaElement.prototype) : ((elWinT.HTMLInputElement && elWinT.HTMLInputElement.prototype) || window.HTMLInputElement.prototype);
                                var descType = Object.getOwnPropertyDescriptor(protoType, 'value');
                                var setterType = descType && descType.set;
                                if (setterType) { setterType.call(el, textToType); } else { el.value = textToType; }
                            } catch(e) {
                                el.value = textToType;
                            }
                            el.dispatchEvent(new (elWinT.Event || Event)('input', { bubbles: true }));
                        }
                        if (actionObj.submit || actionObj.blur || actionObj.change) {
                            el.dispatchEvent(new (elWinT.Event || Event)('change', { bubbles: true }));
                        }
                        if (actionObj.blur) {
                            try { el.blur(); } catch(e) {}
                        }
                        if (actionObj.submit) {
                            var enterDown = new (elWinT.KeyboardEvent || KeyboardEvent)('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true });
                            var enterUp = new (elWinT.KeyboardEvent || KeyboardEvent)('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true });
                            el.dispatchEvent(enterDown);
                            el.dispatchEvent(enterUp);
                            var f = el.form || (el.closest ? el.closest('form') : null);
                            if (f) {
                                try {
                                    if (typeof f.requestSubmit === 'function') f.requestSubmit();
                                    else f.submit();
                                } catch(e) {}
                            }
                        }
                        var inputMsg = shouldUpdateValue ? ('Typed into ' + (targetId || 'element')) : ('Submitted ' + (targetId || 'element'));
                        return { success: true, message: inputMsg, elementId: targetId };

                    case 'drag':
                        if (!el) return { success: false, code: 'MISSING_TARGET', message: 'No source element for drag action' };
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

                        var validNamedKeys = {
                            'enter': 'Enter', 'tab': 'Tab', 'escape': 'Escape', 'esc': 'Escape',
                            'backspace': 'Backspace', 'delete': 'Delete', 'del': 'Delete',
                            'arrowup': 'ArrowUp', 'up': 'ArrowUp',
                            'arrowdown': 'ArrowDown', 'down': 'ArrowDown',
                            'arrowleft': 'ArrowLeft', 'left': 'ArrowLeft',
                            'arrowright': 'ArrowRight', 'right': 'ArrowRight',
                            'home': 'Home', 'end': 'End', 'pageup': 'PageUp', 'pagedown': 'PageDown',
                            'space': ' ', 'spacebar': ' ',
                            'capslock': 'CapsLock', 'insert': 'Insert',
                            'f1': 'F1', 'f2': 'F2', 'f3': 'F3', 'f4': 'F4',
                            'f5': 'F5', 'f6': 'F6', 'f7': 'F7', 'f8': 'F8',
                            'f9': 'F9', 'f10': 'F10', 'f11': 'F11', 'f12': 'F12',
                            'meta': 'Meta', 'cmd': 'Meta', 'command': 'Meta',
                            'control': 'Control', 'ctrl': 'Control',
                            'shift': 'Shift', 'alt': 'Alt', 'option': 'Alt'
                        };

                        var normMain = mainKey.trim().toLowerCase();
                        if (mainKey.length > 1) {
                            if (!validNamedKeys[normMain]) {
                                return { success: false, code: 'INVALID_KEY', message: 'Unknown or unsupported key: ' + rawKey };
                            }
                            mainKey = validNamedKeys[normMain];
                        }

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

                    case 'selectoption':
                    case 'selectOption':
                        if (!el || el.tagName !== 'SELECT') {
                            return { success: false, code: !el ? 'MISSING_TARGET' : 'NOT_A_SELECT', message: 'Target ' + targetId + ' is not a <select> element' };
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
                        return { success: false, code: 'OPTION_NOT_FOUND', message: 'Option not found in ' + targetId };

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

                        var prevScrollY = window.scrollY || window.pageYOffset || 0;
                        var prevScrollX = window.scrollX || window.pageXOffset || 0;
                        window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
                        var actualDy = Math.round((window.scrollY || window.pageYOffset || 0) - prevScrollY);
                        var actualDx = Math.round((window.scrollX || window.pageXOffset || 0) - prevScrollX);

                        var desc = '';
                        if (actualDy !== 0) {
                            desc = actualDy > 0 ? 'down by ' + actualDy + 'px' : 'up by ' + Math.abs(actualDy) + 'px';
                            if (dy !== 0 && Math.abs(actualDy) < Math.abs(dy)) {
                                desc += ' (clamped from requested ' + Math.abs(dy) + 'px)';
                            }
                        } else if (actualDx !== 0) {
                            desc = actualDx > 0 ? 'right by ' + actualDx + 'px' : 'left by ' + Math.abs(actualDx) + 'px';
                            if (dx !== 0 && Math.abs(actualDx) < Math.abs(dx)) {
                                desc += ' (clamped from requested ' + Math.abs(dx) + 'px)';
                            }
                        } else {
                            desc = '0px (already at boundary)';
                        }
                        return { success: true, message: 'Scrolled ' + desc };

                    case 'highlight':
                        if (!el) return { success: false, code: 'MISSING_TARGET', message: 'No target element to highlight' };
                        self.showHighlight(el);
                        return { success: true, message: 'Highlighted ' + targetId, elementId: targetId };

                    case 'upload':
                        if (!el) return { success: false, code: 'MISSING_TARGET', message: 'No target element for upload action' };
                        if (el.ownerDocument && el.ownerDocument !== document && el.ownerDocument.defaultView && el.ownerDocument.defaultView.frameElement) {
                            try { el.ownerDocument.defaultView.frameElement.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } catch(e) {}
                        }
                        el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                        try { el.focus(); } catch(e) {}

                        // Resolve file input: el directly, or if label/button, find input[type=file]
                        var fileInput = null;
                        if (el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'file') {
                            fileInput = el;
                        } else if (el.tagName === 'LABEL') {
                            var targetInput = el.htmlFor ? (el.ownerDocument ? el.ownerDocument.getElementById(el.htmlFor) : document.getElementById(el.htmlFor)) : el.querySelector('input[type="file"]');
                            if (targetInput && targetInput.tagName === 'INPUT' && (targetInput.type || '').toLowerCase() === 'file') {
                                fileInput = targetInput;
                            }
                        } else {
                            fileInput = el.querySelector('input[type="file"]');
                        }

                        var targetToClick = fileInput || el;
                        try {
                            targetToClick.click();
                        } catch(e) {
                            var elDocU = targetToClick.ownerDocument || document;
                            var elWinU = elDocU.defaultView || window;
                            targetToClick.dispatchEvent(new elWinU.MouseEvent('click', { bubbles: true, cancelable: true, view: elWinU }));
                        }
                        return { success: true, message: 'Triggered file upload on ' + (targetId || 'element'), elementId: targetId };

                    default:
                        return { success: false, code: 'UNKNOWN_ACTION', message: 'Unknown action: ' + action };
                }
            })(this);

            if (actionOutcome && actionOutcome.success && wasHealed) {
                actionOutcome.healed = true;
            }
            return actionOutcome;
        } catch (actionErr) {
            var errMsg = (actionErr && actionErr.message) ? actionErr.message : String(actionErr);
            var errStack = (actionErr && actionErr.stack) ? actionErr.stack : null;
            return {
                success: false,
                code: 'ACTION_JS_ERROR',
                error: errMsg,
                message: "Action '" + (actionObj && (actionObj.action || actionObj.type)) + "' threw JavaScript error: " + errMsg,
                stack: errStack,
                elementId: (actionObj && (actionObj.target || actionObj.elementId || actionObj.selector)) || null
            };
        }
    },

            // 3. Visual Element Highlighter for DevX & Inspection
            showHighlight: function(el) {
                var prev = document.getElementById('__nomad_highlight');
                if (prev) prev.remove();

                var rect = this.getElementViewportRect(el);
                var div = document.createElement('div');
                div.id = '__nomad_highlight';
                div.style.position = 'fixed';
                div.style.left = (rect.left - 2) + 'px';
                div.style.top = (rect.top - 2) + 'px';
                div.style.width = (rect.width + 4) + 'px';
                div.style.height = (rect.height + 4) + 'px';
                div.style.border = '2px solid rgba(0, 0, 0, 0.85)';
                div.style.outline = '1px solid rgba(255, 255, 255, 0.85)';
                div.style.borderRadius = '4px';
                div.style.backgroundColor = 'rgba(0, 0, 0, 0.12)';
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
                container.innerHTML = '<style>.__nb{position:fixed;background:#000;color:#fff;border:1px solid rgba(255,255,255,0.8);font:bold 10px monospace;padding:1px 3px;border-radius:3px;box-shadow:0 1px 3px rgba(0,0,0,0.6);}</style>';

                for (var id in this.elements) {
                    var el = this.elements[id];
                    var rect = this.getElementViewportRect(el);
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
                    var lastMutationTime = performance.now();
                    var mutationCount = 0;
                    var intervalTimer = null;
                    var maxTimer = null;
                    var resolved = false;
                    var observer = null;
                    var recentMutationTimes = [];

                    function recordMutation(count) {
                        var t = performance.now();
                        lastMutationTime = t;
                        mutationCount += count;
                        recentMutationTimes.push(t);
                        if (recentMutationTimes.length > 20) {
                            recentMutationTimes.shift();
                        }
                    }

                    function done(res) {
                        if (resolved) return;
                        resolved = true;
                        if (maxTimer) clearTimeout(maxTimer);
                        if (intervalTimer) clearInterval(intervalTimer);
                        if (observer) {
                            try { observer.disconnect(); } catch(e) {}
                            observer = null;
                        }
                        resolve(res);
                    }

                    maxTimer = setTimeout(function() {
                        done({ success: false, reason: 'timeout', message: 'Exceeded max wait of ' + maxWait + 'ms (' + mutationCount + ' mutations observed)', mutations: mutationCount });
                    }, maxWait);

                    try {
                        observer = new MutationObserver(function(mutations) {
                            var added = (mutations ? mutations.length : 1);
                            recordMutation(added);
                        });
                        var targetNode = document;
                        observer.observe(targetNode, {
                            childList: true,
                            subtree: true,
                            attributes: true,
                            characterData: true
                        });
                    } catch(e) {}

                    intervalTimer = setInterval(function() {
                        if (resolved) return;
                        if (observer) {
                            try {
                                var records = observer.takeRecords();
                                if (records && records.length > 0) {
                                    recordMutation(records.length);
                                }
                            } catch(e) {}
                        }
                        var now = performance.now();
                        var isReady = (document.readyState === 'complete' || document.readyState === 'interactive');

                        // Dynamic cadence detection: if recurring periodic mutations occur (e.g. 50ms churn with timer jitter),
                        // require silence that strictly exceeds the observed interval cadence to avoid false-settling mid-churn.
                        var requiredQuiet = quiet;
                        if (recentMutationTimes.length >= 2) {
                            var intervals = [];
                            for (var k = 1; k < recentMutationTimes.length; k++) {
                                var diff = recentMutationTimes[k] - recentMutationTimes[k - 1];
                                if (diff > 10 && diff <= 800) {
                                    intervals.push(diff);
                                }
                            }
                            if (intervals.length >= 1) {
                                var sum = 0;
                                var maxInt = 0;
                                for (var m = 0; m < intervals.length; m++) {
                                    sum += intervals[m];
                                    if (intervals[m] > maxInt) maxInt = intervals[m];
                                }
                                var avgInt = sum / intervals.length;
                                var dynamicFloor = Math.max(Math.round(avgInt * 2.5), Math.round(maxInt * 1.8));
                                if (dynamicFloor > requiredQuiet) {
                                    requiredQuiet = dynamicFloor;
                                }
                            }
                        }

                        if (isReady && (now - lastMutationTime) >= requiredQuiet) {
                            done({ success: true, message: 'DOM stabilized for ' + quiet + 'ms (' + mutationCount + ' mutations observed)', mutations: mutationCount });
                        }
                    }, 25);
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
        if webView.isLoading {
            let start = Date()
            while webView.isLoading && Date().timeIntervalSince(start) < 0.5 {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
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
        if webView.isLoading {
            let start = Date()
            while webView.isLoading && Date().timeIntervalSince(start) < 0.4 {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            if webView.isLoading {
                return NomadActionResult(success: false, message: "Cannot execute action '\(action.action)': active page is currently navigating. Wait for navigation to complete before dispatching actions.", elementId: action.target)
            }
        }

        // Programmatic file upload staging & validation
        if action.action.lowercased() == "upload" {
            let paths = action.resolvedPaths
            guard !paths.isEmpty else {
                return NomadActionResult(success: false, message: "Missing required 'paths' or 'files' for upload action", elementId: action.target, code: "MISSING_PATHS")
            }
            var validatedURLs: [URL] = []
            for path in paths {
                let expanded = (path as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: expanded) else {
                    return NomadActionResult(success: false, message: "File not found at path: \(path)", elementId: action.target, code: "FILE_NOT_FOUND")
                }
                guard FileManager.default.isReadableFile(atPath: expanded) else {
                    return NomadActionResult(success: false, message: "File is not readable at path: \(path)", elementId: action.target, code: "FILE_NOT_READABLE")
                }
                validatedURLs.append(URL(fileURLWithPath: expanded))
            }
            self.stageUpload(urls: validatedURLs)
        }

        await ensureNomadScriptInjected()
        let actionData = try JSONEncoder().encode(action)
        guard let actionJSON = String(data: actionData, encoding: .utf8) else {
            throw NSError(domain: "NomadAgent", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode action JSON"])
        }
        do {
            let resultString = try await webView.evaluateJavaScript("JSON.stringify(window.__nomad.performAction(\(actionJSON)))") as? String ?? "{}"
            guard let resultData = resultString.data(using: .utf8) else {
                return NomadActionResult(success: false, message: "Failed to parse action result JSON", elementId: action.target, code: "ACTION_PARSE_ERROR")
            }
            var res = try JSONDecoder().decode(NomadActionResult.self, from: resultData)
            if action.action.lowercased() == "upload" && res.success {
                res.files = action.resolvedPaths
                res.count = action.resolvedPaths.count
                res.message = "Successfully uploaded \(res.count ?? 1) file(s) to \(action.target ?? "element")"
            }
            return res
        } catch let decodeErr as DecodingError {
            return NomadActionResult(success: false, message: "Failed to decode action result: \(decodeErr.localizedDescription)", elementId: action.target, code: "ACTION_DECODE_ERROR")
        } catch {
            return NomadActionResult(
                success: false,
                message: "JavaScript evaluation failed: \(error.localizedDescription)",
                elementId: action.target,
                code: "ACTION_EVALUATION_ERROR",
                error: error.localizedDescription
            )
        }
    }

    /// Waits for DOM mutation quiescence (stability) on the active page.
    @MainActor
    func waitForStability(quietMs: Int = 250, timeoutMs: Int = 5000) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        // 1. Wait for webView provisional or active navigation to complete
        while webView.isLoading && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        // 2. Wait for HTML document to finish parsing
        while Date() < deadline {
            let readyState = (try? await webView.evaluateJavaScript("document.readyState")) as? String
            if readyState != "loading" {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let remainingSeconds = deadline.timeIntervalSinceNow
        if remainingSeconds <= 0.05 && timeoutMs > 50 {
            return ["success": false, "reason": "timeout", "message": "Exceeded max wait of \(timeoutMs)ms (page still loading)"]
        }
        let remainingTimeoutMs = max(50, Int(remainingSeconds * 1000.0))

        await ensureNomadScriptInjected()
        let script = """
        return await (async () => {
            if (!window.__nomad || !window.__nomad.waitForStability) {
                return { success: false, reason: "not_ready", message: "Nomad agent perception script not initialized" };
            }
            return await window.__nomad.waitForStability(quietMs, timeoutMs);
        })();
        """
        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.webView.callAsyncJavaScript(script, arguments: ["quietMs": quietMs, "timeoutMs": remainingTimeoutMs], in: nil, in: .page) { result in
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
                                continuation.resume(returning: ["success": false, "reason": "navigation_occurred", "message": "Document navigated during wait for stability"])
                            } else {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            }
            group.addTask {
                let sleepTime = max(0.1, remainingSeconds + 0.3)
                try await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
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
            let safeElIdData = (try? JSONSerialization.data(withJSONObject: [elId])) ?? Data("[\"\"]".utf8)
            let safeElIdArray = String(data: safeElIdData, encoding: .utf8) ?? "[\"\"]"
            let rectScript = """
            (function() {
                var targetId = (\(safeElIdArray))[0];
                var el = window.__nomad && window.__nomad.elements && window.__nomad.elements[targetId];
                if (!el && window.__nomad && window.__nomad.findInTree) { el = window.__nomad.findInTree(document, targetId); }
                if (!el) {
                    try { el = document.querySelector('[data-nomad-id="' + CSS.escape(targetId) + '"]'); } catch(e) {}
                }
                if (el) {
                    var r = (window.__nomad && window.__nomad.getElementViewportRect) ? window.__nomad.getElementViewportRect(el) : el.getBoundingClientRect();
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
            } else {
                throw NSError(domain: "NomadAgent", code: -5, userInfo: [NSLocalizedDescriptionKey: "Element '\(elId)' not found or has zero dimensions for screenshot crop"])
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
