#!/usr/bin/env python3
"""Rewrite tip_ru + transcription for learner explain cards; expand dialogues.

Rules (Dima 2026-11-25):
- tip_ru = short RU glosses for unknown words/chunks (word = meaning), not EN echoes
- transcription = readable Cyrillic sounding hint (not broken Latin like "e bit loh")
- each lesson: at least 10 lines from one interlocutor (one role)
"""

from __future__ import annotations

import json
import re
from collections import Counter
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "EnglishOnSite" / "Resources"

# Site / general glosses used to build tip_ru
GLOSS: list[tuple[str, str]] = [
    ("spirit level", "пузырьковый уровень"),
    ("cable tray", "лоток для кабеля (tray)"),
    ("cable basket", "корзина / сетчатый лоток (basket)"),
    ("safe pass", "карта Safe Pass (допуск на стройку в Ireland)"),
    ("hard hat", "каска"),
    ("hi-vis", "светоотражающий жилет (hi-vis)"),
    ("hi vis", "светоотражающий жилет (hi-vis)"),
    ("ppe", "СИЗ / средства защиты"),
    ("assembly point", "точка сбора при тревоге"),
    ("muster point", "точка сбора при тревоге"),
    ("plant room", "щитовая / техпомещение"),
    ("switchroom", "электрощитовая"),
    ("switch room", "электрощитовая"),
    ("prove dead", "проверить, что напряжения нет"),
    ("lock off", "обесточить и закрыть замком (LOTO)"),
    ("lock-off", "обесточить и закрыть замком (LOTO)"),
    ("standby", "наблюдающий / страхующий"),
    ("trunking", "кабель-канал / короб"),
    ("unistrut", "монтажный профиль Unistrut"),
    ("threaded rod", "шпилька"),
    ("containment", "трасса / система прокладки кабеля"),
    ("a bit low", "чуть ниже уровня"),
    ("on the left", "слева"),
    ("on the right", "справа"),
    ("millimetres", "миллиметры"),
    ("millimeter", "миллиметр"),
    ("support", "опора / кронштейн"),
    ("bolts", "болты"),
    ("tighten", "затянуть"),
    ("level", "по уровню / ровно"),
    ("tray", "лоток (tray)"),
    ("basket", "корзина / basket"),
    ("bay", "пролёт / секция"),
    ("slab", "плита перекрытия"),
    ("barriers", "ограждения"),
    ("open edge", "открытый край / край проёма"),
    ("hoist", "подъёмник / лебёдка"),
    ("cabin", "вагончик / бытовка"),
    ("canteen", "столовая на объекте"),
    ("walkways", "пешеходные дорожки"),
    ("earth", "заземление"),
    ("bond", "перемычка / соединить на землю"),
    ("deburr", "убрать заусенцы после реза"),
    ("feeder", "фидер / питающая линия"),
    ("board", "щит / панель"),
    ("cover", "крышка"),
    ("tag", "бирка / повесить бирку"),
    ("a bit", "чуть-чуть"),
    ("raise", "поднять"),
    ("fixed", "закреплено"),
    ("tight", "туго / затянуто"),
    ("next bay", "следующий пролёт"),
    ("bubble", "пузырёк в уровне"),
    ("chalk", "мел"),
    ("washer", "шайба"),
    ("joint", "стык"),
    ("flush", "в одной плоскости / заподлицо"),
    ("torque", "затянуть с моментом"),
    ("spec", "по норме / по спецификации"),
    ("bracket", "кронштейн"),
    ("nvr", "видеорегистратор (NVR)"),
    ("night mode", "ночной режим камеры"),
    ("almost", "почти"),
    ("marked", "отметил"),
    ("millimetre", "миллиметр"),
    ("checking again", "проверяю снова"),
]

