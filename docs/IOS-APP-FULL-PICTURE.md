# English on Site — полная картина A→Z

| | |
|---|---|
| **Документ** | `docs/IOS-APP-FULL-PICTURE.md` |
| **Дата** | 2026-10-24 |
| **Версия приложения** | 4.0 (build 7) |
| **Корень проекта** | `~/Developer/EnglishOnSite` |
| **Bundle iPhone** | `com.sputnik.englishonsite` |
| **Bundle Watch** | `com.sputnik.englishonsite.watchkitapp` |

Источник истины: кодовая база в репозитории (скан файлов + `project.pbxproj`). README.md в корне описывает v2.1 и **устарел** относительно табов Roleplay / Репетитор.

---

## 1. Что это за продукт

**English on Site** — iPhone + Apple Watch приложение для изучения **технического английского A1–A2** на строительном объекте в **Ireland** (UK terms): электрики, CCTV, монтажники, инсталляторы.

- Язык интерфейса / подсказок: **RU**
- Контент реплик: **EN ↔ RU**
- Сценарий: голос на объекте без наушников (особенно Watch), офлайн-банк фраз, опционально Gemini и ElevenLabs
- Вне scope продукта: App Store paywall, n8n/«Завод», Spanish и прочие соседние проекты

---

## 2. Структура проекта (папки, targets, min iOS)

### Дерево (реальные пути)

```
EnglishOnSite/
├── EnglishOnSite.xcodeproj/
├── EnglishOnSite/                         # iPhone target
│   ├── EnglishOnSiteApp.swift
│   ├── Info.plist
│   ├── Models/
│   │   ├── AppSettings.swift
│   │   ├── Lesson.swift
│   │   ├── LibraryItem.swift
│   │   ├── RoleplayScript.swift
│   │   ├── SitePhrase.swift
│   │   └── VoiceCommands.swift
│   ├── Views/
│   │   ├── ContentView.swift
│   │   ├── HomeView.swift
│   │   ├── PlayerView.swift
│   │   ├── CreateLessonView.swift
│   │   ├── TranslateView.swift
│   │   ├── LibraryView.swift
│   │   ├── ReviewSessionView.swift
│   │   ├── RoleplayHubView.swift
│   │   ├── ImportRoleplayView.swift
│   │   ├── RoleplayLoopView.swift
│   │   ├── SiteTutorView.swift
│   │   ├── SettingsView.swift
│   │   ├── NavChrome.swift
│   │   └── CoachSourceBadge.swift
│   ├── Services/
│   │   ├── GeminiSiteCoachService.swift
│   │   ├── ElevenLabsTTS.swift
│   │   ├── ElevenLabsConfig.swift
│   │   ├── TimedSpeechCapture.swift
│   │   ├── SpeechSpeaker.swift
│   │   ├── SpeechCommandListener.swift
│   │   ├── TranslationService.swift
│   │   ├── RememberCaptureService.swift
│   │   ├── LessonRepository.swift
│   │   ├── LessonPlayer.swift
│   │   ├── LibraryStore.swift
│   │   ├── KeychainStore.swift
│   │   ├── AudioSessionManager.swift
│   │   ├── HapticFeedback.swift
│   │   ├── DocumentTextExtractor.swift
│   │   ├── RoleplayParserService.swift
│   │   ├── RoleplayRepository.swift
│   │   ├── RoleplayLoopEngine.swift
│   │   ├── PhoneWatchBridge.swift
│   │   ├── PhoneLessonRelay.swift
│   │   └── PhoneSpeechTranscriber.swift
│   ├── Resources/
│   │   ├── SitePhraseBank.json
│   │   └── Lessons/
│   │       ├── cctv-01.json
│   │       ├── consumer-unit-01.json
│   │       ├── sockets-01.json
│   │       ├── tools-01.json
│   │       └── two-way-01.json
│   └── Assets.xcassets/
├── EnglishOnSiteWatch/                    # Watch target
│   ├── EnglishOnSiteWatchApp.swift
│   ├── Info.plist
│   ├── Views/WatchHomeView.swift
│   ├── Services/
│   │   ├── WatchAppModel.swift
│   │   ├── WatchConnectivityClient.swift
│   │   ├── WatchSpeechCapture.swift
│   │   ├── WatchSpeaker.swift
│   │   └── WatchOfflineBank.swift
│   ├── Resources/WatchPhraseBank.json
│   └── Assets.xcassets/
├── Shared/WatchPhoneMessages.swift
├── docs/IOS-APP-FULL-PICTURE.md           # этот файл
└── README.md                              # устаревший обзор v2.1
```

### Targets / OS

