import { lookup } from "node:dns/promises";
import { isIP } from "node:net";

import { defineTool } from "@grok/agent-sdk/tools";
import * as z from "zod/v4";

const DEFAULT_URL = "https://example.com";
const MAX_HTML_CHARS = 500_000;
const MAX_SIGNALS = 40;
const MAX_REDIRECTS = 5;

const ISO639_1 = new Set([
  "aa", "ab", "ae", "af", "ak", "am", "an", "ar", "as", "av", "ay", "az",
  "ba", "be", "bg", "bh", "bi", "bm", "bn", "bo", "br", "bs",
  "ca", "ce", "ch", "co", "cr", "cs", "cu", "cv", "cy",
  "da", "de", "dv", "dz",
  "ee", "el", "en", "eo", "es", "et", "eu",
  "fa", "ff", "fi", "fj", "fo", "fr", "fy",
  "ga", "gd", "gl", "gn", "gu", "gv",
  "ha", "he", "hi", "ho", "hr", "ht", "hu", "hy", "hz",
  "ia", "id", "ie", "ig", "ii", "ik", "io", "is", "it", "iu",
  "ja", "jv",
  "ka", "kg", "ki", "kj", "kk", "kl", "km", "kn", "ko", "kr", "ks", "ku", "kv", "kw", "ky",
  "la", "lb", "lg", "li", "ln", "lo", "lt", "lu", "lv",
  "mg", "mh", "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my",
  "na", "nb", "nd", "ne", "ng", "nl", "nn", "no", "nr", "nv", "ny",
  "oc", "oj", "om", "or", "os",
  "pa", "pi", "pl", "ps", "pt",
  "qu",
  "rm", "rn", "ro", "ru", "rw",
  "sa", "sc", "sd", "se", "sg", "si", "sk", "sl", "sm", "sn", "so", "sq", "sr", "ss", "st", "su", "sv", "sw",
  "ta", "te", "tg", "th", "ti", "tk", "tl", "tn", "to", "tr", "ts", "tt", "tw", "ty",
  "ug", "uk", "ur", "uz",
  "ve", "vi", "vo",
  "wa", "wo",
  "xh",
  "yi", "yo",
  "za", "zh", "zu",
]);

type SignalSource = "html-lang" | "content-language" | "hreflang" | "locale-link";

type LanguageSignal = {
  source: SignalSource;
  tag: string;
  href: string | null;
};

type SiteLanguageReport = {
  ok: true;
  requestedUrl: string;
  finalUrl: string;
  httpStatus: number;
  pageLanguageTags: string[];
  versionTags: string[];
  hasDefaultAlternate: boolean;
  signals: LanguageSignal[];
  textSample: string;
  notes: string[];
};

type SiteLanguageError = {
  ok: false;
  requestedUrl: string;
  error: string;
};

function blockedAddress(ip: string): boolean {
  const normalized = ip.toLowerCase().replace(/^\[|\]$/g, "");
  if (normalized.startsWith("::ffff:")) {
    return blockedAddress(normalized.slice(7));
  }
  if (isIP(normalized) === 4) {
    const [a = 0, b = 0] = normalized.split(".").map((part) => Number(part));
    if (a === 0 || a === 10 || a === 127) return true;
    if (a === 169 && b === 254) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 100 && b >= 64 && b <= 127) return true;
    if (a >= 224) return true;
    return false;
  }
  if (normalized === "::1" || normalized === "::") return true;
  if (/^f[cd]/.test(normalized)) return true;
  if (normalized.startsWith("fe80") || normalized.startsWith("ff")) return true;
  return false;
}

function blockedHostname(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/\.$/, "");
  if (
    host === "localhost" ||
    host.endsWith(".localhost") ||
    host.endsWith(".local") ||
    host.endsWith(".localdomain") ||
    host.endsWith(".internal")
  ) {
    return true;
  }
  return false;
}

