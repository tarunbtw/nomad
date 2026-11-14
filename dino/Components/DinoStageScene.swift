//
//  DinoStageScene.swift
//  dino
//
//  Created for Dino Browser.
//  Quiet, atmospheric ambient stage for empty tabs and browser backdrop.
//  Deep pine palette (#023121) with soft ambient light, Daniel Linssen-inspired
//  celestial stars, and zero CPU idle draw.
//

import SwiftUI
import AppKit

struct DinoStageScene: View {
    let spaceColor: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(spaceColor: String = "pine") {
        self.spaceColor = spaceColor
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DinoSkyCanvas(spaceColor: spaceColor)

                // Soft ambient watermark mark
                if let _ = NSImage(named: "DinoMark") {
                    Image("DinoMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .opacity(0.18)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }

                if let _ = NSImage(named: "FirstLightGrain") {
                    Image("FirstLightGrain")
                        .resizable(resizingMode: .tile)
                        .opacity(0.20)
                        .blendMode(.softLight)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Theme.page)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DinoSkyCanvas: View {
    let spaceColor: String

    var body: some View {
        Canvas { context, size in
            let (w, h) = (size.width, size.height)
            let rect = CGRect(origin: .zero, size: size)

            // Deep pine base gradient
            let topColor = Color(hex: 0x022519)
            let bottomColor = Color(hex: 0x023121)

            context.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: topColor, location: 0),
                        .init(color: bottomColor, location: 1.0)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: h)
                )
            )

            // Space-tinted soft radial glow in upper-center
            let tint = Theme.FirstLight.spaceHex(spaceColor)
            let glowColor = Color(hex: tint, opacity: 0.12)
            let glowRect = CGRect(x: w * 0.2, y: -h * 0.1, width: w * 0.6, height: h * 0.7)
            context.fill(
                Path(ellipseIn: glowRect),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: glowColor, location: 0),
                        .init(color: glowColor.opacity(0), location: 0.8)
                    ]),
                    center: CGPoint(x: glowRect.midX, y: glowRect.midY),
                    startRadius: 0,
                    endRadius: glowRect.width / 2
                )
            )

            // Minimalist Planetarium stars (static seed, zero CPU)
            for i in 0..<36 {
              let sx = CGFloat((i * 73 + (i * i * 19)) % Int(max(1, w)))
              let sy = CGFloat((i * 47) % Int(max(1, h * 0.75)))
              let sSize: CGFloat = (i % 6 == 0) ? 2.0 : 1.0
              let sAlpha: Double = (i % 4 == 0) ? 0.35 : 0.18
              let starRect = CGRect(x: sx, y: sy, width: sSize, height: sSize)
              context.fill(Path(starRect), with: .color(Color(hex: 0xFFE5CC, opacity: sAlpha)))
            }
        }
    }
}