| | iPhone | Watch |
|---|---|---|
| **Target / Scheme** | `EnglishOnSite` | `EnglishOnSiteWatch` |
| **Bundle ID** | `com.sputnik.englishonsite` | `com.sputnik.englishonsite.watchkitapp` |
| **Min OS** | **iOS 17.0** | **watchOS 10.0** |
| **Marketing / build** | 4.0 / 7 | 4.0 / 7 |
| **Конфиги** | Debug, Release | Debug, Release |

### Зависимости

- **SPM / CocoaPods / Carthage:** нет
- Только системные фреймворки: SwiftUI, SwiftData, Speech, AVFoundation, WatchConnectivity, CryptoKit, zlib (DOCX inflate)

---

## 3. Экраны сейчас (есть / заглушка)

Табы задаются в `EnglishOnSite/Views/ContentView.swift`.

| Экран | Файл | Статус |
|---|---|---|
| **Уроки** (Home) | `HomeView.swift` | Есть: список уроков, «Новый урок», вход в Перевод |
| **Плеер урока** | `PlayerView.swift` | Есть: play/pause, голос-команды, overlay Перевод / Запомни |
| **Создать урок** (sheet) | `CreateLessonView.swift` | Есть (Gemini); без ключа — **3 офлайн-шаблона** (`LessonRepository.stubTemplates`) — намеренный fallback, не пустой UI |
| **Перевод** | `TranslateView.swift` | Есть (не отдельный таб — из Home) |
| **Библиотека** | `LibraryView.swift` | Есть: SwiftData, фильтры |
| **Повтор 5 минут** | `ReviewSessionView.swift` | Есть |
| **Roleplay** (hub) | `RoleplayHubView.swift` | Есть |
| **Импорт диалога** | `ImportRoleplayView.swift` | Есть: paste + `.txt` / `.docx` |
| **Loop Mode** | `RoleplayLoopView.swift` + `RoleplayLoopEngine.swift` | Есть каркас (см. §7) |
| **Репетитор** | `SiteTutorView.swift` | Есть (нужен Gemini) |
| **Настройки** | `SettingsView.swift` | Есть: скорость, STT caps, ключи Gemini / ElevenLabs |
| **Watch home** | `WatchHomeView.swift` | Есть: Слушаю / Перевод / Запомни / Повтор / Стоп |

Пустых экранов с `TODO`-заглушками UI в коде нет. Единственные «stubs» — офлайн-шаблоны урока при отсутствии Gemini.

---

## 4. Архитектура

### Слои

```
SwiftUI Views
    → Services (@MainActor / Observable)
        → Keychain / UserDefaults / Application Support JSON / SwiftData
        → URLSession → Gemini API / ElevenLabs API
        → AVSpeech / AVAudioPlayer / SFSpeech
Watch UI ← WatchConnectivity → PhoneWatchBridge (мозг на iPhone)
```

### UI

- SwiftUI + Observation (`@Observable`, `@Environment(AppSettings)`)
- Точка входа: `EnglishOnSiteApp.swift` → `ContentView` + SwiftData `ModelContainer(LibraryItem.self)`

### Хранение

| Данные | Где |
|---|---|
| Библиотека фраз / SRS | SwiftData → `LibraryItem` |
| Настройки UI | UserDefaults (`AppSettings`) |
| API keys | Keychain (`KeychainStore`) — **не в git** |
| User-уроки | Application Support `UserLessons/*.json` |
| Roleplay-скрипты | Application Support `Roleplays/*.json` |
| Кэш TTS | Caches `ElevenLabsTTS/*.mp3` (SHA256 от `model\|voice\|text`) |
| Bundle-уроки / банк | `Resources/Lessons/*.json`, `SitePhraseBank.json`, Watch `WatchPhraseBank.json` |

### Сеть

- Своего бэкенда нет
- Прямой `URLSession` к:
  - Gemini: `generativelanguage.googleapis.com/v1beta/models/{id}:generateContent`
  - ElevenLabs: `https://api.elevenlabs.io/v1/text-to-speech/{voice_id}`

### Аудио / речь

- TTS: `ElevenLabsTTS` → mp3 + `AVAudioPlayer`; fallback `AVSpeechSynthesizer` (`SpeechSpeaker` в уроках)
- STT: `TimedSpeechCapture` (user-stop «Готово», max 30/45/60 с), `SpeechCommandListener`, Watch audio → `PhoneSpeechTranscriber`

### Watch-модель

- **iPhone = мозг** (Gemini, банк, библиотека, урок)
- **Watch = UI + mic + локальный TTS + Solo offline bank**
- Общие payload: `Shared/WatchPhoneMessages.swift`

---

## 5. Интеграции (ElevenLabs, Gemini, STT) — статус