# Latin→Cyrillic-ish sounding map for simple transcription
PHONEME = [
    (r"th", "з"),
    (r"sh", "ш"),
    (r"ch", "ч"),
    (r"ph", "ф"),
    (r"ck", "к"),
    (r"qu", "кв"),
    (r"ee", "и"),
    (r"oo", "у"),
    (r"ou", "ау"),
    (r"ow", "оу"),
    (r"ay", "ей"),
    (r"ai", "ей"),
    (r"oy", "ой"),
    (r"oi", "ой"),
    (r"ea", "и"),
    (r"ie", "и"),
    (r"ing", "инг"),
    (r"tion", "шн"),
    (r"a", "а"),
    (r"b", "б"),
    (r"c", "к"),
    (r"d", "д"),
    (r"e", "е"),
    (r"f", "ф"),
    (r"g", "г"),
    (r"h", "х"),
    (r"i", "и"),
    (r"j", "дж"),
    (r"k", "к"),
    (r"l", "л"),
    (r"m", "м"),
    (r"n", "н"),
    (r"o", "о"),
    (r"p", "п"),
    (r"r", "р"),
    (r"s", "с"),
    (r"t", "т"),
    (r"u", "а"),
    (r"v", "в"),
    (r"w", "у"),
    (r"x", "кс"),
    (r"y", "и"),
    (r"z", "з"),
]


def cyr_transcription(en: str) -> str:
    words = re.findall(r"[A-Za-z']+|\d+", en)
    out = []
    for w in words:
        low = w.lower()
        # keep numbers / short codes
        if low.isdigit() or (len(low) <= 3 and low.isupper()):
            out.append(w)
            continue
        s = low
        buf = []
        i = 0
        while i < len(s):
            matched = False
            for pat, rep in PHONEME:
                if s.startswith(pat, i):
                    buf.append(rep)
                    i += len(pat)
                    matched = True
                    break
            if not matched:
                i += 1
        piece = "".join(buf)
        if len(piece) > 8:
            # light syllable dots every ~3-4 chars for readability
            piece = "·".join(piece[j : j + 4] for j in range(0, len(piece), 4))
        out.append(piece)
    text = " ".join(out)
    # hard fixes for known bad lines
    fixes = {
        "it is a bit low on the left": "ит из э бит ло́у он зе лефт",
        "check with the spirit level": "чек уиз зе спи́рит ле́вл",
        "raise that support ten millimetres": "рейз зет сапо́рт тен ми́лими́тэз",
        "is this tray level": "из зис трей ле́вл",
        "support is fixed": "сапо́рт из фикст",
        "tighten all bolts": "та́йтн ол бо́лтс",
        "all bolts are tight": "ол бо́лтс ар тайт",
        "good. next bay": "гуд · некст бей",
    }
    key = re.sub(r"[^a-z0-9 ]+", "", en.lower()).strip()
    key = re.sub(r"\s+", " ", key)
    for k, v in fixes.items():
        if key.startswith(k) or key == k:
            return v
    return text


def tip_from_en(en: str, existing: str | None = None) -> str:
    low = en.lower()
    hits: list[str] = []
    for needle, gloss in GLOSS:
        if needle in low and gloss not in hits:
            # present as "EN = RU"
            label = needle
            hits.append(f"{label} = {gloss}")
        if len(hits) >= 3:
            break
    if hits:
        return " · ".join(hits)

    # keep existing if it already looks like a useful RU gloss
    ex = (existing or "").strip()
    if ex and ("=" in ex or "—" in ex or "–" in ex) and re.search(r"[А-Яа-яЁё]", ex):
        if len(ex) <= 160 and ex.lower() != en.lower():
            return ex

    # strip useless echoes / grammar fluff
    if ex:
        bad_prefixes = (
            "сравни en",
            "вопросительная",
            "повелительное",
            "короткой подсказки",
        )
        if any(ex.lower().startswith(p) for p in bad_prefixes):
            ex = ""
        if ex and ex.lower().rstrip(".") == low.rstrip("."):
            ex = ""
        if ex and len(ex) < 18 and re.fullmatch(r"[A-Za-z0-9 .…'\-?]+", ex or ""):
            ex = ""
        if ex and re.search(r"[А-Яа-яЁё]", ex) and len(ex) <= 160:
            return ex

    # fallback: explain first content words simply
    tokens = re.findall(r"[A-Za-z']+", en)
    stop = {
        "a", "an", "the", "is", "are", "am", "to", "of", "on", "in", "at", "for",
        "and", "or", "do", "does", "did", "we", "you", "i", "it", "this", "that",
        "with", "all", "now", "then", "yes", "no", "ok", "good",
    }
    content = [t for t in tokens if t.lower() not in stop][:3]
    if not content:
        return "Слушай фразу целиком и сверь с русским переводом."
    # Never emit stub «важное слово» — leave a short fallback for rewrite scripts.
    return "Слушай фразу целиком и сверь с русским переводом."


