import { defineEval, includes } from "@grok/agent-sdk/evals";

export default defineEval({
  tags: ["smoke"],
  description: "example.com has no declared language versions.",
  async test(t) {
    await t.send(
      "Проверь сайт https://example.com: собери основные языки, на которых есть версии, и верни краткий список.",
    );
    t.succeeded();
    t.calledTool("list_site_languages", {
      output: (value) => {
        if (!value || typeof value !== "object") return false;
        const report = value as { ok?: boolean; finalUrl?: string; versionTags?: unknown };
        return (
          report.ok === true &&
          typeof report.finalUrl === "string" &&
          report.finalUrl.includes("example.com") &&
          Array.isArray(report.versionTags)
        );
      },
    });
    t.check(t.reply, includes(/example\.com/i));
  },
});
