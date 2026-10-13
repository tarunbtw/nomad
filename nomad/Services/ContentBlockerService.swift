//
//  ContentBlockerService.swift
//  nomad
//
//  Created by tarun on 13/10/26.
//

import Foundation
import WebKit
import Combine

/// Native network-level content and ad blocker using Apple's WKContentRuleListStore.
/// Executes at WebKit C++ engine level with 0% JS overhead and zero network requests for trackers.
/// Uses strict third-party scoping so extensions (like uBlock Origin) and first-party players (YouTube) remain 100% functional.
@MainActor
final class ContentBlockerService: ObservableObject {
    static let shared = ContentBlockerService()

    @Published private(set) var isReady: Bool = false
    @Published var isEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "nomad.adblocker.enabled")
        }
    }

    private var compiledRuleList: WKContentRuleList?
    private let ruleListIdentifier = "nomad.native.blocker.v2"

    /// Known third-party tracker and ad networks.
    /// Strictly scoped to third-party loads so first-party scripts and streaming players are never disrupted.
    private static let unwantedDomains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com"
    ]

    /// Reliable advertisement cosmetic container selectors.
    private static let adSlots = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_\"]",
        "[id^=\"div-gpt-ad\"]", "[id^=\"taboola-\"]", "#taboola-below-article",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"amazon-adsystem\"]",
        ".ad-slot", ".ad-slot-container", ".top-banner-ad-container",
        ".ad-leaderboard", ".ad-billboard", ".ad-giga", ".ad-mpu", ".ad-mrec",
        ".ad-unit", ".adunit", ".adslot", ".dfp-ad", ".gpt-ad", ".w_ad",
        ".advertisement", ".ad-banner", ".sponsored-post"
    ]

    private init() {
        self.isEnabled = UserDefaults.standard.object(forKey: "nomad.adblocker.enabled") as? Bool ?? true
        loadOrCompileRules()
    }

    /// Attaches the native compiled rule list to a WKUserContentController
    func attach(to userContentController: WKUserContentController) {
        guard isEnabled, let list = compiledRuleList else { return }
        userContentController.add(list)
    }

    /// Removes the compiled rule list if disabled
    func detach(from userContentController: WKUserContentController) {
        guard let list = compiledRuleList else { return }
        userContentController.remove(list)
    }

    private func loadOrCompileRules() {
        guard let store = WKContentRuleListStore.default() else { return }

        // Look up existing compiled bytecode first for instantaneous startup
        store.lookUpContentRuleList(forIdentifier: ruleListIdentifier) { [weak self] list, _ in
            if let list = list {
                Task { @MainActor [weak self] in
                    self?.compiledRuleList = list
                    self?.isReady = true
                }
            } else {
                // Compile the curated rule set
                self?.compileRules(store: store)
            }
        }
    }

    private func compileRules(store: WKContentRuleListStore) {
        var rules: [[String: Any]] = Self.unwantedDomains.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": [
                    "url-filter": "^https?://([^/]+\\.)?\(escaped)",
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }

        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": Self.adSlots.joined(separator: ", ")],
        ])

        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }

        store.compileContentRuleList(forIdentifier: ruleListIdentifier, encodedContentRuleList: json) { [weak self] list, error in
            if let error = error {
                print("⚠️ [ContentBlockerService] Compilation error: \(error.localizedDescription)")
                return
            }
            Task { @MainActor [weak self] in
                self?.compiledRuleList = list
                self?.isReady = true
            }
        }
    }
}