async function assertPublicHttpUrl(raw: string): Promise<URL> {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error("The URL is not valid.");
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("Only http and https URLs are allowed.");
  }
  if (url.username || url.password) {
    throw new Error("URLs with a username or password are not allowed.");
  }
  if (url.port && url.port !== "80" && url.port !== "443") {
    throw new Error("Only ports 80 and 443 are allowed.");
  }
  const hostname = url.hostname.replace(/^\[|\]$/g, "");
  if (!hostname || blockedHostname(hostname)) {
    throw new Error("That host is not a public website.");
  }
  if (isIP(hostname)) {
    if (blockedAddress(hostname)) throw new Error("That address is not a public website.");
    return url;
  }
  const records = await lookup(hostname, { all: true, verbatim: true });
  if (records.length === 0) throw new Error("The host did not resolve.");
  if (records.some((record) => blockedAddress(record.address))) {
    throw new Error("That host does not resolve to a public address.");
  }
  return url;
}

function normalizeInputUrl(raw: string | undefined): string {
  const value = (raw ?? "").trim();
  if (!value) return DEFAULT_URL;
  const withScheme = /^[a-z][a-z0-9+.-]*:/i.test(value) ? value : `https://${value}`;
  return new URL(withScheme).toString();
}

function attrs(tag: string): Map<string, string> {
  const found = new Map<string, string>();
  const pattern = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/g;
  for (const match of tag.matchAll(pattern)) {
    const name = (match[1] ?? "").toLowerCase();
    const value = match[2] ?? match[3] ?? match[4] ?? "";
    if (name) found.set(name, value);
  }
  return found;
}

function cleanTag(tag: string): string {
  return tag.trim().toLowerCase();
}

function isLanguageTag(tag: string): boolean {
  const primary = tag.split("-")[0] ?? "";
  return ISO639_1.has(primary);
}

function pushSignal(signals: LanguageSignal[], signal: LanguageSignal): void {
  if (signals.length >= MAX_SIGNALS) return;
  const key = `${signal.source}|${signal.tag}|${signal.href ?? ""}`;
  const exists = signals.some((item) => `${item.source}|${item.tag}|${item.href ?? ""}` === key);
  if (!exists) signals.push(signal);
}

function uniqueTags(tags: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const tag of tags) {
    const key = tag.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(tag);
  }
  return result;
}

function collectSignals(html: string, pageUrl: string, contentLanguage: string | null): {
  signals: LanguageSignal[];
  hasDefaultAlternate: boolean;
} {
  const signals: LanguageSignal[] = [];
  let hasDefaultAlternate = false;

  const htmlTag = html.match(/<html\b[^>]*>/i)?.[0];
  if (htmlTag) {
    const lang = attrs(htmlTag).get("lang");
    if (lang && isLanguageTag(cleanTag(lang))) {
      pushSignal(signals, { source: "html-lang", tag: cleanTag(lang), href: pageUrl });
    }
  }

  if (contentLanguage) {
    for (const part of contentLanguage.split(",")) {
      const tag = cleanTag(part.split(";")[0] ?? "");
      if (tag && isLanguageTag(tag)) {
        pushSignal(signals, { source: "content-language", tag, href: null });
      }
    }
  }

  for (const tag of html.match(/<link\b[^>]*>/gi) ?? []) {
    const map = attrs(tag);
    const rel = (map.get("rel") ?? "").toLowerCase();
    if (!rel.split(/\s+/).includes("alternate")) continue;
    const hreflang = cleanTag(map.get("hreflang") ?? "");
    if (!hreflang) continue;
    const href = map.get("href") ?? null;
    if (hreflang === "x-default") {
      hasDefaultAlternate = true;
      continue;
    }
    if (!isLanguageTag(hreflang)) continue;
    pushSignal(signals, { source: "hreflang", tag: hreflang, href });
  }

  for (const tag of html.match(/<a\b[^>]*>/gi) ?? []) {
    const map = attrs(tag);
    const hreflang = cleanTag(map.get("hreflang") ?? "");
    const hrefRaw = map.get("href");
    if (!hrefRaw) continue;
    let target: URL;
    try {
      target = new URL(hrefRaw, pageUrl);
    } catch {
      continue;
    }
    if (hreflang === "x-default") {
      hasDefaultAlternate = true;
    } else if (hreflang && isLanguageTag(hreflang)) {
      pushSignal(signals, { source: "hreflang", tag: hreflang, href: target.toString() });
      continue;
    }
    if (target.hostname !== new URL(pageUrl).hostname) continue;
    const segment = target.pathname.split("/").filter(Boolean)[0] ?? "";
    const pathIsLocaleRoot = /^\/[a-z]{2,3}(?:-[a-z0-9]{2,8})?\/?$/i.test(target.pathname);
    if (!pathIsLocaleRoot || !isLanguageTag(cleanTag(segment))) continue;
    pushSignal(signals, {
      source: "locale-link",
      tag: cleanTag(segment),
      href: target.toString(),
    });
  }

  return { signals, hasDefaultAlternate };
}

