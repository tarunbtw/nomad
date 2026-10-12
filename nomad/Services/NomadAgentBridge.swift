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
    var action: String // "click", "type", "press", "scroll", "highlight"
    var target: String? // e.g. "e1", "e2"
    var text: String?
    var key: String? // "Enter", "Escape", "Tab", etc.
    var direction: String? // "up", "down", "left", "right"
    var amount: CGFloat?
    var submit: Bool?
    var x: CGFloat?
    var y: CGFloat?

    init(
        action: String,
        target: String? = nil,
        text: String? = nil,
        key: String? = nil,
        direction: String? = nil,
        amount: CGFloat? = nil,
        submit: Bool? = nil,
        x: CGFloat? = nil,
        y: CGFloat? = nil
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
    /// Injected JavaScript that parses visible interactive elements, computes bounding boxes,
    /// formats a dense LLM-friendly semantic summary, and executes native browser actions.
    public static let core = """
    (function() {
        if (window.__nomad) return;

        window.__nomad = {
            elements: {},

            // 1. Scans visible interactive targets and generates dense LLM summary
            getSemanticTree: function() {
                this.elements = {};
                var results = [];
                var counter = 1;

                var selector = 'a, button, input, textarea, select, details, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="combobox"], [role="menuitem"], [role="tab"], [tabindex]:not([tabindex="-1"])';
                var nodes = document.querySelectorAll(selector);

                var vpW = window.innerWidth;
                var vpH = window.innerHeight;

                for (var i = 0; i < nodes.length; i++) {
                    var el = nodes[i];
                    var rect = el.getBoundingClientRect();

                    // Visibility check: size and viewport containment
                    if (rect.width <= 0 || rect.height <= 0) continue;
                    if (rect.bottom < -100 || rect.top > vpH + 100 || rect.right < -100 || rect.left > vpW + 100) continue;

                    var style = window.getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity) < 0.05) continue;
                    if (style.pointerEvents === 'none') continue;

                    var id = 'e' + counter++;
                    this.elements[id] = el;
                    el.setAttribute('data-nomad-id', id);

                    // Extract accessible label/text
                    var text = (el.innerText || el.textContent || el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || el.value || '').trim();
                    text = text.replace(/\\s+/g, ' ').substring(0, 80);

                    var tag = el.tagName.toLowerCase();
                    var role = el.getAttribute('role') || tag;
                    var type = el.getAttribute('type') || null;
                    var val = el.value !== undefined && el.value !== '' ? String(el.value).substring(0, 50) : null;

                    results.push({
                        id: id,
                        tag: tag,
                        role: role,
                        text: text,
                        value: val,
                        type: type,
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
                    desc += '>';
                    summaryLines.push(desc);
                }

                return {
                    title: document.title || '',
                    url: window.location.href,
                    viewportWidth: vpW,
                    viewportHeight: vpH,
                    elements: results,
                    summary: summaryLines.join('\\n')
                };
            },

            // 2. Dispatches synthetic actions on targeted elements
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
                            var mdown = new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window });
                            var mup = new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window });
                            var clk = new MouseEvent('click', { bubbles: true, cancelable: true, view: window });
                            el.dispatchEvent(mdown);
                            el.dispatchEvent(mup);
                            el.dispatchEvent(clk);
                            if (el.tagName === 'A' && el.href) {
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

                    case 'type':
                        if (!el) return { success: false, message: 'No target element for type action' };
                        el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                        el.focus();
                        var textToType = actionObj.text || '';
                        el.value = textToType;
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
                        var keyName = actionObj.key || 'Enter';
                        var targetNode = el || document.activeElement || document.body;
                        var kdown = new KeyboardEvent('keydown', { key: keyName, code: keyName, bubbles: true });
                        var kup = new KeyboardEvent('keyup', { key: keyName, code: keyName, bubbles: true });
                        targetNode.dispatchEvent(kdown);
                        targetNode.dispatchEvent(kup);
                        return { success: true, message: 'Pressed key ' + keyName };

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

    /// Dispatches a browser action (click, type, scroll, keypress, highlight) on the active page.
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
