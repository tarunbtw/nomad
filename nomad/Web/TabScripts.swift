//
//  TabScripts.swift
//  nomad
//
//  Created by tarun on 14/10/26.
//

import Foundation

/// Injected DOM JavaScript routines for DevX Inspector, Element Zapper, and Reading Mode.
enum TabScripts {

    // MARK: - Element Inspector (DevX Drawer)
    static let startInspector = """
    (function() {
        if (window.__nomad_inspector_active) return;
        window.__nomad_inspector_active = true;
        let overlay = document.getElementById('__nomad_inspect_overlay');
        if (!overlay) {
            overlay = document.createElement('div');
            overlay.id = '__nomad_inspect_overlay';
            overlay.style.position = 'fixed';
            overlay.style.pointerEvents = 'none';
            overlay.style.border = '2px solid #007aff';
            overlay.style.backgroundColor = 'rgba(0, 122, 255, 0.15)';
            overlay.style.zIndex = '2147483647';
            overlay.style.transition = 'all 0.05s ease';
            overlay.style.borderRadius = '3px';
            document.body.appendChild(overlay);
        }
        overlay.style.display = 'none';

        function onMouseMove(e) {
            const el = document.elementFromPoint(e.clientX, e.clientY);
            if (!el || el === overlay) return;
            const rect = el.getBoundingClientRect();
            overlay.style.left = rect.left + 'px';
            overlay.style.top = rect.top + 'px';
            overlay.style.width = rect.width + 'px';
            overlay.style.height = rect.height + 'px';
            overlay.style.display = 'block';
        }

        function cleanup() {
            window.__nomad_inspector_active = false;
            window.removeEventListener('mousemove', onMouseMove, true);
            window.removeEventListener('click', onClick, true);
            window.removeEventListener('keydown', onKeyDown, true);
            if (overlay) overlay.style.display = 'none';
        }

        function onClick(e) {
            e.preventDefault();
            e.stopPropagation();
            const el = document.elementFromPoint(e.clientX, e.clientY);
            if (el && el !== overlay) {
                const rect = el.getBoundingClientRect();
                let sel = el.tagName.toLowerCase();
                if (el.id) {
                    sel += '#' + el.id;
                } else if (el.className && typeof el.className === 'string') {
                    const cls = el.className.trim().split(/\\s+/).filter(Boolean).slice(0, 2).join('.');
                    if (cls) sel += '.' + cls;
                }
                const info = {
                    selector: sel,
                    tag: el.tagName.toLowerCase(),
                    idAttr: el.id || '',
                    classes: typeof el.className === 'string' ? el.className.trim() : '',
                    text: (el.innerText || el.textContent || '').trim().slice(0, 300),
                    width: Math.round(rect.width),
                    height: Math.round(rect.height),
                    agentId: el.getAttribute('data-nomad-id') || null
                };
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadInspect) {
                    window.webkit.messageHandlers.nomadInspect.postMessage(info);
                }
            }
            cleanup();
        }

        function onKeyDown(e) {
            if (e.key === 'Escape') {
                cleanup();
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadInspect) {
                    window.webkit.messageHandlers.nomadInspect.postMessage({ cancel: true });
                }
            }
        }

        window.addEventListener('mousemove', onMouseMove, true);
        window.addEventListener('click', onClick, true);
        window.addEventListener('keydown', onKeyDown, true);
    })();
    """

