# Offline translator (ML Kit)

## Stack
- SPM: `https://github.com/d-date/google-mlkit-swiftpm` ≥ 9.0.3 (Google does **not** ship official SPM; this rebuilds CocoaPods XCFrameworks).
- Products: `MLKitTranslate`, `MLKitTextRecognition`.
- Bundled resources (must be in Copy Bundle Resources):
  - `EnglishOnSite/Resources/MLKit/MLKitTranslate_resource.bundle`
  - `EnglishOnSite/Resources/MLKit/LatinOCRResources.bundle`
- Linker: `-ObjC` `-all_load` on the EnglishOnSite target.

## Offline / online switch
1. **PhraseBank** exact hit (site EN↔RU) always wins.
2. If **Офлайн ML Kit сначала** (`preferOfflineTranslation`) **or** Gemini is off → ML Kit Translate (source picker → Russian).
3. Else / on ML Kit miss → **Gemini** online (same picker source language).
4. Photo: OCR (ML Kit Text Recognition if linked, else Apple Vision) → ML Kit Translate; Gemini photo path keeps the picker language and does **not** assume Russian.

## Model sizes
- ~**30 MB per language** downloaded on first use (Wi‑Fi preferred).
- Pair = source + **Russian** ≈ **60 MB** for EN→RU; more if the user switches ES/DE/FR/PT.

## Requirements
- App deployment: **iOS 17** (project); ML Kit package needs **iOS 15+**.
- First translate may download models; UI shows `Скачиваю офлайн …`.
- There is **no** single “image translation” ML Kit API — photo = OCR + text translate.

## Attribution
Show Google ML Kit / Translate attribution where required by [ML Kit guidelines](https://developers.google.com/ml-kit/attribution).
