import { createServer } from "node:http";

import {
  DEFAULT_LECTURE_OS_DB,
  inspectDatabase,
  getMaterialPage,
  listLectures,
  listMaterials,
  openLectureOsDatabase,
} from "../../../packages/db/src/index.ts";
import { getLectureIntelligence } from "../../../packages/intelligence/src/index.ts";

const port = Number(process.env.PORT || 4310);
const databasePath = process.env.LECTURE_OS_DB || DEFAULT_LECTURE_OS_DB;

const server = createServer((request, response) => {
  response.setHeader("content-type", "application/json; charset=utf-8");
  const database = openLectureOsDatabase(databasePath);
  try {
    if (request.method === "GET" && request.url === "/health") {
      response.end(JSON.stringify({ ok: true, database: inspectDatabase(database) }));
      return;
    }
    if (request.method === "GET" && request.url === "/lectures") {
      response.end(JSON.stringify({ lectures: listLectures(database) }));
      return;
    }
    const intelligenceMatch = request.method === "GET"
      ? /^\/lectures\/([^/]+)\/intelligence$/.exec(request.url || "")
      : null;
    if (intelligenceMatch) {
      const artifact = getLectureIntelligence(database, decodeURIComponent(intelligenceMatch[1]));
      response.statusCode = artifact ? 200 : 404;
      response.end(JSON.stringify(artifact ?? { error: "not_found" }));
      return;
    }
    if (request.method === "GET" && request.url === "/materials") {
      response.end(JSON.stringify({ materials: listMaterials(database) }));
      return;
    }
    const pageMatch = request.method === "GET"
      ? /^\/materials\/([^/]+)\/pages\/(\d+)$/.exec(request.url || "")
      : null;
    if (pageMatch) {
      const page = getMaterialPage(database, decodeURIComponent(pageMatch[1]), Number(pageMatch[2]));
      response.statusCode = page ? 200 : 404;
      response.end(JSON.stringify(page ?? { error: "not_found" }));
      return;
    }
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "not_found" }));
  } finally {
    database.close();
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`Lecture OS API listening on http://127.0.0.1:${port}`);
});