    static func highlightElement(selector: String) -> String {
        let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
            try {
                const el = document.querySelector('\(escaped)');
                if (!el) return;
                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                const prev = el.style.outline;
                const prevTrans = el.style.transition;
                el.style.transition = 'outline 0.15s ease';
                el.style.outline = '3px solid #007aff';
                setTimeout(() => {
                    el.style.outline = prev;
                    el.style.transition = prevTrans;
                }, 1500);
            } catch(e) {}
        })();
        """
    }

    // MARK: - Element Zapper (Hide Anything ⇧⌘H)
    static let startZapper = """
    (function() {
        if (typeof window.__nomad_zapper_cleanup === 'function') {
            window.__nomad_zapper_cleanup();
        }
        window.__nomad_zapper_active = true;
        document.documentElement.style.cursor = 'crosshair';

        let overlay = document.getElementById('__nomad_zap_overlay');
        if (!overlay) {
            overlay = document.createElement('div');
            overlay.id = '__nomad_zap_overlay';
            overlay.style.position = 'fixed';
            overlay.style.pointerEvents = 'none';
            overlay.style.border = '2px dashed #ff3b30';
            overlay.style.backgroundColor = 'rgba(255, 59, 48, 0.18)';
            overlay.style.zIndex = '2147483647';
            overlay.style.transition = 'all 0.05s ease';
            overlay.style.borderRadius = '3px';
            (document.body || document.documentElement).appendChild(overlay);
        }
        overlay.style.display = 'none';

        function onMouseMove(e) {
            if (!window.__nomad_zapper_active) return;
            const isOverBar = (e.clientY < 65 && Math.abs(e.clientX - window.innerWidth / 2) < 250);
            if (isOverBar) {
                overlay.style.display = 'none';
                document.documentElement.style.cursor = 'default';
                return;
            }
            document.documentElement.style.cursor = 'crosshair';
            const el = document.elementFromPoint(e.clientX, e.clientY);
            if (!el || el === overlay) return;
            const rect = el.getBoundingClientRect();
            overlay.style.left = rect.left + 'px';
            overlay.style.top = rect.top + 'px';
            overlay.style.width = rect.width + 'px';
            overlay.style.height = rect.height + 'px';
            overlay.style.display = 'block';
        }

        function cleanup() {
            window.__nomad_zapper_active = false;
            window.__nomad_zapper_cleanup = null;
            document.documentElement.style.cursor = '';
            window.removeEventListener('mousemove', onMouseMove, true);
            window.removeEventListener('click', onClick, true);
            window.removeEventListener('keydown', onKeyDown, true);
            const ov = document.getElementById('__nomad_zap_overlay');
            if (ov) {
                ov.style.display = 'none';
                ov.remove();
            }
        }
        window.__nomad_zapper_cleanup = cleanup;

        function onClick(e) {
            if (!window.__nomad_zapper_active) return;
            if (e.clientY < 65 && Math.abs(e.clientX - window.innerWidth / 2) < 250) {
                return;
            }
            e.preventDefault();
            e.stopPropagation();
            const el = document.elementFromPoint(e.clientX, e.clientY);
            if (el && el !== overlay) {
                let sel = el.tagName.toLowerCase();
                if (el.id) {
                    sel += '#' + el.id;
                } else if (el.className && typeof el.className === 'string') {
                    const cls = el.className.trim().split(/\\s+/).filter(Boolean).slice(0, 2).join('.');
                    if (cls) sel += '.' + cls;
                }
                el.setAttribute('data-nomad-zapped', 'true');
                el.style.setProperty('display', 'none', 'important');
                overlay.style.display = 'none';
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadZapper) {
                    window.webkit.messageHandlers.nomadZapper.postMessage({
                        host: window.location.host,
                        selector: sel
                    });
                }
            }
        }

        function onKeyDown(e) {
            if (!window.__nomad_zapper_active) return;
            if (e.key === 'Escape' || e.keyCode === 27 || e.which === 27) {
                e.preventDefault();
                e.stopPropagation();
                cleanup();
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadZapper) {
                    window.webkit.messageHandlers.nomadZapper.postMessage({ cancel: true });
                }
            }
        }

        window.addEventListener('mousemove', onMouseMove, true);
        window.addEventListener('click', onClick, true);
        window.addEventListener('keydown', onKeyDown, true);
    })();
    """

    static let stopZapper = """
    (function() {
        if (typeof window.__nomad_zapper_cleanup === 'function') {
            window.__nomad_zapper_cleanup();
        }
        window.__nomad_zapper_active = false;
        document.documentElement.style.cursor = '';
        const overlay = document.getElementById('__nomad_zap_overlay');
        if (overlay) {
            overlay.style.display = 'none';
            overlay.remove();
        }
    })();
    """

    static let unhideZapped = """
    (function() {
        const s = document.getElementById('nomad-zapped-rules');
        if (s) s.remove();
        document.querySelectorAll('[data-nomad-zapped="true"]').forEach(el => {
            el.style.removeProperty('display');
            el.removeAttribute('data-nomad-zapped');
        });
    })();
    """

    // MARK: - Reading Mode (⇧⌘R)
    static let extractReaderArticle = """
    (function() {
        const title = document.querySelector('h1')?.innerText || document.title || 'Untitled';
        const bylineEl = document.querySelector('[rel="author"], .byline, .author, time, .date');
        const byline = bylineEl ? bylineEl.innerText.trim() : '';
        const siteName = document.querySelector('meta[property="og:site_name"]')?.content || window.location.hostname;

        const candidate = document.querySelector('article, [role="article"], main, .article-body, .post-content') || document.body;
        const pEls = Array.from(candidate.querySelectorAll('p'));
        const paragraphs = pEls
            .map(p => p.innerText.trim())
            .filter(t => t.length > 35 && !t.includes('Cookie') && !t.includes('Privacy Policy'));

        const totalWords = paragraphs.reduce((sum, p) => sum + p.split(/\\s+/).length, 0);
        const readingTime = Math.max(1, Math.round(totalWords / 200));

        return {
            title: title,
            byline: byline,
            siteName: siteName,
            paragraphs: paragraphs,
            wordCount: totalWords,
            readingTime: readingTime
        };
    })();
    """
}
