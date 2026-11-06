# Ключи Gemini / ElevenLabs (ЧИТАЙ)

1. На Mac Kolya скопируй:
   ```bash
   cp EnglishOnSite/Secrets.local.swift.example EnglishOnSite/Secrets.local.swift
   ```
2. Открой `EnglishOnSite/Secrets.local.swift` и **один раз** впиши:
   - `geminiAPIKey`
   - `elevenLabsAPIKey`
3. Файл в `.gitignore` — **не коммить**, **не кидай в чат**.
4. При старте приложения: если Keychain пустой → ключи из Secrets пишутся в Keychain, toggle Gemini/EL включаются.
5. Если Keychain уже заполнен — Secrets **не затирает**.
6. Запасной путь: Настройки → вставить ключ вручную.

Статус в Настройках: строка «Secrets.local… · Keychain…» и бейдж «Ключи из Secrets».
