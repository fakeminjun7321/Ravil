import { DEFAULT_ALT_DB } from "../../../src/alt-adapter.mjs";
import { DEFAULT_LECTURE_OS_DB } from "../../db/src/index.ts";
import { syncAltOnce } from "./index.ts";

const [command] = process.argv.slice(2);
const altDatabasePath = process.env.ALT_DB || DEFAULT_ALT_DB;
const lectureOsDatabasePath = process.env.LECTURE_OS_DB || DEFAULT_LECTURE_OS_DB;

async function runOnce(): Promise<void> {
  const result = await syncAltOnce({ altDatabasePath, lectureOsDatabasePath });
  console.log(JSON.stringify(result, null, 2));
}

if (command === "sync") {
  await runOnce();
} else if (command === "watch") {
  const intervalMs = Number(process.env.ALT_SYNC_INTERVAL_MS || 30_000);
  let stopping = false;
  process.once("SIGINT", () => { stopping = true; });
  process.once("SIGTERM", () => { stopping = true; });
  while (!stopping) {
    await runOnce();
    if (!stopping) await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
} else {
  throw new Error("Usage: cli.ts <sync|watch>");
}
