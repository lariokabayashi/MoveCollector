//
//  Theme.swift
//  MotionApp
//
//  Design system centralizado do Move Collector.
//
//  Fonte unica de verdade para cores da marca, superficies do dark mode e o
//  visual dos cards. O app roda em dark mode fixo (ver MotionAppApp), entao os
//  tokens de superficie usam valores escuros fixos — sem variantes light.
//
//  Regra: NAO usar cores semanticas cruas (.blue, .green, .red...) espalhadas
//  pelas views. Sempre referencie os tokens daqui (brandLime, brandGreen,
//  brandBlue, brandRed) e o modificador `.cardStyle()`.
//

import SwiftUI

extension Color {
    /// Inicializa a partir de um hex RGB de 6 digitos (ex.: 0xB7F701 ou "#B7F701").
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    // MARK: - Cores da marca (papeis semanticos)

    /// #B7F701 — acao primaria / accent (casa com o AccentColor do asset catalog).
    static let brandLime = Color(hex: 0xB7F701)
    /// #0C7C02 — sucesso / estados positivos.
    static let brandGreen = Color(hex: 0x0C7C02)
    /// #0136FE — acao secundaria / informacao.
    static let brandBlue = Color(hex: 0x0136FE)
    /// #F00000 — destrutivo / gravacao em andamento.
    static let brandRed = Color(hex: 0xF00000)

    // MARK: - Superficies (dark-only, valores fixos)

    /// Fundo base das telas (a camada mais escura, atras dos cards).
    static let appBackground = Color(hex: 0x0E0E10)
    /// Superficie elevada dos cards — levemente mais clara que o fundo base
    /// para criar a separacao visual que a sombra sozinha nao dava no dark mode.
    static let cardSurface = Color(hex: 0x1C1C1E)
    /// Borda hairline dos cards: garante uma delimitacao visivel mesmo quando
    /// card e fundo tem luminosidade parecida.
    static let cardBorder = Color.white.opacity(0.08)

    /// Cor de texto/icone sobre a lima. Texto branco sobre #B7F701 tem contraste
    /// ruim, entao usamos quase-preto sobre o accent.
    static let onAccent = Color(hex: 0x0E0E10)
}

// MARK: - Card style

/// Estilo padrao de card do app: padding + superficie elevada + borda hairline
/// + sombra sutil de reforco. Fonte unica de verdade do visual dos cards.
@available(iOS 15.0, *)
struct CardStyle: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding()
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.cardBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
    }
}

@available(iOS 15.0, *)
extension View {
    /// Aplica o visual padrao de card do app (superficie + borda + sombra).
    func cardStyle(cornerRadius: CGFloat = 16) -> some View {
        modifier(CardStyle(cornerRadius: cornerRadius))
    }
}
