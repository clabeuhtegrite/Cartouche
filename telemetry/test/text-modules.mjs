// Lets Node import a file as the Workers runtime imports a text module: the
// dashboard's page (dashboard/index.html), which dashboard/worker.js imports,
// as a string, its default export. For the tests only:
//
//     node --import ./telemetry/test/text-modules.mjs --test telemetry/test/dashboard.test.js

import { register } from "node:module";
import { isMainThread } from "node:worker_threads";
import { readFile } from "node:fs/promises";

// Node runs the hooks of a module it registers on a thread of their own,
// where this file is loaded again: there it only answers.
if (isMainThread) register(import.meta.url);

export async function load(url, context, nextLoad) {
  if (url.startsWith("file:") && url.endsWith(".html")) {
    const text = await readFile(new URL(url), "utf8");
    return { format: "module", shortCircuit: true, source: `export default ${JSON.stringify(text)};` };
  }
  return nextLoad(url, context);
}
