# English on Site (v4.0)

iPhone + Apple Watch: EN ↔ RU на объекте (Ireland).  
Табы: Уроки · Библиотека · Roleplay · Репетитор · Настройки.  
Тренажёр фраз (Loop 75%), EL cache, Gemini tutor + phrasals.

## Ключи (один раз на Mac)

См. [docs/SECRETS.md](docs/SECRETS.md). Кратко:

```bash
cp EnglishOnSite/Secrets.local.swift.example EnglishOnSite/Secrets.local.swift
# впиши geminiAPIKey / elevenLabsAPIKey — НЕ в git, НЕ в чат
```

При старте пустой Keychain заполняется из Secrets.local.swift.

## Targets / Scheme

| Scheme | Bundle ID | Роль |
|---|---|---|
| **EnglishOnSite** | `com.sputnik.englishonsite` | Мозг: банк, Gemini, библиотека, урок |
| **EnglishOnSiteWatch** | `com.sputnik.englishonsite.watchkitapp` | UI + mic + TTS на запястье |

### Как запустить Watch Simulator

1. Открой `~/Developer/EnglishOnSite/EnglishOnSite.xcodeproj` в **Xcode.app** (нужен полный Xcode, не только CLI Tools).
2. Scheme → **EnglishOnSiteWatch**.
3. Destination → Apple Watch simulator (paired с iPhone sim).
4. ⌘R. Тап **Слушаю** → демо-фраза если mic пуст → EN/RU + TTS.
5. Полный цикл (Gemini / Запомни / Повтор): сначала Run **EnglishOnSite** на paired iPhone sim, потом Watch.

## Ключевые файлы

**Watch**
- `EnglishOnSiteWatch/Views/WatchHomeView.swift` — экран
- `EnglishOnSiteWatch/Services/WatchAppModel.swift` — логика команд
- `EnglishOnSiteWatch/Services/WatchConnectivityClient.swift` — WCSession
- `EnglishOnSiteWatch/Services/WatchSpeechCapture.swift` — mic 4–8 с
- `EnglishOnSiteWatch/Services/WatchSpeaker.swift` — TTS в динамик
- `EnglishOnSiteWatch/Services/WatchOfflineBank.swift` + `Resources/WatchPhraseBank.json` (~34 фразы)

**iPhone**
- `EnglishOnSite/Services/PhoneWatchBridge.swift` — мозг WC
- `EnglishOnSite/Services/PhoneLessonRelay.swift` — стоп/дальше урока
- `Shared/WatchPhoneMessages.swift` — общие payload

## Батарея

- Нет always-on listening — только тап **Слушаю**.
- Захват 4–8 с (перевод) / 30–60 с (запомни из settings телефона).
- TTS короткий; кнопка **Стоп речь**.
- Solo-режим: локальный банк, без сети/Gemini.

## Вторник · Series 12 (чеклист)

- [ ] Pair Watch ↔ iPhone, оба app установлены
- [ ] Permissions mic + speech на Watch
- [ ] Тап Слушаю на шумном объекте → transcript / «Не слышу»
- [ ] Ответ: крупный EN+RU + голос из динамика часов (без AirPods)
- [ ] Перевод / Запомни / Повтор при reachable iPhone
- [ ] Solo (iPhone далеко): офлайн-банк, без краша
- [ ] Урок на iPhone → Стоп с часов
- [ ] Громкость / haptic до ответа

## v2.1 · Новые уроки (Gemini)

1. Settings → вставь Gemini key, включи Gemini.
2. Уроки → **Новый урок** → тема текстом или mic («урок про CCTV кабель»).
3. «Собираю урок…» → урок с бейджем **Мой** → сразу открывается плеер.
4. Без ключа: алерт + 3 шаблона-заглушки.
5. Свайп удаляет только user-уроки. Bundle — нельзя.
6. Файлы: `Application Support/UserLessons/*.json`.

Код: `LessonRepository`, `CreateLessonView`, `GeminiSiteCoachService.generateLesson`, `LessonTopicParser`.

**Watch: не делал** (можно позже: WC «урок»+тема → phone → «Урок готов на iPhone»).