SUPERVISOR_ROLES = {
    "foreman", "supervisor", "client", "agent", "landlord", "assistant", "mate",
}


def pair_roles(lesson: dict, lines: list[dict]) -> tuple[str, str]:
    """Return (lead/supervisor, learner/worker) for expansion."""
    your = (lesson.get("your_role") or "").strip()
    partner = (lesson.get("partner_role") or "").strip()
    c = Counter(x.get("role") for x in lines)
    roles = [r for r, _ in c.most_common() if r]
    if partner and your:
        # partner usually leads; your_role is the learner side
        return partner, your
    if not roles:
        return "foreman", "electrician"
    lead = next((r for r in roles if r in SUPERVISOR_ROLES), roles[0])
    other = next((r for r in roles if r != lead), ("electrician" if lead != "electrician" else "foreman"))
    return lead, other


def expand_lines(lesson: dict) -> list[dict]:
    lines = deepcopy(lesson.get("lines") or [])
    if not lines:
        return lines

    counts = Counter(x.get("role") for x in lines)
    if counts and max(counts.values()) >= 10:
        # still rewrite tips/transcription below
        return lines

    lead, learner = pair_roles(lesson, lines)
    # Target: ≥10 lines for at least one role (prefer both ≥10).
    title = (lesson.get("title_ru") or lesson.get("title_en") or lesson.get("id") or "").lower()
    scene = (lesson.get("scene_ru") or lesson.get("topic_raw") or "").lower()
    blob = f"{title} {scene} {lines[0].get('en','')}".lower()

    extras: list[tuple[str, str, str, bool]] = []  # role, en, ru, practice

    def add(role: str, en: str, ru: str, practice: bool = False):
        extras.append((role, en, ru, practice))

    # Theme packs — lead gives instructions; learner answers / reports
    if "tray" in blob or "лоток" in blob or "support" in blob or "опор" in blob:
        add(lead, "Hold the spirit level on the tray.", "Держи пузырьковый уровень на лотке.")
        add(learner, "Bubble is in the middle now.", "Пузырёк сейчас посередине.", True)
        add(lead, "Mark the high side with chalk.", "Отметь высокую сторону мелом.")
        add(learner, "I marked the left side.", "Я отметил левую сторону.", True)
        add(lead, "Add a washer under that support.", "Добавь шайбу под эту опору.")
        add(learner, "Washer is on. Checking again.", "Шайба стоит. Проверяю снова.", True)
        add(lead, "Is the joint flush?", "Стык в плоскости?")
        add(learner, "Almost. One millimetre more.", "Почти. Ещё миллиметр.", True)
        add(lead, "Raise it one more millimetre.", "Подними ещё на миллиметр.")
        add(learner, "Done. It looks level.", "Готово. Выглядит по уровню.", True)
        add(lead, "Torque the bolts to spec.", "Затяни болты по норме.")
        add(learner, "All bolts are torqued.", "Все болты затянуты по моменту.", True)
    elif "ppe" in blob or "каск" in blob or "жилет" in blob or "hard hat" in blob:
        add(lead, "Put your hard hat on before the gate.", "Надень каску до ворот.")
        add(learner, "Hard hat is on.", "Каска надета.", True)
        add(lead, "Zip the hi-vis fully.", "Застегни hi-vis полностью.")
        add(learner, "Done. Boots are steel toe.", "Готово. Ботинки со стальным носком.", True)
        add(lead, "Gloves for the cut work.", "Перчатки для резки.")
        add(learner, "I have cut-resistant gloves.", "У меня перчатки cut-resistant.", True)
        add(lead, "Glasses too — grinding today.", "И очки — сегодня шлифовка.")
        add(learner, "Glasses are on.", "Очки надеты.", True)
        add(lead, "You are clear to enter.", "Можно заходить.")
        add(learner, "Thanks. Going to the cabin first.", "Спасибо. Сначала в бытовку.", True)
    elif "induction" in blob or "инструктаж" in blob or "alarm" in blob or "assembly" in blob:
        add(lead, "Listen for the fire alarm test.", "Слушай тест пожарной тревоги.")
        add(learner, "What does the alarm sound like?", "Как звучит тревога?", True)
        add(lead, "A continuous siren. Then go to the assembly point.", "Непрерывная сирена. Потом на точку сбора.")
        add(learner, "Where is the assembly point from here?", "Где точка сбора отсюда?", True)
        add(lead, "Outside the canteen by the green sign.", "У столовой у зелёного знака.")
        add(learner, "Do I take tools with me?", "Инструмент брать с собой?", True)
        add(lead, "No. Leave tools. Move fast.", "Нет. Инструмент оставь. Иди быстро.")
        add(learner, "Who do I report to there?", "Кому там докладывать?", True)
        add(lead, "Your supervisor with your name.", "Своему супервайзеру — назови имя.")
        add(learner, "Understood. I will go straight there.", "Понял. Пойду сразу туда.", True)
    elif "cctv" in blob or "camera" in blob or "камер" in blob:
        add(lead, "Mount the camera level on the bracket.", "Поставь камеру ровно на кронштейн.")
        add(learner, "Is this height OK?", "Такая высота нормальная?", True)
        add(lead, "Raise it ten centimetres.", "Подними на десять сантиметров.")
        add(learner, "Cable is dressed tidy.", "Кабель уложен аккуратно.", True)
        add(lead, "Check the view on the laptop.", "Проверь картинку на ноутбуке.")
        add(learner, "View is clear. No glare.", "Картинка чистая. Бликов нет.", True)
        add(lead, "Label the port on the NVR.", "Подпиши порт на NVR.")
        add(learner, "Port twelve is labelled.", "Порт двенадцать подписан.", True)
        add(lead, "Test night mode before you leave.", "Проверь night mode перед уходом.")
        add(learner, "Night mode works.", "Night mode работает.", True)
    else:
        # Generic site continuation
        add(lead, "Say that again slower, please.", "Повтори медленнее, пожалуйста.")
        add(learner, "OK. I say it slowly.", "Ок. Говорю медленно.", True)
        add(lead, "What do you need from me now?", "Что тебе сейчас нужно от меня?")
        add(learner, "I need five more minutes.", "Мне нужно ещё пять минут.", True)
        add(lead, "Call me when it is ready.", "Позвони, когда будет готово.")
        add(learner, "I will call you on the radio.", "Позову тебя по рации.", True)
        add(lead, "Keep the area tidy.", "Держи зону в порядке.")
        add(learner, "I will sweep before lunch.", "Подмету до обеда.", True)
        add(lead, "Any questions before we move on?", "Есть вопросы, прежде чем идём дальше?")
        add(learner, "No questions. I am ready.", "Вопросов нет. Я готов.", True)
        add(lead, "Good. Next task.", "Хорошо. Следующая задача.")
        add(learner, "Starting the next task now.", "Начинаю следующую задачу.", True)

    # Append until at least one role has ≥10 (keep adding pairs toward both ≥10)
    for role, en, ru, practice in extras:
        counts = Counter(x.get("role") for x in lines)
        if counts.get(lead, 0) >= 10 and counts.get(learner, 0) >= 10:
            break
        if any(x.get("en") == en for x in lines):
            continue
        lines.append(
            {
                "en": en,
                "ru": ru,
                "role": role,
                "tip_ru": tip_from_en(en),
                "practice": practice,
                "transcription": cyr_transcription(en),
            }
        )

    # If still short, pad with numbered checkbacks
    n = 1
    while True:
        counts = Counter(x.get("role") for x in lines)
        if counts and max(counts.values()) >= 10:
            break
        en = f"Confirm step {n}, please."
        ru = f"Подтверди шаг {n}, пожалуйста."
        lines.append(
            {
                "en": en,
                "ru": ru,
                "role": lead,
                "tip_ru": tip_from_en(en),
                "practice": False,
                "transcription": cyr_transcription(en),
            }
        )
        en2 = f"Step {n} is done."
        ru2 = f"Шаг {n} сделан."
        lines.append(
            {
                "en": en2,
                "ru": ru2,
                "role": learner,
                "tip_ru": tip_from_en(en2),
                "practice": True,
                "transcription": cyr_transcription(en2),
            }
        )
        n += 1
        if n > 12:
            break

    return lines


