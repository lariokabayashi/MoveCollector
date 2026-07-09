//
//  OnboardingView.swift
//  MotionApp
//
//  Tutorial "How to use this app" exibido no primeiro uso (e reabrível pelo
//  botão de ajuda na barra superior). Explica, em poucas telas, o que o app
//  faz e o fluxo básico de uso.
//

import SwiftUI

@available(iOS 26.0, *)
struct OnboardingView: View {

    /// Chamado quando o usuário conclui ou pula o tutorial.
    var onFinish: () -> Void

    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            systemImage: "figure.walk.motion",
            title: "Bem-vindo ao Move Collector",
            message: "O app registra seus movimentos em segundo plano usando os sensores do iPhone e monta automaticamente os blocos do seu trajeto."
        ),
        OnboardingPage(
            systemImage: "play.circle.fill",
            title: "Inicie a coleta",
            message: "Toque em \"Parar coleta / Iniciar coleta\" para ligar e desligar o registro. Pode deixar rodando enquanto se move pelo dia."
        ),
        OnboardingPage(
            systemImage: "chart.bar.xaxis",
            title: "Veja seus episódios",
            message: "Ao parar, toque em \"Processar\" para dividir a sessão em episódios de movimento. Abra o mapa e o gráfico para visualizar cada trecho."
        ),
        OnboardingPage(
            systemImage: "mic.fill",
            title: "Rotule por voz",
            message: "Toque no microfone de um episódio e grave uma nota curta (ex.: \"corrida no parque\"). O app transcreve e usa como rótulo automaticamente."
        ),
        OnboardingPage(
            systemImage: "lock.shield.fill",
            title: "Seus dados ficam no iPhone",
            message: "Todo o processamento acontece no dispositivo. Nada é enviado para servidores — sua privacidade em primeiro lugar."
        )
    ]

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button("Pular") { onFinish() }
                    .font(.subheadline)
                    .padding()
            }

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(pages[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < pages.count - 1 ? "Continuar" : "Começar")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Color.onAccent)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
        }
        .background(Color.appBackground.ignoresSafeArea())
    }

    @ViewBuilder
    private func pageView(_ page: OnboardingPage) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: page.systemImage)
                .font(.system(size: 84))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text(page.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(page.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .padding()
    }
}

private struct OnboardingPage {
    let systemImage: String
    let title: String
    let message: String
}

@available(iOS 26.0, *)
#Preview {
    OnboardingView(onFinish: {})
}