function visibleText(html: string): string {
  return html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ")
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 400);
}

async function fetchPage(start: string): Promise<{
  finalUrl: string;
  httpStatus: number;
  contentLanguage: string | null;
  body: string;
  notes: string[];
}> {
  let current = start;
  const notes: string[] = [];
  for (let hop = 0; hop <= MAX_REDIRECTS; hop += 1) {
    const url = await assertPublicHttpUrl(current);
    const response = await fetch(url, {
      redirect: "manual",
      signal: AbortSignal.timeout(8_000),
      headers: {
        accept: "text/html,application/xhtml+xml;q=0.9,text/plain;q=0.5",
        "user-agent": "languages-on-site/0.1",
      },
    });
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) {
        throw new Error(`Redirect ${response.status} had no Location header.`);
      }
      if (hop === MAX_REDIRECTS) throw new Error("The page redirected too many times.");
      current = new URL(location, url).toString();
      continue;
    }
    const length = Number(response.headers.get("content-length") ?? "0");
    if (Number.isFinite(length) && length > 1_000_000) {
      notes.push("The response is larger than 1 MB, so the body was not read.");
      return {
        finalUrl: url.toString(),
        httpStatus: response.status,
        contentLanguage: response.headers.get("content-language"),
        body: "",
        notes,
      };
    }
    const raw = await response.text();
    if (raw.length > MAX_HTML_CHARS) notes.push("HTML was truncated before scanning.");
    const contentType = response.headers.get("content-type") ?? "";
    if (contentType && !/html|xml|text\/plain/i.test(contentType)) {
      notes.push(`Content-Type is ${contentType}. Tags were still scanned.`);
    }
    return {
      finalUrl: url.toString(),
      httpStatus: response.status,
      contentLanguage: response.headers.get("content-language"),
      body: raw.slice(0, MAX_HTML_CHARS),
      notes,
    };
  }
  throw new Error("The page redirected too many times.");
}

export default defineTool({
  description:
    "Fetch one public page and return language-version evidence: html lang, Content-Language, hreflang alternates, and same-host locale homepage links. Omit url to check https://example.com. This does not decide the reply wording.",
  effect: "read",
  inputSchema: z.object({
    url: z
      .string()
      .trim()
      .min(1)
      .max(2000)
      .optional()
      .describe("Page URL. Omit it to check https://example.com."),
  }),
  async execute({ url }): Promise<SiteLanguageReport | SiteLanguageError> {
    let requestedUrl = DEFAULT_URL;
    try {
      requestedUrl = normalizeInputUrl(url);
      const page = await fetchPage(requestedUrl);
      const collected = collectSignals(page.body, page.finalUrl, page.contentLanguage);
      const pageLanguageTags = uniqueTags(
        collected.signals
          .filter((signal) => signal.source === "html-lang" || signal.source === "content-language")
          .map((signal) => signal.tag),
      );
      const versionTags = uniqueTags(
        collected.signals
          .filter((signal) => signal.source === "hreflang" || signal.source === "locale-link")
          .map((signal) => signal.tag),
      );
      const notes = [...page.notes];
      if (page.httpStatus < 200 || page.httpStatus >= 300) {
        notes.push(`HTTP status ${page.httpStatus}. Language tags may be missing.`);
      }
      return {
        ok: true,
        requestedUrl,
        finalUrl: page.finalUrl,
        httpStatus: page.httpStatus,
        pageLanguageTags,
        versionTags,
        hasDefaultAlternate: collected.hasDefaultAlternate,
        signals: collected.signals,
        textSample: visibleText(page.body),
        notes,
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : "The page could not be read.";
      return { ok: false, requestedUrl, error: message };
    }
  },
});