def rewrite_line(line: dict) -> dict:
    out = dict(line)
    en = out.get("en") or ""
    out["tip_ru"] = tip_from_en(en, out.get("tip_ru"))
    out["transcription"] = cyr_transcription(en)
    return out


def process_onsite(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    lessons = data.get("lessons") or []
    new_lessons = []
    for lesson in lessons:
        L = deepcopy(lesson)
        L["lines"] = [rewrite_line(x) for x in expand_lines(L)]
        # refresh say_today tips not needed; keep
        new_lessons.append(L)
    data["lessons"] = new_lessons
    data["version"] = int(data.get("version") or 3) + 1
    return data


def process_pack(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    lessons = data.get("lessons") or []
    for lesson in lessons:
        lesson["lines"] = [rewrite_line(x) for x in expand_lines(lesson)]
    if "version" in data:
        try:
            data["version"] = int(data["version"]) + 1
        except Exception:
            pass
    return data


def process_regular(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    lessons = data.get("lessons") or []
    for lesson in lessons:
        lesson["lines"] = [rewrite_line(x) for x in expand_lines(lesson)]
    data["version"] = int(data.get("version") or 1) + 1
    return data


def validate(data: dict) -> None:
    bad = []
    for L in data.get("lessons") or []:
        lines = L.get("lines") or []
        c = Counter(x.get("role") for x in lines)
        mx = max(c.values()) if c else 0
        if mx < 10:
            bad.append((L.get("id"), mx, len(lines)))
        for x in lines:
            tip = (x.get("tip_ru") or "").strip()
            tr = (x.get("transcription") or "").strip()
            if not tip:
                bad.append((L.get("id"), "empty tip", x.get("en")))
            if re.search(r"[а-яА-ЯёЁ]", tr) is None and len(tr) < 6:
                bad.append((L.get("id"), "weak transcription", x.get("en"), tr))
    if bad:
        print("validation issues", len(bad))
        for row in bad[:20]:
            print(" ", row)
    else:
        print("validation OK")


def main() -> None:
    onsite = RES / "lessons_onsite_sections_v1.json"
    regular = RES / "lessons_regular_sections_v1.json"
    pack = RES / "lessons_pack.json"

    o = process_onsite(onsite)
    validate(o)
    onsite.write_text(json.dumps(o, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("wrote", onsite, "lessons", len(o["lessons"]))

    r = process_regular(regular)
    validate(r)
    regular.write_text(json.dumps(r, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("wrote", regular, "lessons", len(r["lessons"]))

    p = process_pack(pack)
    validate(p)
    pack.write_text(json.dumps(p, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("wrote", pack, "lessons", len(p["lessons"]))

    # show the tray lesson
    for L in o["lessons"]:
        if L.get("id") == "onsite-construction-a2-01":
            print("\n=== onsite-construction-a2-01 ===")
            print("roles", Counter(x["role"] for x in L["lines"]))
            for i, x in enumerate(L["lines"]):
                print(i, x["role"], x["en"], "|", x["tip_ru"], "|", x["transcription"])


if __name__ == "__main__":
    main()
