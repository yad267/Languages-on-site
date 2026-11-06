import SwiftUI

struct HomeView: View {
    @Bindable var repository: LessonRepository
    @Binding var path: NavigationPath
    @Binding var showCreateLesson: Bool

    var body: some View {
        List {
            Section {
                Text("Ireland · Site induction + Containment · A1–A2 · EN ↔ RU")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                Text(LessonStore.shared.lastStatusRU)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .listRowBackground(Color.clear)
            }

            if let next = LessonStore.shared.firstIncomplete {
                Section("Продолжить") {
                    NavigationLink(value: next) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(next.titleRu)
                                .font(.headline)
                            if let en = next.titleEn {
                                Text(en).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    showCreateLesson = true
                } label: {
                    Label("Новый урок", systemImage: "plus.circle.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section {
                NavigationLink {
                    TranslateView()
                } label: {
                    Label("Перевод", systemImage: "character.book.closed")
                        .font(.headline)
                        .padding(.vertical, 8)
                }
            }

            Section("Path") {
                ForEach(repository.lessons) { lesson in
                    NavigationLink(value: lesson) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(lesson.titleRu)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                if LessonProgressStore.isCompleted(lesson.id) {
                                    Text("✓")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.green)
                                }
                                if lesson.isSiteInduction {
                                    Text("Site induction")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.18))
                                        .foregroundStyle(.tint)
                                        .clipShape(Capsule())
                                } else if lesson.tags.contains("containment") {
                                    Text("Containment")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.18))
                                        .foregroundStyle(.tint)
                                        .clipShape(Capsule())
                                }
                                if lesson.isUserLesson {
                                    Text("Мой")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.orange.opacity(0.2))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                }
                            }

                            if let titleEn = lesson.titleEn, !titleEn.isEmpty {
                                Text(titleEn)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }

                            Text(lesson.sceneRu)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            HStack(spacing: 8) {
                                ForEach(lesson.tags.filter { $0 != "induction" }, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.accentColor.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if lesson.isUserLesson {
                            Button(role: .destructive) {
                                try? repository.deleteUser(id: lesson.id)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Уроки")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { repository.reload() }
    }
}
