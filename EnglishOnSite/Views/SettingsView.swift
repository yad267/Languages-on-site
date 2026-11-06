import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var showGeminiKey = false
    @State private var showElevenKey = false
    @State private var secretsRereadNote = ""
    @State private var lessonsUpdateNote = ""

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Button {
                    Task { @MainActor in
                        lessonsUpdateNote = "Проверяю…"
                        let msg = await LessonStore.shared.checkForUpdates(settings: settings, quiet: false)
                        lessonsUpdateNote = msg
                        LessonRepository.shared.reload()
                    }
                } label: {
                    if LessonStore.shared.isChecking {
                        ProgressView()
                    } else {
                        Text("Обновить уроки")
                    }
                }
                if !lessonsUpdateNote.isEmpty {
                    Text(lessonsUpdateNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(LessonStore.shared.lastStatusRU.isEmpty ? "Локально: bundled/cache" : LessonStore.shared.lastStatusRU)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Уроки")
            } footer: {
                Text("Пакет подтягивается с Drive при старте (раз за сессию) и по кнопке. Прогресс галочек не сбрасывается.")
            }

            Section {
                TextField("https://…/webhook/…", text: $settings.eosSyncWebhookURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text("EOS sync webhook")
            } footer: {
                Text("Пусто = sync выключен. После нового EL TTS и обновления пакета уроков — POST JSON (type=tts_audio / lesson_pack). n8n → Drive — отдельной задачей.")
            }

            Section("Скорость EN") {
                Picker("Скорость", selection: $settings.englishSpeed) {
                    ForEach(EnglishSpeechSpeed.allCases) { speed in
                        Text(speed.titleRu).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Подсказки") {
                Toggle("Показывать tip_ru", isOn: $settings.showTips)
            }

            Section("Запись речи") {
                Picker("Макс. длина (Перевод / тема)", selection: $settings.translateDuration) {
                    ForEach(TranslateDuration.allCases) { d in
                        Text(d.titleRu).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                Text("Сам жмёшь «Готово», когда закончил говорить. Автостоп на максимуме.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Запомни") {
                Picker("Длительность", selection: $settings.rememberDuration) {
                    ForEach(RememberDuration.allCases) { d in
                        Text(d.titleRu).tag(d)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Распознавание", selection: $settings.rememberLocale) {
                    ForEach(RememberLocale.allCases) { loc in
                        Text(loc.titleRu).tag(loc)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Text(AppSecrets.settingsStatusLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(settings.hasElevenLabsKey && settings.useElevenLabs ? Color.secondary : Color.red)

                HStack {
                    Text(settings.hasElevenLabsKey ? "ключ сохранён (Keychain)" : "нет ключа")
                        .font(.subheadline)
                        .foregroundStyle(settings.hasElevenLabsKey ? Color.secondary : Color.red)
                    Spacer()
                    if AppSecrets.hasLocalElevenLabs {
                        Text("Ключи из Secrets")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }

                if AppSecrets.hasAnyLocal {
                    Button("Перечитать Secrets") {
                        secretsRereadNote = settings.rereadSecretsFromDisk()
                        print("[secrets] reread button: \(secretsRereadNote)")
                    }
                    if !secretsRereadNote.isEmpty {
                        Text(secretsRereadNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Голос ElevenLabs", isOn: $settings.useElevenLabs)
                    .disabled(!settings.hasElevenLabsKey)

                if settings.hasElevenLabsKey, !settings.useElevenLabs {
                    Text("Toggle выкл → будет робот (AVSpeech). Включи «Голос ElevenLabs».")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.red)
                }
                if !settings.hasElevenLabsKey {
                    Text("Нет ключа EL в Keychain. Проверь Secrets.local.swift и пересобери.")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.red)
                }

                if showElevenKey {
                    SecureField("ElevenLabs API key", text: $settings.elevenLabsAPIKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Button(settings.hasElevenLabsKey ? "Изменить ключ…" : "Вставить ключ…") {
                        showElevenKey = true
                    }
                }

                if settings.hasElevenLabsKey {
                    Button("Удалить ключ", role: .destructive) {
                        settings.clearElevenLabsKey()
                        showElevenKey = false
                    }
                }

                TextField("ID голоса бригадира (EN)", text: $settings.voiceIdEnSupervisor)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(
                    """
                    Worker EN: \(ElevenLabsConfig.voiceIdEnWorker)
                    Supervisor EN (сейчас): \(settings.resolvedVoiceIdEnSupervisor)
                    RU clone (не для диалога урока): \(ElevenLabsConfig.voiceRU)
                    Пока 2-го ID нет — бригадир = worker. Вставь ElevenLabs voice_id сюда.
                    Без ключа / ошибка сети → системный голос (AVSpeech). Ключ только в Keychain.
                    Кэш mp3 учитывает voiceId + model + stability/similarity/style.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            } header: {
                Text("ElevenLabs (голос)")
            }

            Section {
                Picker("Model", selection: $settings.elModel) {
                    ForEach(ElevenLabsModelID.allCases) { m in
                        Text(m.titleRu).tag(m)
                    }
                }

                Text("RU clone (завод)")
                    .font(.subheadline.weight(.semibold))
                sliderRow("Stability RU", value: $settings.elStabilityRU)
                sliderRow("Similarity RU", value: $settings.elSimilarityRU)
                sliderRow("Style RU", value: $settings.elStyleRU)

                Text("EN")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                sliderRow("Stability EN", value: $settings.elStabilityEN)
                sliderRow("Similarity EN", value: $settings.elSimilarityEN)
                sliderRow("Style EN", value: $settings.elStyleEN)

                Button("Очистить кэш голоса") {
                    let n = ElevenLabsAudioCache.clearAll()
                    secretsRereadNote = "Кэш голоса очищен: \(n) файлов"
                    print("[el] clear cache button removed=\(n)")
                }

                Button("Сброс EL к заводским (v4)") {
                    settings.resetELVoiceDefaults()
                    secretsRereadNote = "EL завод: \(settings.elModel.rawValue) · stab \(String(format: "%.2f", settings.elStabilityRU))"
                }
            } header: {
                Text("ElevenLabs voice_settings")
            } footer: {
                Text("Завод: eleven_v4 · stability 0.70 · similarity 0.85 · style 0.10. Кэш = model+settings; смена model чистит кэш.")
            }

            Section {
                HStack {
                    Text(settings.hasGeminiKey ? "ключ сохранён (Keychain)" : "нет ключа")
                        .font(.subheadline)
                        .foregroundStyle(settings.hasGeminiKey ? Color.secondary : Color.orange)
                    Spacer()
                    if AppSecrets.hasLocalGemini {
                        Text("Ключи из Secrets")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    CoachSourceBadge(kind: settings.geminiEnabledAndReady ? .gemini : .offline)
                }

                Toggle("Использовать Gemini", isOn: $settings.useGemini)
                    .disabled(!settings.hasGeminiKey)

                if showGeminiKey {
                    SecureField("Gemini API key", text: $settings.geminiAPIKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Button(settings.hasGeminiKey ? "Изменить ключ…" : "Вставить ключ…") {
                        showGeminiKey = true
                    }
                }

                if settings.hasGeminiKey {
                    Button("Удалить ключ", role: .destructive) {
                        settings.clearGeminiKey()
                        showGeminiKey = false
                    }
                }

                Text(
                    """
                    Модель: \(GeminiConfig.model)
                    Fallback 404: \(GeminiConfig.modelFallbackChain.joined(separator: " → "))
                    Новые уроки и перевод при miss офлайн-банка. Ключ только в Keychain.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } header: {
                Text("Gemini (опционально)")
            }

            Section("Голосовые команды (RU)") {
                commandEditor("Стоп", $settings.voiceCommands.stop)
                commandEditor("Пауза", $settings.voiceCommands.pause)
                commandEditor("Дальше", $settings.voiceCommands.resume)
                commandEditor("Повтори", $settings.voiceCommands.repeatLast)
                commandEditor("Перевод", $settings.voiceCommands.translate)
                commandEditor("Запомни", $settings.voiceCommands.remember)
                commandEditor("Новый урок", $settings.voiceCommands.newLesson)
            }

            Section("О приложении") {
                LabeledContent("Приложение", value: "Languages on site")
                LabeledContent("Версия", value: "4.0")
                LabeledContent("Bundle ID", value: "com.sputnik.englishonsite")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Настройки")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { NavChrome.dismissKeyboard() }
                    .fontWeight(.semibold)
            }
        }
        .onAppear {
            settings.seedFromLocalSecretsIfNeeded()
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1, step: 0.01)
        }
    }

    private func commandEditor(_ title: String, _ words: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            TextField(
                "слова через запятую",
                text: Binding(
                    get: { words.wrappedValue.joined(separator: ", ") },
                    set: { newValue in
                        words.wrappedValue = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                            .filter { !$0.isEmpty }
                    }
                )
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.vertical, 4)
    }
}
