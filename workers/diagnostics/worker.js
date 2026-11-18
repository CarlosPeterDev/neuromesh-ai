import { zipSync } from "fflate";

const maxReportBytes = 256 * 1024;
const decoder = new TextDecoder("utf-8", { fatal: true });

class InvalidReport extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
  }
}

function reply(status, code) {
  return Response.json(
    code ? { ok: false, code } : { ok: true },
    { status, headers: { "Cache-Control": "no-store" } }
  );
}

async function readReport(request) {
  const type = request.headers.get("Content-Type")?.split(";")[0].trim();
  if (type !== "text/plain") throw new InvalidReport(415, "unsupported_format");
  if (Number(request.headers.get("Content-Length")) > maxReportBytes) {
    throw new InvalidReport(413, "report_too_large");
  }
  if (!request.body) throw new InvalidReport(400, "empty_report");
  const reader = request.body.getReader();
  const buffer = new Uint8Array(maxReportBytes);
  let size = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (size + value.length > maxReportBytes) {
        await reader.cancel();
        throw new InvalidReport(413, "report_too_large");
      }
      buffer.set(value, size);
      size += value.length;
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = buffer.subarray(0, size);
  let text;
  try {
    text = decoder.decode(bytes);
  } catch {
    throw new InvalidReport(400, "invalid_encoding");
  }
  if (!text.startsWith("Problem description\n") ||
      !text.includes("\nNeuroMesh AI diagnostic report\n")) {
    throw new InvalidReport(400, "invalid_report");
  }
  return bytes;
}

export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname !== "/report") return reply(404, "not_found");
    if (request.method !== "POST") return reply(405, "method_not_allowed");
    if (!/^\d+:[a-zA-Z0-9_-]+$/.test(env.TELEGRAM_BOT_TOKEN ?? "") ||
        !env.TELEGRAM_CHAT_ID?.trim() ||
        !env.REPORTS_PER_SENDER || !env.REPORTS_PER_LOCATION) {
      return reply(503, "delivery_not_configured");
    }
    try {
      const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
      const sender = await env.REPORTS_PER_SENDER.limit({ key: ip });
      if (!sender.success) return reply(429, "rate_limited");
      const budget = await env.REPORTS_PER_LOCATION.limit({ key: "report" });
      if (!budget.success) return reply(429, "rate_limited");

      const bytes = await readReport(request);
      const zip = zipSync({ "diagnostics.txt": bytes });
      const form = new FormData();
      form.set("chat_id", env.TELEGRAM_CHAT_ID.trim());
      form.set("disable_notification", "true");
      form.set("document", new Blob([zip], { type: "application/zip" }),
        `NeuroMesh-diagnostics-${Date.now()}.zip`);
      const telegram = await fetch(
        `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendDocument`,
        {
          method: "POST", body: form, redirect: "error",
          signal: AbortSignal.timeout(15000),
        }
      );
      const result = await telegram.json().catch(() => null);
      if (telegram.ok && result?.ok === true) return reply(200);
      if (telegram.status === 429) return reply(429, "rate_limited");
      if ([400, 401, 403, 404].includes(telegram.status)) {
        return reply(503, "telegram_rejected_delivery");
      }
      return reply(502, "delivery_unavailable");
    } catch (error) {
      if (error instanceof InvalidReport) return reply(error.status, error.message);
      return reply(502, "delivery_unavailable");
    }
  },
};
