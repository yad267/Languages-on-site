import SwiftUI

/// Уроки only: Onsite Language | Regular Language → subsections → 10–15 lessons.
/// Does not own other tabs.
struct HomeView: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var repository: LessonRepository
    @Binding var path: NavigationPath
    @Binding var showCreateLesson: Bool

    private var mode: AppLearningMode { settings.learningMode }

    private var userDialogues: [Lesson] {
        repository.lessons.filter {
            $0.tags.contains("general") || $0.createdBy == "user_gemini_general"
        }
    }

    var body: some View {
        List {
            Section {
                LearningModePicker(mode: Bindable(settings).learningMode)
            } header: {
                Text("Уроки")
            }

            if mode == .onSite {
                onsiteSections
            } else {
                regularSections
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, 12, for: .scrollContent)
        .safeAreaPadding(.bottom, 8)
        .navigationTitle(mode == .onSite ? "Onsite Language" : "Regular Language")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            // Avoid re-decoding the whole lesson pack on every return to this tab.
            TutorBankStore.setMode(mode == .onSite ? .site : .general)
        }
        .onChange(of: settings.learningMode) { _, newMode in
            TutorBankStore.setMode(newMode == .onSite ? .site : .general)
        }
    }

    @ViewBuilder
    private var onsiteSections: some View {
        Section("Разделы · Onsite") {
            ForEach(SectionLessonStore.sections(track: .onSite)) { sec in
                NavigationLink {
                    SectionLessonsListView(track: .onSite, section: sec)
                } label: {
                    sectionLabel(sec)
                }
            }
        }

        Section {
            Button {
                showCreateLesson = true
            } label: {
                Label("Новый урок · объект (Gemini)", systemImage: "plus.circle.fill")
            }
        }
    }

    @ViewBuilder
    private var regularSections: some View {
        Section("Разделы · Regular") {
            ForEach(SectionLessonStore.sections(track: .regular)) { sec in
                NavigationLink {
                    SectionLessonsListView(track: .regular, section: sec)
                } label: {
                    sectionLabel(sec)
                }
            }
        }

        Section("Своя тема") {
            NavigationLink {
                RegularLanguageRequestView(preferredLevel: .a2) { lessons in
                    repository.reload()
                    if let first = lessons.first {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            path.append(first)
                        }
                    }
                }
            } label: {
                Label("Голос или текст → до 10 диалогов", systemImage: "mic.badge.plus")
            }
            Text("Пример: «I want dating dialogues».")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !userDialogues.isEmpty {
            Section("Мои собранные диалоги") {
                ForEach(userDialogues) { lesson in
                    NavigationLink(value: lesson) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lesson.titleRu).font(.headline)
                            Text(lesson.sceneRu)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func sectionLabel(_ sec: LessonSectionInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sec.titleRu).font(.headline)
            Text(sec.titleEn)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(sec.lessonCount) уроков")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

struct SectionLessonsListView: View {
    let track: AppLearningMode
    let section: LessonSectionInfo
    @State private var band: CEFRLevel.Band = .all

    private var allLessons: [Lesson] {
        SectionLessonStore.lessons(sectionId: section.id, track: track)
    }

    private var lessons: [Lesson] {
        allLessons.filter { band.contains($0.cefrLevel) }
    }

    var body: some View {
        List {
            Section {
                Text(track == .onSite
                     ? "Onsite · только этот раздел"
                     : "Regular · только этот раздел")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Уровень", selection: $band) {
                    ForEach(CEFRLevel.Band.allCases) { b in
                        Text(b.titleRU).tag(b)
                    }
                }
                .pickerStyle(.segmented)
                Text(band.subtitleRU)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Section("Уроки · \(lessons.count)") {
                if lessons.isEmpty {
                    Text("Пока нет уроков для \(band.titleRU). Выбери «Все» или другой уровень.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(lessons) { lesson in
                    // Destination link (not value:/path): section was pushed with
                    // NavigationLink { … }, so value-based Lesson pushes bounce back
                    // to this menu instead of opening PlayerView.
                    NavigationLink {
                        PlayerView(lesson: lesson)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(lesson.titleRu).font(.headline)
                                if let cefr = lesson.cefr, !cefr.isEmpty {
                                    Text(cefr)
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(Color.accentColor.opacity(0.15))
                                        )
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            if let en = lesson.titleEn {
                                Text(en).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(lesson.sceneRu)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                            if let first = lesson.lines.first?.en, !first.isEmpty {
                                Text(first)
                                    .font(.caption2)
                                    .foregroundStyle(.quaternary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, 12, for: .scrollContent)
        .safeAreaPadding(.bottom, 8)
        .navigationTitle(section.titleRu)
        .navigationBarTitleDisplayMode(.inline)
    }
}
