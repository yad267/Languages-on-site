import Foundation

/// UI / explain / target languages — ready for multilingual product.
/// Today UI+explain default to `ru`; target is always `en` for now.
enum AppLocaleCode: String, Codable, CaseIterable, Identifiable, Hashable {
    case ru
    case en
    case uk
    case pl

    var id: String { rawValue }

    var titleNative: String {
        switch self {
        case .ru: return "Русский"
        case .en: return "English"
        case .uk: return "Українська"
        case .pl: return "Polski"
        }
    }
}

/// Stable role ids — content packs and Home ranking key off these (not free text).
enum LearnerRole: String, Codable, CaseIterable, Identifiable, Hashable {
    case electricianSiteIE = "electrician_site_ie"
    case siteGeneral = "site_general"
    case shopGrocery = "shop_grocery"
    case shopBuilders = "shop_builders"
    case ecommerce = "ecommerce"
    case freelancer = "freelancer"
    case office = "office"
    case jobseeker = "jobseeker"
    case unknown = "unknown"

    var id: String { rawValue }

    var titleRU: String {
        switch self {
        case .electricianSiteIE: return "Электрик · площадка IE"
        case .siteGeneral: return "Объект / стройка"
        case .shopGrocery: return "Продавец · продукты"
        case .shopBuilders: return "Продавец · стройматериалы"
        case .ecommerce: return "Интернет-магазин"
        case .freelancer: return "Фрилансер"
        case .office: return "Офис"
        case .jobseeker: return "Ищу работу"
        case .unknown: return "Пока не выбрано"
        }
    }

    var blurbRU: String {
        switch self {
        case .electricianSiteIE:
            return "Лотки, крепёж, резка металла, кабель, щиты, LOTO — не только «провода»."
        case .siteGeneral:
            return "Onsite: стройка, induction, инструмент, CCTV."
        case .shopGrocery:
            return "Зал, цена, сдача, «где найти», жалобы."
        case .shopBuilders:
            return "Артикул, наличие, «под что берёте», доставка."
        case .ecommerce:
            return "Заказ, возврат, трек, чат с клиентом."
        case .freelancer:
            return "Бриф, сроки, оплата, правки, созвон."
        case .office:
            return "Встречи, почта, статусы задач."
        case .jobseeker:
            return "Самопрезентация и собеседование."
        case .unknown:
            return "Расскажи, кем работаешь — подстроим уроки."
        }
    }

    var preferredLearningMode: AppLearningMode {
        switch self {
        case .electricianSiteIE, .siteGeneral:
            return .onSite
        case .shopGrocery, .shopBuilders, .ecommerce, .freelancer, .office, .jobseeker, .unknown:
            return .regular
        }
    }

    /// Onsite / Regular section ids to surface first (must exist in packs).
    var preferredSectionIds: [String] {
        switch self {
        case .electricianSiteIE:
            return ["electrical", "tools", "induction", "construction", "job_interview"]
        case .siteGeneral:
            return ["construction", "induction", "tools", "electrical", "websites_cctv"]
        case .shopGrocery, .shopBuilders:
            return ["shopping", "job_interview", "food", "work_office"]
        case .ecommerce:
            return ["shopping", "work_office", "job_interview"]
        case .freelancer:
            return ["work_office", "job_interview", "home"]
        case .office:
            return ["work_office", "job_interview"]
        case .jobseeker:
            return ["job_interview", "work_office", "shopping"]
        case .unknown:
            return []
        }
    }

    var tutorMode: TutorContentMode {
        preferredLearningMode.tutorMode
    }
}

enum LearnerGoal: String, Codable, CaseIterable, Identifiable, Hashable {
    case workEnglish = "work_english"
    case interview = "interview"
    case daily = "daily"

    var id: String { rawValue }

    var titleRU: String {
        switch self {
        case .workEnglish: return "Английский на работе"
        case .interview: return "Собеседование"
        case .daily: return "Быт / everyday"
        }
    }
}

