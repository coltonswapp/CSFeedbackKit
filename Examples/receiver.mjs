// Local test receiver for CSFeedbackKit payloads (JSON encoding).
// Usage: node Examples/receiver.mjs [port]   → POST http://<your-mac>:8787/
// Prints a summary and writes each payload + decoded attachments to ./received/<id>/.

import { createServer } from "node:http";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const port = Number(process.argv[2] ?? 8787);

createServer((req, res) => {
  if (req.method !== "POST") return res.writeHead(405).end();
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    let body;
    try {
      body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      return res.writeHead(400, { "Content-Type": "text/plain" }).end("invalid JSON");
    }
    const dir = join("received", String(body.id ?? Date.now()));
    mkdirSync(dir, { recursive: true });
    for (const a of body.attachments ?? []) {
      if (a.data) writeFileSync(join(dir, a.filename), Buffer.from(a.data, "base64"));
      delete a.data;
    }
    writeFileSync(join(dir, "payload.json"), JSON.stringify(body, null, 2));
    console.log(
      `[${new Date().toISOString()}] ${body.id} idem=${req.headers["idempotency-key"] ?? "-"}`,
      `\n  note: ${body.note}\n  tags: ${(body.tags ?? []).map((t) => t.id).join(", ")}`,
      `\n  custom: ${JSON.stringify(body.custom)}\n  saved: ${dir}`,
    );
    res.writeHead(202, { "Content-Type": "application/json" }).end(JSON.stringify({ id: body.id }));
  });
}).listen(port, () => console.log(`CSFeedbackKit receiver on :${port}`));
