import assert from "node:assert/strict";
import { test } from "node:test";
import { unzipSync, strFromU8 } from "fflate";
import worker from "./worker.js";

const report = "Problem description\nصوت غير واضح\n\nNeuroMesh AI diagnostic report\nSample logs\n";
const limiter = { async limit() { return { success: true }; } };
const env = {
  TELEGRAM_BOT_TOKEN: ["12", "testing-token"].join(":"),
  TELEGRAM_CHAT_ID: "-999",
  REPORTS_PER_SENDER: limiter,
  REPORTS_PER_LOCATION: limiter,
};
const request = (body = report, type = "text/plain; charset=utf-8") =>
  new Request("https://worker.example/report", {
    method: "POST", body, headers: { "Content-Type": type },
  });

test("forwards one ZIP with exactly the reviewed UTF-8 report", async (t) => {
  t.mock.method(globalThis, "fetch", async (url, options) => {
    assert.equal(new URL(url).origin, "https://api.telegram.org");
    assert.equal(new URL(url).pathname.endsWith("/sendDocument"), true);
    assert.equal(options.body.get("chat_id"), "-999");
    const file = options.body.get("document");
    assert.equal(file.type, "application/zip");
    const files = unzipSync(new Uint8Array(await file.arrayBuffer()));
    assert.deepEqual(Object.keys(files), ["diagnostics.txt"]);
    assert.equal(strFromU8(files["diagnostics.txt"]), report);
    return Response.json({ ok: true });
  });
  const response = await worker.fetch(request(), env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
});

test("validates report format and size before contacting Telegram", async (t) => {
  const outgoing = t.mock.method(globalThis, "fetch");
  assert.equal((await worker.fetch(request("random attachment"), env)).status, 400);
  assert.equal((await worker.fetch(request(report, "application/zip"), env)).status, 415);
  assert.equal((await worker.fetch(request(report.repeat(10000)), env)).status, 413);
  assert.equal(outgoing.mock.callCount(), 0);
});

test("rejects rate limited requests and reports Telegram 400 without secrets", async (t) => {
  const outgoing = t.mock.method(globalThis, "fetch", async () =>
    Response.json({ ok: false, description: "private provider details" }, { status: 400 }));
  const denied = await worker.fetch(request(), {
    ...env,
    REPORTS_PER_SENDER: { async limit() { return { success: false }; } },
  });
  assert.equal(denied.status, 429);
  assert.equal(outgoing.mock.callCount(), 0);
  const response = await worker.fetch(request(), env);
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { ok: false, code: "telegram_rejected_delivery" });
});