/// Persisted learner identity — routing key for content; locales reserved for i18n.
struct LearnerProfile: Codable, Hashable, Equatable {
    var role: LearnerRole
    var goal: LearnerGoal
    var cefr: CEFRLevel?
    /// Free-text “about me” (source of truth for re-parse / Gemini later).
    var aboutRaw: String
    /// Fasteners / tools extracted from introduction (mixed RU/EN compounds kept).
    var tools: [LearnerToolTerm]
    /// Personal ASR vocabulary (трей, джигсо, бенсоу…) — keep learner slang, don't “fix” it.
    var speechTerms: [String]
    /// Country / market hint, e.g. IE, UK.
    var market: String?
    /// Interface language (menus). Default ru today.
    var uiLocale: AppLocaleCode
    /// Language of grammar tips / explanations. Default ru today.
    var explainLocale: AppLocaleCode
    /// Language the user is learning. Default en.
    var targetLocale: AppLocaleCode
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case role, goal, cefr, aboutRaw, tools, speechTerms, market, uiLocale, explainLocale, targetLocale, updatedAt
    }

    init(
        role: LearnerRole,
        goal: LearnerGoal,
        cefr: CEFRLevel?,
        aboutRaw: String,
        tools: [LearnerToolTerm] = [],
        speechTerms: [String] = [],
        market: String?,
        uiLocale: AppLocaleCode,
        explainLocale: AppLocaleCode,
        targetLocale: AppLocaleCode,
        updatedAt: Date
    ) {
        self.role = role
        self.goal = goal
        self.cefr = cefr
        self.aboutRaw = aboutRaw
        self.tools = tools
        self.speechTerms = speechTerms
        self.market = market
        self.uiLocale = uiLocale
        self.explainLocale = explainLocale
        self.targetLocale = targetLocale
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(LearnerRole.self, forKey: .role) ?? .unknown
        goal = try c.decodeIfPresent(LearnerGoal.self, forKey: .goal) ?? .workEnglish
        cefr = try c.decodeIfPresent(CEFRLevel.self, forKey: .cefr)
        aboutRaw = try c.decodeIfPresent(String.self, forKey: .aboutRaw) ?? ""
        tools = try c.decodeIfPresent([LearnerToolTerm].self, forKey: .tools) ?? []
        speechTerms = try c.decodeIfPresent([String].self, forKey: .speechTerms) ?? []
        market = try c.decodeIfPresent(String.self, forKey: .market)
        uiLocale = try c.decodeIfPresent(AppLocaleCode.self, forKey: .uiLocale) ?? .ru
        explainLocale = try c.decodeIfPresent(AppLocaleCode.self, forKey: .explainLocale) ?? .ru
        targetLocale = try c.decodeIfPresent(AppLocaleCode.self, forKey: .targetLocale) ?? .en
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    static let `default` = LearnerProfile(
        role: .unknown,
        goal: .workEnglish,
        cefr: nil,
        aboutRaw: "",
        tools: [],
        speechTerms: [],
        market: nil,
        uiLocale: .ru,
        explainLocale: .ru,
        targetLocale: .en,
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    var isSet: Bool { role != .unknown || !aboutRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var summaryChipsRU: [String] {
        var chips: [String] = []
        if role != .unknown { chips.append(role.titleRU) }
        chips.append(goal.titleRU)
        if let cefr { chips.append(cefr.rawValue) }
        if let market, !market.isEmpty { chips.append(market.uppercased()) }
        for tool in tools.prefix(3) {
            chips.append(tool.chipRU)
        }
        if tools.count > 3 {
            chips.append("+\(tools.count - 3) инструмент.")
        }
        for term in speechTerms.prefix(4) {
            chips.append(term)
        }
        return chips
    }

    /// Inject into Gemini / coach — introduction + structured tools.
    var contentContextBlock: String {
        var block = SiteToolLexicon.promptBlock(for: tools, aboutRaw: aboutRaw)
        if !speechTerms.isEmpty {
            block += "\nLearner personal speech terms (keep verbatim in lessons): "
                + speechTerms.joined(separator: ", ")
        }
        return block
    }

    /// SFSpeech contextual bias for this learner.
    var asrContextualStrings: [String] {
        LearnerSpeechLexicon.contextualStrings(profileTerms: speechTerms, tools: tools)
    }
}

extension LearnerProfile {
    /// Offline keyword parse — works without Gemini (pitfall: flaky network / no key).
    /// Keeps full introduction text; extracts compound tool phrases without dropping modifiers.
    static func infer(from raw: String, base: LearnerProfile = .default) -> LearnerProfile {
        let t = raw.lowercased()
        var role = base.role
        var goal = base.goal
        var market = base.market
        var cefr = base.cefr

        if t.contains("электрик") || t.contains("electrician") || t.contains("sparky")
            || t.contains("болт") || t.contains("лотк") || t.contains("кабел") || t.contains("tray")
            || t.contains("трей") || t.contains("джигсо") || t.contains("бенсоу")
            || t.contains("jigsaw") || t.contains("bandsaw") || t.contains("containment")
            || t.contains("контентмент") {
            role = .electricianSiteIE
        } else if t.contains("фриланс") || t.contains("freelance") || t.contains("самозанят") {
            role = .freelancer
        } else if t.contains("интернет") || t.contains("ecommerce") || t.contains("online shop") || t.contains("wb.") || t.contains("wildberries") {
            role = .ecommerce
        } else if (t.contains("продав") || t.contains("seller") || t.contains("shop")) &&
                    (t.contains("строител") || t.contains("builder") || t.contains("diy") || t.contains("инструмент")) {
            role = .shopBuilders
        } else if t.contains("продав") || t.contains("касс") || t.contains("магазин") || t.contains("grocery") || t.contains("супермаркет") {
            role = .shopGrocery
        } else if t.contains("офис") || t.contains("office") || t.contains("менеджер") {
            role = .office
        } else if t.contains("ищу работ") || t.contains("собеседов") || t.contains("interview") || t.contains("job seek") {
            role = .jobseeker
        } else if t.contains("стройк") || t.contains("площадк") || t.contains("onsite") || t.contains("site ") {
            role = .siteGeneral
        }

        if t.contains("собеседов") || t.contains("interview") || t.contains("ищу работ") {
            goal = .interview
        } else if t.contains("быт") || t.contains("everyday") || t.contains("dating") {
            goal = .daily
        } else {
            goal = .workEnglish
        }

        if t.contains("ирланд") || t.contains("dublin") || t.contains(" ireland") || t.contains(" ie") || t.hasSuffix("ie") {
            market = "IE"
        } else if t.contains("britain") || t.contains("uk ") || t.contains("london") {
            market = "UK"
        }

        for level in CEFRLevel.allCases {
            if t.contains(level.rawValue.lowercased()) {
                cefr = level
                break
            }
        }

        let cleaned = LearnerSpeechLexicon.correctASR(raw, profileTerms: base.speechTerms)
        let tools = SiteToolLexicon.extract(from: cleaned)
        let speech = LearnerSpeechLexicon.extractSpokenTerms(from: cleaned, extras: base.speechTerms)

        // Prefer tools section when learner talks fasteners/tools heavily.
        if !tools.isEmpty || !speech.isEmpty, role == .electricianSiteIE || role == .siteGeneral || role == .unknown {
            if role == .unknown { role = .electricianSiteIE }
        }

        return LearnerProfile(
            role: role,
            goal: goal,
            cefr: cefr,
            aboutRaw: cleaned.trimmingCharacters(in: .whitespacesAndNewlines),
            tools: tools,
            speechTerms: speech,
            market: market,
            uiLocale: base.uiLocale,
            explainLocale: base.explainLocale,
            targetLocale: base.targetLocale,
            updatedAt: Date()
        )
    }
}
