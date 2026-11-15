import SwiftUI
import SwiftData

private enum LessonsRoute: Hashable {
    case translate
}

struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @State private var lessonsPath = NavigationPath()
    @State private var repository = LessonRepository.shared
    @State private var showCreateLesson = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $lessonsPath) {
                HomeView(
                    repository: repository,
                    path: $lessonsPath,
                    showCreateLesson: $showCreateLesson
                )
                .navigationDestination(for: Lesson.self) { lesson in
                    PlayerView(lesson: lesson)
                }
                .navigationDestination(for: LessonsRoute.self) { route in
                    switch route {
                    case .translate:
                        TranslateView()
                    }
                }
                #if DEBUG
                .onAppear {
                    let args = ProcessInfo.processInfo.arguments
                    if args.contains("-EOSOpenLesson11") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            if let lesson = LessonStore.shared.lessons.first(where: { $0.id == "lesson_1_1_tray_basket" }) {
                                lessonsPath.append(lesson)
                            }
                        }
                    } else if args.contains("-EOSOpenLesson") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            if let lesson = LessonStore.shared.lessons.first {
                                lessonsPath.append(lesson)
                            }
                        }
                    }
                }
                #endif
            }
            .tabItem {
                Label("Уроки", systemImage: "list.bullet.rectangle")
            }
            .tag(0)
            .sheet(isPresented: $showCreateLesson) {
                CreateLessonView { lesson in
                    repository.reload()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        lessonsPath.append(lesson)
                    }
                }
                .presentationDragIndicator(.visible)
            }

            // Translator at root (1 tap). Phrasal board remains under Репетитор → Пары.
            NavigationStack {
                TranslateView(isRootTab: true)
            }
            .tabItem {
                Label("Переводчик", systemImage: "globe")
            }
            .tag(1)

            // B17: Мои фразы (= former Library)
            NavigationStack {
                LibraryView()
            }
            .tabItem {
                Label("Мои фразы", systemImage: "text.book.closed")
            }
            .tag(2)

            SiteTutorView()
                .tabItem {
                    Label("Репетитор", systemImage: "bubble.left.and.text.bubble.right")
                }
                .tag(3)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Настройки", systemImage: "gearshape.fill")
            }
            .tag(4)
        }
        .onChange(of: selectedTab) { _, _ in
            NavChrome.dismissKeyboard()
        }
        .onAppear {
            TutorBankStore.setMode(settings.learningMode.tutorMode)
        }
        .onChange(of: settings.learningMode) { _, mode in
            TutorBankStore.setMode(mode.tutorMode)
        }
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-EOSOpenTutor") {
                selectedTab = 3
            } else if args.contains("-EOSOpenTranslate") || args.contains("-EOSOpenPhrasalTab") {
                // -EOSOpenPhrasalTab kept as alias → translator tab (phrasal lives under Репетитор).
                selectedTab = 1
            } else if args.contains("-EOSOpenMyPhrases") {
                selectedTab = 2
            }
        }
        #endif
    }
}

#Preview {
    ContentView()
        .environment(AppSettings())
        .modelContainer(for: LibraryItem.self, inMemory: true)
}
