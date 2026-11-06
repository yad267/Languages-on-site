import SwiftUI

struct RoleplayLoopView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let script: RoleplayScript

    @State private var engine: RoleplayLoopEngine
    @State private var selectedSlot = "a"

    init(script: RoleplayScript) {
        self.script = script
        let defaultSlot = script.roles.first?.slot ?? "a"
        _engine = State(initialValue: RoleplayLoopEngine(script: script, userSlot: defaultSlot))
        _selectedSlot = State(initialValue: defaultSlot)
    }

    var body: some View {
        @Bindable var engine = engine
        VStack(spacing: 0) {
            rolePicker
                .padding()
                .background(Color(.secondarySystemBackground))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(script.sceneRu)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(engine.statusRU)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)

                    if let line = engine.currentLine {
                        lineCard(line, highlight: engine.phase == .waitingUser || engine.phase == .playingOpponent)
                    } else if engine.phase == .idle {
                        Text("Выбери роль и жми Старт. Сценарий крутится, пока не нажмёшь Стоп.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(Array(script.lines.enumerated()), id: \.element.id) { idx, line in
                        HStack(alignment: .top) {
                            Circle()
                                .fill(idx == engine.lineIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(width: 8, height: 8)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.role)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                                Text(line.en)
                                    .font(.subheadline)
                                    .opacity(idx == engine.lineIndex ? 1 : 0.55)
                            }
                        }
                    }
                }
                .padding()
            }

            controls
                .padding()
                .background(.ultraThinMaterial)
        }
        .navigationTitle(script.titleRu)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    engine.stop()
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                            .font(.body.weight(.semibold))
                        Text("Назад")
                            .font(.body.weight(.semibold))
                    }
                    .frame(minHeight: 44)
                }
            }
        }
        .onDisappear { engine.stop() }
    }

    private var rolePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Твоя роль")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Роль", selection: $selectedSlot) {
                ForEach(script.roles) { role in
                    Text(role.name).tag(role.slot)
                }
            }
            .pickerStyle(.segmented)
            .disabled(engine.phase != .idle && engine.phase != .finished)
            .onChange(of: selectedSlot) { _, new in
                engine.setUserSlot(new)
            }

            Toggle("Озвучивать и мои реплики", isOn: $engine.speakUserLines)
                .font(.subheadline)
        }
    }

    private func lineCard(_ line: RoleplayLine, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(line.role)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(line.en)
                .font(.title3.weight(.semibold))
            Text(line.ru)
                .font(.body)
                .foregroundStyle(.secondary)
            if let tip = line.tipRu, !tip.isEmpty {
                Text(tip)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if engine.phase == .waitingUser {
                Text("Скажи вслух для себя → «Готово». STT-зачёт здесь пока нет (в Тренажёре / Поговорить — есть).")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(highlight ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground))
        )
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if engine.phase == .idle || engine.phase == .finished {
                Button {
                    engine.setUserSlot(selectedSlot)
                    engine.start(settings: settings)
                } label: {
                    Text("Старт · Loop")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
            } else {
                if engine.phase == .waitingUser {
                    Button {
                        engine.confirmUserTurn()
                    } label: {
                        Text("Готово")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(role: .destructive) {
                    engine.stop()
                } label: {
                    Text("Стоп")
                        .font(.headline)
                        .frame(minWidth: 96, minHeight: 52)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
