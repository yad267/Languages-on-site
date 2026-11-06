import SwiftUI
import SwiftData

@main
struct EnglishOnSiteApp: App {
    @State private var settings = AppSettings()
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: LibraryItem.self)
        } catch {
            // Schema evolve (B17b/B20 fields) — reset local library store once, keep app bootable.
            if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                for name in names where name.contains(".store") {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                }
            }
            do {
                container = try ModelContainer(for: LibraryItem.self)
            } catch {
                fatalError("SwiftData container failed: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .onAppear {
                    let seedMsg = AppSecrets.seedKeychainIfNeeded(into: settings)
                    settings.geminiAPIKeyDraft = KeychainStore.loadGeminiAPIKey()
                    settings.elevenLabsAPIKeyDraft = KeychainStore.loadElevenLabsAPIKey()
                    print("[secrets] \(seedMsg)")
                    print("[secrets] \(AppSecrets.settingsStatusLine)")
                    PhoneWatchBridge.shared.configure(settings: settings, container: container)
                    LessonRepository.shared.reload()
                    Task { @MainActor in
                        await LessonStore.shared.checkForUpdatesIfNeeded(settings: settings)
                        LessonRepository.shared.reload()
                    }
                    #if DEBUG
                    let fails = ElevenLabsAudioCache.selfCheckFailures()
                    if fails.isEmpty {
                        print("[el] cache selfCheck OK")
                    } else {
                        print("[el] cache selfCheck FAIL: \(fails.joined(separator: "; "))")
                    }
                    let simFails = PhraseSimilarity.selfCheckFailures()
                    if simFails.isEmpty {
                        print("[PhraseSimilarity] selfCheck OK (incl. twenty vs 20)")
                    } else {
                        print("[PhraseSimilarity] selfCheck FAIL:\n" + simFails.joined(separator: "\n"))
                    }
                    let pathLessons = LessonStore.shared.lessons
                    let pathIds = pathLessons.map(\.id)
                    print("[path] pack v\(LessonStore.shared.contentVersion) count=\(pathLessons.count) src=\(LessonStore.shared.sourceLabel)")
                    print("[path] ids=\(pathIds.joined(separator: ","))")
                    let expectedPrefix = ["lesson_0_1_safe_pass", "lesson_0_2_induction", "lesson_0_3_ppe", "lesson_1_1_tray_basket"]
                    if Array(pathIds.prefix(4)) != expectedPrefix || pathIds.count < 9 {
                        print("[path] FAIL expected 0.1–1.6 pack")
                    } else {
                        print("[path] OK 0.1–1.6")
                    }
                    if ProcessInfo.processInfo.environment["EOS_SMOKE_EL"] == "1" {
                        Task { @MainActor in
                            let reread = settings.rereadSecretsFromDisk()
                            print("[secrets] smoke reread: \(reread)")
                            settings.migrateELFactoryIfNeeded()
                            let cleared = ElevenLabsAudioCache.clearAll()
                            print("[el] smoke clear cache removed=\(cleared) model=\(settings.elModel.rawValue)")
                            let phraseRU = "Проверь кабель и заземление."
                            let params = settings.elVoiceParams(for: .ru)
                            print("[el] smoke RU params model=\(params.model.rawValue) stab=\(String(format: "%.2f", params.stability)) sim=\(String(format: "%.2f", params.similarityBoost)) style=\(String(format: "%.2f", params.style)) voice=\(SiteVoiceLang.ru.voiceId.prefix(6))…")
                            await ElevenLabsTTS.shared.speak(
                                text: phraseRU,
                                lang: .ru,
                                settings: settings
                            )
                            print("[el] smoke RU status=\(ElevenLabsTTS.shared.lastStatusRU) source=\(ElevenLabsTTS.shared.lastSource.rawValue) system=\(ElevenLabsTTS.shared.lastUsedSystemVoice)")
                        }
                    }
                    #endif
                }
                .onChange(of: settings.useGemini) { _, _ in
                    PhoneWatchBridge.shared.pushSettings()
                }
                .onChange(of: settings.englishSpeed) { _, _ in
                    PhoneWatchBridge.shared.pushSettings()
                }
                .onChange(of: settings.rememberDuration) { _, _ in
                    PhoneWatchBridge.shared.pushSettings()
                }
                .onChange(of: settings.translateDuration) { _, _ in
                    PhoneWatchBridge.shared.pushSettings()
                }
        }
        .modelContainer(container)
    }
}
