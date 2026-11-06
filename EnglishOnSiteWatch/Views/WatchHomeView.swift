import SwiftUI

struct WatchHomeView: View {
    @Environment(WatchAppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.status.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(model.phoneConnected ? "iPhone" : "Solo")
                        .font(.caption2)
                        .foregroundStyle(model.phoneConnected ? .green : .orange)
                    Text(model.sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if model.status == .listening {
                    Text(model.capture.secondsLeft > 0 ? "\(model.capture.secondsLeft)" : "…")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                    if !model.capture.partialText.isEmpty {
                        Text(model.capture.partialText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Button {
                    model.tapListen()
                } label: {
                    Text("Слушаю")
                        .font(.system(size: 20, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)

                if !model.enText.isEmpty {
                    Text(model.enText)
                        .font(.system(size: 18, weight: .bold))
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(model.ruText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)

                    if !model.tipText.isEmpty {
                        Text(model.tipText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !model.transcript.isEmpty {
                    Text(model.transcript)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                if model.speaker.isSpeaking || model.status == .speaking {
                    Button("Стоп речь") { model.stopSpeech() }
                        .font(.caption.weight(.semibold))
                }

                HStack(spacing: 6) {
                    small("Перевод") { model.tapTranslate() }
                    small("Запомни") { model.tapRemember() }
                }
                HStack(spacing: 6) {
                    small("Повтор") { model.tapReview() }
                    small("Стоп") { model.tapStopLesson() }
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear { model.refreshConnection() }
    }

    private func small(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.bordered)
    }
}
