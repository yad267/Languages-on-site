import SwiftUI

/// Репетитор hub: сегмент На объекте | Обычный EN → Поговорить / Упражнения / Лист.
struct SiteTutorView: View {
    private enum Route: Hashable {
        case talk(topic: String?)
        case why(seed: String?)
        case exercises
        case speakDrill
        case pairsOpposites
        case pairsPhrasal
        case printSheet
        case roleplay
    }

    @State private var path = NavigationPath()
    @State private var contentMode: TutorContentMode = .site

    private var topicChips: [String] {
        switch contentMode {
        case .site:
            return [
                "Safe Pass", "PPE", "Containment", "Tools", "CCTV", "Induction",
            ] + TutorTopicBank.makeChips().filter {
                !["Safe Pass", "PPE", "Containment", "Tools", "CCTV", "Induction"].contains($0)
            }.prefix(4)
        case .general:
            return [
                "Home", "Food", "Travel", "Work office", "Shopping", "Feelings", "Phone",
                "Friends", "Daily routine", "Weather",
            ]
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Режим", selection: $contentMode) {
                        ForEach(TutorContentMode.allCases) { mode in
                            Text(mode.titleRU).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: contentMode) { _, mode in
                        TutorBankStore.setMode(mode)
                        path = NavigationPath()
                    }

                    Text(contentMode == .site ? "Чем займёмся на объекте?" : "Обычный английский — быт, еда, поездки")
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(contentMode == .site
                         ? "A1–A2 · Ireland site · задача → речь → правка"
                         : "A1–A2 · general EN · те же упражнения, другие банки")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    modeButton(
                        title: "Поговорить",
                        subtitle: contentMode == .site
                            ? "AI site-buddy · сразу даёт фразу"
                            : "Бытовые темы · без Safe Pass / tray",
                        systemImage: "bubble.left.and.bubble.right.fill",
                        accent: Color.accentColor
                    ) { path.append(Route.talk(topic: nil)) }

                    modeButton(
                        title: "Упражнения",
                        subtitle: "Говорить · Писать · Пары · Формы · поиск take…",
                        systemImage: "square.grid.2x2.fill",
                        accent: .teal
                    ) { path.append(Route.exercises) }

                    modeButton(
                        title: "Лист на печать",
                        subtitle: contentMode == .site
                            ? "Рукопись A4 · фото → проверка"
                            : "Бытовые глаголы / phrasal · A4",
                        systemImage: "printer.fill",
                        accent: .orange
                    ) { path.append(Route.printSheet) }

                    modeButton(
                        title: "Roleplay",
                        subtitle: "Импорт диалога · Loop Mode",
                        systemImage: "person.2.wave.2",
                        accent: .indigo
                    ) { path.append(Route.roleplay) }

                    Text("Темы")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(topicChips.prefix(12)), id: \.self) { topic in
                                Button(topic) {
                                    path.append(Route.talk(topic: topic))
                                }
                                .buttonStyle(.bordered)
                                .font(.subheadline.weight(.semibold))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { NavChrome.dismissKeyboard() }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Репетитор")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .talk(let topic):
                    TutorTalkView(initialTopic: topic, contentMode: contentMode) { whySeed in
                        path.append(Route.why(seed: whySeed))
                    }
                case .why(let seed):
                    TutorWhyView(initialQuestion: seed)
                case .exercises:
                    TutorExercisesHubView(contentMode: contentMode)
                case .speakDrill:
                    TutorSpeakDrillView()
                case .pairsOpposites:
                    TutorPairsView(mode: .opposites)
                case .pairsPhrasal:
                    TutorPairsView(mode: .phrasal)
                case .printSheet:
                    TutorPrintSheetView(contentMode: contentMode)
                case .roleplay:
                    RoleplayHubEmbeddedView()
                }
            }
            .onAppear {
                TutorBankStore.setMode(contentMode)
            }
            #if DEBUG
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-EOSOpenTutorGeneral") {
                    contentMode = .general
                    TutorBankStore.setMode(.general)
                }
                if args.contains("-EOSOpenTutorTalk") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        path.append(Route.talk(topic: nil))
                    }
                } else if args.contains("-EOSOpenTutorSpeak") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        path.append(Route.speakDrill)
                    }
                } else if args.contains("-EOSOpenTutorOpposites") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        path.append(Route.pairsOpposites)
                    }
                } else if args.contains("-EOSOpenTutorPhrasalPairs") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        path.append(Route.pairsPhrasal)
                    }
                } else if args.contains("-EOSOpenTutorPairs") || args.contains("-EOSOpenTutorSearch") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        path.append(Route.exercises)
                    }
                } else if args.contains("-EOSOpenRoleplay") || args.contains("-EOSRoleplayInjectTray") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        path.append(Route.roleplay)
                    }
                }
            }
            #endif
        }
    }

    private func modeButton(
        title: String,
        subtitle: String,
        systemImage: String,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 44, height: 44)
                    .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }
}

@MainActor
enum TutorTopicBank {
    static func makeChips() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !seen.contains(t.lowercased()) else { return }
            seen.insert(t.lowercased())
            out.append(t)
        }
        for lesson in LessonStore.shared.lessons.prefix(8) {
            if let en = lesson.titleEn, !en.isEmpty { add(en) }
            else { add(lesson.titleRu) }
        }
        return out
    }
}