| Интеграция | Статус | Ключевые файлы | Условие работы |
|---|---|---|---|
| **ElevenLabs TTS** | Подключено | `ElevenLabsTTS.swift`, `ElevenLabsConfig.swift`, `SettingsView` | Toggle + ключ в Keychain; иначе AVSpeech |
| **EL disk cache** | Подключено | `fetchOrCache` → `Caches/ElevenLabsTTS` | Hit при повторном тексте+voice (Loop) |
| **Голоса A/B (Roleplay)** | Подключено | `voiceRoleA` / `voiceRoleB` (= EN / RU voice IDs) | `RoleplayLoopEngine.speakLine` |
| **Gemini** | Подключено | `GeminiSiteCoachService.swift` | translate, remember, `generateLesson`, `parseRoleplay`, `tutorReply` |
| **Модель Gemini** | Primary + fallback | `gemini-3.5-flash-lite` → `gemini-3.8-flash` → `gemini-2.5-flash` | Цепочка на HTTP 404 |
| **STT (Apple Speech)** | Подключено | `TimedSpeechCapture`, `SpeechCommandListener`, Watch→Phone | `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` |
| **WatchConnectivity** | Подключено | `PhoneWatchBridge` ↔ `WatchConnectivityClient` | Pair + оба приложения |

Конфиг голосов ElevenLabs (код):

- Model: `eleven_multilingual_v2`
- EN / Role A: `WrjxnKxK0m1uiaH0uteU`
- RU / Role B: `b2LgEdbhF1USG5rOxP3Q`
- Header: `xi-api-key` (ключ не логируется)

`.env` в проекте **нет** — ключи только через UI Настроек → Keychain.

---

## 6. Что умеет пользователь end-to-end

1. Открыть **5 bundle-уроков** (CCTV, consumer unit, sockets, tools, two-way) → прогон реплик с озвучкой.
2. **Новый урок** по теме (текст или mic) через Gemini → сохранение → плеер; без ключа — 3 шаблона.
3. **Перевод** голосом RU↔EN (офлайн `PhraseBank` → при наличии ключа Gemini).
4. **Запомни** → разбор фразы → в **Библиотеку** → **Повтор 5 минут**.
5. Голосовые команды на плеере (`VoiceCommands` / `SpeechCommandListener`).
6. **Roleplay:** вставить текст или файл `.txt`/`.docx` → парсер ролей (regex и/или Gemini) → сохранить → **Loop Mode** (оппонент озвучивается, своя реплика → «Готово», круги до «Стоп»).
7. **Репетитор:** чат про термины/конструкции (в т.ч. транслит/суржик через промпт Gemini); mic; озвучка `say_en` через ElevenLabs.
8. **Watch:** «Слушаю» → Перевод / Запомни / Повтор; Solo по локальному банку; стоп урока на iPhone через WC.

---

## 7. Пробелы по ТЗ (Roleplay Prep, Loop Mode, cache, tutor+транслит, симулятор)

| Пункт ТЗ | Факт в коде | Пробел |
|---|---|---|
| **Roleplay Prep** (paste + txt/docx + роли) | Сделано: `ImportRoleplayView`, `DocumentTextExtractor`, `RoleplayParserService`, `RoleplayRepository` | — |
| **Loop Mode** «пока не пройдёт чисто и уверенно» | Частично: крутится до ручного **Стоп** | Нет скоринга «чисто», confidence, авто-выхода |
| Проверка устной реплики в Loop | Нет | Только кнопка «Готово»; STT на ходе юзера не обязателен |
| **ElevenLabs + cache + разные голоса** | Сделано | Опционально: TTL/лимит кэша, retry |
| **Gemini tutor + транслит/суржик** | Частично: `SiteTutorView` + инструкции в `tutorReply` | Нет клиентского нормализатора транслита; озвучивается в основном `say_en`, не полный `reply_ru` |
| **Автономный симулятор** | Сборка/запуск на iPhone Simulator подтверждены в разработке | Нет XCUITest smoke; README не обновлён под v4 |

---

## 8. План модернизации 2026 (файлы + библиотеки)

Стек уже актуальный: SwiftUI (iOS 17+), Observation, SwiftData, системный Speech/AV. **Новые SPM-пакеты не обязательны.**

### Приоритет правок (существующие файлы)

| # | Файлы | Что сделать |
|---|---|---|
| 1 | `RoleplayLoopEngine.swift`, `RoleplayLoopView.swift` | STT на ходе пользователя; нормализация фразы; выход из loop после N «чистых» кругов |
| 2 | `SiteTutorView.swift`, `GeminiSiteCoachService.tutorReply` | Лёгкий pre-normalize транслита; опционально TTS для RU tip |
| 3 | `ElevenLabsTTS.swift` | При необходимости: TTL кэша, backoff на 429/5xx |
| 4 | `README.md` | Привести к v4.0 (табы Roleplay / Репетитор, команды сборки) |
| 5 | (опционально) XCUITest | Smoke: табы + Import sheet открывается |

