#!/usr/bin/env python3
"""Replace stub tip_ru («важное слово; смотри перевод ниже») with real RU glosses."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "EnglishOnSite" / "Resources"
STUB = "важное слово"

# Longer phrases first.
GLOSS: list[tuple[str, str]] = [
    ("spirit level", "пузырьковый уровень"),
    ("cable tray", "лоток для кабеля"),
    ("cable basket", "корзина / сетчатый лоток"),
    ("safe pass", "карта Safe Pass (допуск на стройку)"),
    ("hard hat", "каска"),
    ("steel toe", "со стальным носком (ботинки)"),
    ("cut-resistant", "устойчивые к порезу"),
    ("cut resistant", "устойчивые к порезу"),
    ("hi-vis", "светоотражающий жилет"),
    ("hi vis", "светоотражающий жилет"),
    ("assembly point", "точка сбора при тревоге"),
    ("muster point", "точка сбора при тревоге"),
    ("plant room", "щитовая / техпомещение"),
    ("switch room", "электрощитовая"),
    ("switchroom", "электрощитовая"),
    ("prove dead", "проверить, что напряжения нет"),
    ("lock off", "обесточить и закрыть замком (LOTO)"),
    ("lock-off", "обесточить и закрыть замком (LOTO)"),
    ("threaded rod", "шпилька"),
    ("night mode", "ночной режим камеры"),
    ("open edge", "открытый край / край проёма"),
    ("fire alarm", "пожарная тревога"),
    ("first aider", "человек с первой помощью"),
    ("a bit low", "чуть ниже"),
    ("on the left", "слева"),
    ("on the right", "справа"),
    ("next bay", "следующий пролёт"),
    ("checking again", "проверяю снова"),
]

WORD: dict[str, str] = {
    "done": "готово / сделано",
    "boots": "ботинки",
    "steel": "сталь / стальной",
    "toe": "носок ботинка",
    "zip": "застегни (молнию)",
    "fully": "полностью",
    "gloves": "перчатки",
    "cut": "рез / резка",
    "work": "работа",
    "glasses": "очки (защитные)",
    "grinding": "шлифовка",
    "clear": "можно / свободно",
    "enter": "заходить",
    "cabin": "бытовка",
    "thanks": "спасибо",
    "going": "иду",
    "first": "сначала / первый",
    "put": "надень / поставь",
    "your": "твой / ваш",
    "hard": "жёсткий / каска (hard hat)",
    "hat": "каска (в hard hat)",
    "before": "до / перед",
    "gate": "ворота / калитка",
    "step": "шаг",
    "confirm": "подтверди",
    "please": "пожалуйста",
    "need": "нужно",
    "next": "следующий",
    "ready": "готов",
    "call": "позвони / вызови",
    "questions": "вопросы",
    "task": "задача",
    "say": "скажи",
    "more": "ещё / больше",
    "keep": "держи / продолжай",
    "move": "двигайся / перенеси",
    "again": "снова",
    "five": "пять",
    "minutes": "минут",
    "tidy": "убери / приведи в порядок",
    "area": "зона / участок",
    "lunch": "обед",
    "starting": "начинаем",
    "radio": "рация",
    "sweep": "подмети",
    "slower": "медленнее",
    "slowly": "медленно",
    "level": "уровень / по уровню",
    "go": "иди / поезжай",
    "leave": "оставь / уходи",
    "cable": "кабель",
    "check": "проверь",
    "test": "тест / проверь",
    "tray": "лоток",
    "take": "возьми",
    "two": "два",
    "tools": "инструмент",
    "raise": "подними",
    "camera": "камера",
    "view": "картинка / вид",
    "use": "используй",
    "after": "после",
    "sign": "знак / подпиши",
    "bolts": "болты",
    "ten": "десять",
    "assembly": "сбор / точка сбора",
    "point": "точка / пункт",
    "side": "сторона",
    "mode": "режим",
    "today": "сегодня",
    "site": "площадка / объект",
    "washer": "шайба",
    "millimetre": "миллиметр",
    "millimetres": "миллиметры",
    "alarm": "тревога / сигнал",
    "under": "под",
    "works": "работает / работы",
    "get": "возьми / достань",
    "report": "доложи / отчёт",
    "outside": "снаружи",
    "left": "левый / слева",
    "right": "правый / справа",
    "name": "имя",
    "mark": "отметь",
    "marked": "отметил",
    "start": "начни / старт",
    "only": "только",
    "safe": "безопасно / Safe Pass",
    "hold": "держи",
    "add": "добавь",
    "looks": "выглядит",
    "label": "бирка / наклейка",
    "support": "опора / кронштейн",
    "tighten": "затяни",
    "tight": "туго / затянуто",
    "fixed": "закреплено",
    "bubble": "пузырёк (в уровне)",
    "middle": "середина",
    "chalk": "мел",
    "joint": "стык",
    "flush": "в плоскости / заподлицо",
    "almost": "почти",
    "torque": "затяни с моментом",
    "torqued": "затянуто по моменту",
    "spec": "по норме / спецификация",
    "bracket": "кронштейн",
    "height": "высота",
    "centimetres": "сантиметры",
    "dressed": "уложен (кабель)",
    "glare": "блик",
    "listen": "слушай",
    "carefully": "внимательно",
    "fire": "пожар / огонь",
    "sound": "звук",
    "continuous": "непрерывный",
    "siren": "сирена",
    "canteen": "столовая на объекте",
    "green": "зелёный",
    "supervisor": "супервайзер / бригадир",
    "understood": "понял",
    "straight": "прямо / сразу",
    "allowed": "разрешено",
    "ppe": "СИЗ",
    "earth": "заземление",
    "bond": "перемычка / на землю",
    "deburr": "убрать заусенцы",
    "feeder": "фидер / питающая линия",
    "board": "щит / панель",
    "cover": "крышка",
    "tag": "бирка",
    "bay": "пролёт / секция",
    "slab": "плита перекрытия",
    "barriers": "ограждения",
    "hoist": "подъёмник",
    "walkways": "пешеходные дорожки",
    "trunking": "кабель-канал",
    "unistrut": "профиль Unistrut",
    "containment": "трасса прокладки кабеля",
    "standby": "наблюдающий",
    "nvr": "видеорегистратор (NVR)",
    "card": "карта / пропуск",
    "sit": "садись / сиди",
    "where": "где",
    "what": "что",
    "who": "кто",
    "how": "как",
    "induction": "инструктаж",
    "pass": "пропуск / Pass",
    "resistant": "устойчивый",
    "have": "есть / имею",
    "i'll": "я сделаю / я",
    "one": "один",
    "port": "порт",
    "night": "ночь / ночной",
    "any": "какие-нибудь / любой",
    "like": "как / нравится",
    "high": "высокий",
    "low": "низкий",
    "bit": "чуть-чуть",
    "okay": "ладно / ок",
    "ok": "ок",
    "good": "хорошо",
    "yes": "да",
    "no": "нет",
}


STOP = {
    "a", "an", "the", "is", "are", "am", "to", "of", "on", "in", "at", "for", "and", "or",
    "do", "does", "did", "we", "you", "i", "it", "this", "that", "with", "all", "now", "then",
    "be", "been", "was", "were", "will", "can", "could", "should", "from", "by", "as", "if",
    "so", "not", "but", "too", "just", "also", "here", "there", "me", "him", "her", "them",
    "our", "their", "my", "his", "hers", "its", "up", "out", "off", "into", "onto",
}


def tip_from_en(en: str, existing: str | None = None) -> str:
    low = en.lower()
    hits: list[str] = []
    used_spans: list[tuple[int, int]] = []

    for needle, gloss in sorted(GLOSS, key=lambda x: -len(x[0])):
        start = 0
        while True:
            idx = low.find(needle, start)
            if idx < 0:
                break
            end = idx + len(needle)
            if any(not (end <= a or idx >= b) for a, b in used_spans):
                start = end
                continue
            used_spans.append((idx, end))
            label = en[idx:end] if en[idx:end] else needle
            # preserve original casing lightly
            hits.append(f"{needle} = {gloss}")
            start = end
            break  # one hit per phrase type
        if len(hits) >= 4:
            break

    covered = set()
    for a, b in used_spans:
        for w in re.findall(r"[a-z']+", low[a:b]):
            covered.add(w)

    tokens = re.findall(r"[A-Za-z']+", en)
    for tok in tokens:
        w = tok.lower()
        if w in STOP or w in covered or len(w) <= 1:
            continue
        meaning = WORD.get(w)
        if meaning:
            hits.append(f"{tok} = {meaning}")
            covered.add(w)
        if len(hits) >= 4:
            break

    if hits:
        # unique preserve order
        seen = set()
        out = []
        for h in hits:
            if h.lower() in seen:
                continue
            seen.add(h.lower())
            out.append(h)
        return " · ".join(out[:4])

    ex = (existing or "").strip()
    if ex and STUB not in ex and re.search(r"[А-Яа-яЁё]", ex) and len(ex) <= 180:
        if "=" in ex or "—" in ex or "–" in ex or " - " in ex:
            return ex

    # Last resort: short RU cue from full translation is better than stub — but tip is words.
    return "Слушай фразу и сверь с переводом ниже."


def rewrite_obj(o):
    if isinstance(o, dict):
        if isinstance(o.get("en"), str) and "tip_ru" in o:
            en = o["en"]
            old = o.get("tip_ru")
            if not isinstance(old, str) or STUB in old or not old.strip():
                o["tip_ru"] = tip_from_en(en, old if isinstance(old, str) else None)
            elif STUB in old:
                o["tip_ru"] = tip_from_en(en, old)
            else:
                # still refresh weak stubs-only remnants
                if "смотри перевод" in old.lower():
                    o["tip_ru"] = tip_from_en(en, old)
        for v in o.values():
            rewrite_obj(v)
    elif isinstance(o, list):
        for v in o:
            rewrite_obj(v)


def main() -> None:
    for name in (
        "lessons_pack.json",
        "lessons_onsite_sections_v1.json",
        "lessons_regular_sections_v1.json",
    ):
        path = RES / name
        data = json.loads(path.read_text(encoding="utf-8"))
        before = path.read_text(encoding="utf-8").count(STUB)
        rewrite_obj(data)
        path.write_text(
            json.dumps(data, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        after = path.read_text(encoding="utf-8").count(STUB)
        print(f"{name}: stub {before} → {after}")

    # verify steel toe line
    pack = json.loads((RES / "lessons_pack.json").read_text(encoding="utf-8"))

    def find(o):
        if isinstance(o, dict):
            if o.get("en") == "Done. Boots are steel toe.":
                print("steel tip:", o.get("tip_ru"))
            for v in o.values():
                find(v)
        elif isinstance(o, list):
            for v in o:
                find(v)

    find(pack)


if __name__ == "__main__":
    main()
