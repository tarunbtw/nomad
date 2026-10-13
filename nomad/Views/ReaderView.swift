//
//  ReaderView.swift
//  nomad
//
//  Created by tarun on 13/10/26.
//

import SwiftUI
import AppKit

/// Data model representing an extracted article for distraction-free reading.
struct ReaderArticle: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let byline: String
    let siteName: String
    let paragraphs: [String]
    let wordCount: Int
    let readingTimeMinutes: Int
    let url: URL?

    static func == (lhs: ReaderArticle, rhs: ReaderArticle) -> Bool {
        lhs.id == rhs.id
    }
}

/// Distraction-free typography-first Reader View for Nomad (⌘⇧R).
struct ReaderView: View {
    let article: ReaderArticle
    let onClose: () -> Void

    @AppStorage("nomad.reader.fontSize") private var fontSize: Double = 17
    @AppStorage("nomad.reader.isSerif") private var isSerif: Bool = true
    @AppStorage("nomad.reader.theme") private var themeRaw: String = "system"

    enum ReaderTheme: String, CaseIterable {
        case system = "System"
        case paper = "Warm"
        case dark = "Dark"

        var bg: Color {
            switch self {
            case .system: return Color(nsColor: .windowBackgroundColor)
            case .paper: return Color(red: 0.98, green: 0.96, blue: 0.92)
            case .dark: return Color(red: 0.11, green: 0.11, blue: 0.12)
            }
        }

        var text: Color {
            switch self {
            case .system: return Color(nsColor: .textColor)
            case .paper: return Color(red: 0.20, green: 0.17, blue: 0.14)
            case .dark: return Color(red: 0.92, green: 0.92, blue: 0.92)
            }
        }

        var secondaryText: Color {
            switch self {
            case .system: return Color(nsColor: .secondaryLabelColor)
            case .paper: return Color(red: 0.46, green: 0.40, blue: 0.35)
            case .dark: return Color(red: 0.65, green: 0.65, blue: 0.68)
            }
        }

        var tertiaryText: Color {
            switch self {
            case .system: return Color(nsColor: .tertiaryLabelColor)
            case .paper: return Color(red: 0.58, green: 0.52, blue: 0.46)
            case .dark: return Color(red: 0.50, green: 0.50, blue: 0.54)
            }
        }

        var controlBg: Color {
            switch self {
            case .system: return Color.primary.opacity(0.06)
            case .paper: return Color(red: 0.20, green: 0.17, blue: 0.14).opacity(0.07)
            case .dark: return Color.white.opacity(0.08)
            }
        }

        var divider: Color {
            switch self {
            case .system: return Color.primary.opacity(0.10)
            case .paper: return Color(red: 0.20, green: 0.17, blue: 0.14).opacity(0.12)
            case .dark: return Color.white.opacity(0.12)
            }
        }
    }

    private var currentTheme: ReaderTheme {
        ReaderTheme(rawValue: themeRaw) ?? .system
    }

    var body: some View {
        ZStack {
            // Background
            currentTheme.bg
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Reader Top Bar
                HStack(spacing: 16) {
                    Button(action: onClose) {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Done")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(currentTheme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(currentTheme.controlBg, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Close Reading Mode (Esc or ⌘⇧R)")

                    Spacer()

                    // Theme selector
                    HStack(spacing: 4) {
                        ForEach(ReaderTheme.allCases, id: \.self) { th in
                            Button(action: { themeRaw = th.rawValue }) {
                                Circle()
                                    .fill(th.bg)
                                    .frame(width: 16, height: 16)
                                    .overlay(Circle().stroke(currentTheme == th ? Color.accentColor : currentTheme.secondaryText.opacity(0.3), lineWidth: currentTheme == th ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .help("\(th.rawValue) paper theme")
                        }
                    }

                    Rectangle()
                        .fill(currentTheme.divider)
                        .frame(width: 1, height: 14)

                    // Serif / Sans toggle
                    Button(action: { isSerif.toggle() }) {
                        Text(isSerif ? "Serif" : "Sans")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(currentTheme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(currentTheme.controlBg, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Toggle typeface")

                    // Font size adjustments
                    HStack(spacing: 2) {
                        Button(action: { fontSize = max(13, fontSize - 1) }) {
                            Text("A-")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(currentTheme.secondaryText)
                                .frame(width: 24, height: 22)
                        }
                        .buttonStyle(.plain)
                        .disabled(fontSize <= 13)

                        Button(action: { fontSize = min(28, fontSize + 1) }) {
                            Text("A+")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(currentTheme.secondaryText)
                                .frame(width: 24, height: 22)
                        }
                        .buttonStyle(.plain)
                        .disabled(fontSize >= 28)
                    }
                    .padding(.horizontal, 2)
                    .background(currentTheme.controlBg, in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(currentTheme.bg.opacity(0.95))

                Rectangle()
                    .fill(currentTheme.divider)
                    .frame(height: 1)

                // Article Content Scroll View
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 22) {
                        // Title
                        Text(article.title)
                            .font(isSerif ? .system(size: fontSize * 1.6, weight: .bold, design: .serif) : .system(size: fontSize * 1.6, weight: .bold))
                            .foregroundStyle(currentTheme.text)
                            .lineSpacing(4)
                            .padding(.top, 28)

                        // Metadata byline & read time
                        HStack(spacing: 12) {
                            if !article.byline.isEmpty {
                                Text(article.byline)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(currentTheme.secondaryText)
                            }

                            if !article.siteName.isEmpty {
                                Text("•  " + article.siteName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(currentTheme.tertiaryText)
                            }

                            Text("•  \(article.readingTimeMinutes) min read")
                                .font(.system(size: 12))
                                .foregroundStyle(currentTheme.secondaryText)
                        }
                        .padding(.bottom, 8)

                        Rectangle()
                            .fill(currentTheme.divider)
                            .frame(height: 1)

                        // Paragraphs
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(article.paragraphs.enumerated()), id: \.offset) { _, para in
                                Text(para)
                                    .font(isSerif ? .system(size: fontSize, design: .serif) : .system(size: fontSize))
                                    .lineSpacing(CGFloat(fontSize * 0.45))
                                    .foregroundStyle(currentTheme.text)
                            }
                        }
                        .padding(.bottom, 64)
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .preferredColorScheme(currentTheme == .dark ? .dark : (currentTheme == .paper ? .light : nil))
    }
}