### Библиотеки

- **Не ставить** без явной нужды (ZIP/DOCX уже на zlib в `DocumentTextExtractor.swift`).
- Если DOCX станет проблемным на редких файлах — рассмотреть минимальный SPM ZIP; не тянуть тяжёлые SDK.

---

## 9. Как собрать и запустить (команды)

```bash
cd ~/Developer/EnglishOnSite

# Доступные симуляторы / destinations
xcodebuild -scheme EnglishOnSite -showdestinations

# Сборка (пример: iPhone 17; имя сима смотри в showdestinations)
xcodebuild -scheme EnglishOnSite \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build

# Boot + install + launch
UDID=$(xcrun simctl list devices available | grep 'iPhone 17 (' | head -1 | grep -oE '[A-F0-9-]{36}')
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/EnglishOnSite-*/Build/Products/Debug-iphonesimulator/EnglishOnSite.app | head -1)
# Не брать путь из Index.noindex — там битый бандл без Bundle ID

xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" com.sputnik.englishonsite
```

**Через Xcode:** открыть `EnglishOnSite.xcodeproj` → scheme **EnglishOnSite** → iPhone Simulator → ⌘R.

**Watch:** сначала Run **EnglishOnSite** на paired iPhone sim, затем scheme **EnglishOnSiteWatch** на Watch sim.

---

## 10. Ключи / .env что нужно от меня

В репозитории **нет** `.env`. Всё через приложение:

| Ключ | Куда вставить | Для чего |
|---|---|---|
| **Gemini API key** | Настройки → секция Gemini → вставить ключ + включить toggle | Перевод, Запомни, Новый урок, парсер Roleplay (AI), Репетитор |
| **ElevenLabs API key** | Настройки → секция ElevenLabs → ключ + toggle | Живые голоса; без ключа / ошибка → AVSpeech |

После переустановки приложения Keychain для app может очиститься — ключи нужно вставить снова.

Для разработки с агентом: ключи можно дать вручную в чат/вставить в симуляторе; **не коммитить** в git.

---

## 11. Риски и следующие шаги

### Риски

| Риск | Комментарий |
|---|---|
| Смена/удаление Gemini model id | Уже есть 404-fallback chain; primary всё равно может устареть |
| ElevenLabs 400/401/квота | Ошибки показываются коротко RU; silent fallback на AVSpeech |
| DOCX edge-cases | Свой ZIP-reader; data-descriptor / экзотика может не открыться → просить `.txt` |
| Loop без скоринга | Пользователь крутит бесконечно вручную — не закрывает формулировку ТЗ «чисто и уверенно» |
| README drift | Документ в корне врёт про состав продукта |
| Watch без Roleplay/Tutor | Фичи только на iPhone |

### Следующие шаги (рекомендуемый порядок)

1. Допилить **Loop Mode**: STT + критерий «чистый круг» + авто-стоп.
2. Усилить **Репетитор**: клиентский транслит-hint + озвучка RU tip по желанию.
3. Обновить **README.md** под v4.0.
4. Smoke на симуляторе после каждого крупного diff (`xcodebuild` + launch).
5. (Позже) XCUITest на табы Roleplay / Репетитор.

---

## Краткая шпаргалка файлов по модулям ТЗ

| Модуль | Файлы |
|---|---|
| Roleplay Prep | `ImportRoleplayView.swift`, `DocumentTextExtractor.swift`, `RoleplayParserService.swift`, `RoleplayScript.swift`, `RoleplayRepository.swift`, `GeminiSiteCoachService.parseRoleplay` |
| Loop Mode | `RoleplayLoopEngine.swift`, `RoleplayLoopView.swift`, `RoleplayHubView.swift` |
| ElevenLabs | `ElevenLabsTTS.swift`, `ElevenLabsConfig.swift`, `KeychainStore.swift`, `SettingsView.swift` |
| Репетитор | `SiteTutorView.swift`, `GeminiSiteCoachService.tutorReply`, `TimedSpeechCapture.swift` |
| Уроки / банк | `HomeView`, `PlayerView`, `CreateLessonView`, `LessonRepository`, `Resources/Lessons/*`, `SitePhraseBank.json` |
| Watch | `EnglishOnSiteWatch/*`, `PhoneWatchBridge.swift`, `Shared/WatchPhoneMessages.swift` |

---

*Конец документа. Архив: сохрани/скачай этот `.md`.*
