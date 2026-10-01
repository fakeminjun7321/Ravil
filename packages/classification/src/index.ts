import { randomUUID } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";

export interface TimetableConfig {
  semester: { name: string; startsAt: string; endsAt: string };
  courses: Array<{
    name: string;
    professorName?: string;
    color?: string;
    schedules?: Array<{
      isoWeekday: number;
      startsAt: string;
      endsAt: string;
      timezone?: string;
      location?: string;
      source?: string;
    }>;
  }>;
}

export interface ClassificationResult {
  lectureId: string;
  assignedCourseId: string | null;
  confidence: number | null;
  method: "deterministic-score-v1" | "unclassified";
  reason: string;
  candidates: Array<{ courseId: string; courseName: string; score: number; reasons: string[] }>;
}

export function configureTimetable(database: DatabaseSync, config: TimetableConfig): object {
  validateConfig(config);
  const semesterId = randomUUID();
  database.prepare(`
    INSERT INTO semesters (id, name, starts_at, ends_at) VALUES (?, ?, ?, ?)
    ON CONFLICT(name, starts_at, ends_at) DO UPDATE SET name = excluded.name
  `).run(semesterId, config.semester.name, config.semester.startsAt, config.semester.endsAt);
  const semester = database.prepare(
    "SELECT id FROM semesters WHERE name = ? AND starts_at = ? AND ends_at = ?",
  ).get(config.semester.name, config.semester.startsAt, config.semester.endsAt) as { id: string };

  let scheduleCount = 0;
  const courseIds: string[] = [];
  for (const course of config.courses) {
    database.prepare(`
      INSERT INTO courses (id, semester_id, name, professor_name, color) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(semester_id, name) DO UPDATE SET
        professor_name = excluded.professor_name, color = excluded.color
    `).run(randomUUID(), semester.id, course.name, course.professorName ?? null, course.color ?? null);
    const stored = database.prepare(
      "SELECT id FROM courses WHERE semester_id = ? AND name = ?",
    ).get(semester.id, course.name) as { id: string };
    courseIds.push(stored.id);
    for (const schedule of course.schedules ?? []) {
      database.prepare(`
        INSERT INTO course_schedules
          (id, course_id, iso_weekday, start_minute, end_minute, timezone, location, source)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(course_id, iso_weekday, start_minute, end_minute) DO UPDATE SET
          timezone = excluded.timezone, location = excluded.location, source = excluded.source
      `).run(
        randomUUID(), stored.id, schedule.isoWeekday, parseClock(schedule.startsAt),
        parseClock(schedule.endsAt), schedule.timezone ?? "Asia/Seoul",
        schedule.location ?? null, schedule.source ?? "manual",
      );
      scheduleCount += 1;
    }
  }
  return { semesterId: semester.id, courseIds, courseCount: courseIds.length, scheduleCount };
}

export function classifyLecture(database: DatabaseSync, lectureId: string): ClassificationResult {
  const lecture = database.prepare(`
    SELECT id, title, lecture_date AS lectureDate, started_at AS startedAt
    FROM lectures WHERE id = ?
  `).get(lectureId) as { id: string; title: string; lectureDate: string; startedAt: string | null } | undefined;
  if (!lecture) throw new Error(`Lecture not found: ${lectureId}`);
  const courses = database.prepare(`
    SELECT c.id, c.name, s.starts_at AS semesterStarts, s.ends_at AS semesterEnds
    FROM courses c JOIN semesters s ON s.id = c.semester_id
    WHERE ? BETWEEN s.starts_at AND s.ends_at
  `).all(lecture.lectureDate) as Array<{ id: string; name: string; semesterStarts: string; semesterEnds: string }>;

  const candidates = courses.map((course) => scoreCourse(database, lecture, course))
    .filter((candidate) => candidate.score > 0)
    .sort((a, b) => b.score - a.score);
  const version = "deterministic-score-v1";
  database.prepare("DELETE FROM lecture_classification_candidates WHERE lecture_id = ? AND classifier_version = ?")
    .run(lecture.id, version);
  const insertCandidate = database.prepare(`
    INSERT INTO lecture_classification_candidates
      (id, lecture_id, course_id, score, reasons_json, classifier_version, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `);
  for (const candidate of candidates) {
    insertCandidate.run(
      randomUUID(), lecture.id, candidate.courseId, candidate.score,
      JSON.stringify(candidate.reasons), version, new Date().toISOString(),
    );
  }

  const top = candidates[0];
  const runnerUp = candidates[1];
  const assign = Boolean(top && top.score >= 0.6 && (!runnerUp || top.score - runnerUp.score >= 0.15));
  if (assign) {
    database.prepare(`
      UPDATE lectures SET course_id = ?, classification_confidence = ?, classification_method = ?
      WHERE id = ?
    `).run(top.courseId, top.score, version, lecture.id);
  } else {
    database.prepare(`
      UPDATE lectures SET course_id = NULL, classification_confidence = ?, classification_method = ?
      WHERE id = ?
    `).run(top?.score ?? null, candidates.length ? version : "unclassified", lecture.id);
  }
  return {
    lectureId: lecture.id,
    assignedCourseId: assign ? top.courseId : null,
    confidence: top?.score ?? null,
    method: candidates.length ? "deterministic-score-v1" : "unclassified",
    reason: assign ? "top_candidate_clear" : candidates.length ? "ambiguous_or_low_score" : "no_candidate_signal",
    candidates,
  };
}

export function classifyAllLectures(database: DatabaseSync): ClassificationResult[] {
  const lectures = database.prepare("SELECT id FROM lectures ORDER BY lecture_date, created_at").all() as Array<{ id: string }>;
  return lectures.map((lecture) => classifyLecture(database, lecture.id));
}

function scoreCourse(
  database: DatabaseSync,
  lecture: { title: string; startedAt: string | null },
  course: { id: string; name: string },
): { courseId: string; courseName: string; score: number; reasons: string[] } {
  let points = 0;
  const reasons: string[] = [];
  const titleScore = titleSimilarity(lecture.title, course.name);
  if (titleScore === 1) {
    points += 70;
    reasons.push("exact_title_match:+70");
  } else if (titleScore > 0) {
    const titlePoints = Math.round(titleScore * 30);
    points += titlePoints;
    reasons.push(`title_token_overlap:+${titlePoints}`);
  }
  if (lecture.startedAt) {
    const schedules = database.prepare(
      "SELECT iso_weekday AS isoWeekday, start_minute AS startMinute, end_minute AS endMinute, timezone FROM course_schedules WHERE course_id = ?",
    ).all(course.id) as Array<{ isoWeekday: number; startMinute: number; endMinute: number; timezone: string }>;
    if (schedules.some((schedule) => scheduleMatches(lecture.startedAt!, schedule))) {
      points += 60;
      reasons.push("schedule_window_match:+60");
    }
  }
  return { courseId: course.id, courseName: course.name, score: Math.min(points, 100) / 100, reasons };
}

function scheduleMatches(
  startedAt: string,
  schedule: { isoWeekday: number; startMinute: number; endMinute: number; timezone: string },
): boolean {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: schedule.timezone,
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(startedAt));
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const weekday = ({ Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 } as Record<string, number>)[values.weekday];
  const minute = Number(values.hour) * 60 + Number(values.minute);
  return weekday === schedule.isoWeekday && minute >= schedule.startMinute - 15 && minute <= schedule.endMinute + 15;
}

function titleSimilarity(left: string, right: string): number {
  const normalize = (value: string) => value.normalize("NFC").toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
  const normalizedLeft = normalize(left);
  const normalizedRight = normalize(right);
  if (normalizedLeft === normalizedRight) return 1;
  const usefulToken = (token: string) => token.length > 1 && !/^i{1,3}$/i.test(token);
  const leftTokens = new Set(normalizedLeft.split(/\s+/).filter(usefulToken));
  const rightTokens = new Set(normalizedRight.split(/\s+/).filter(usefulToken));
  if (!leftTokens.size || !rightTokens.size) return 0;
  const overlap = [...leftTokens].filter((token) => rightTokens.has(token)).length;
  return overlap / Math.max(leftTokens.size, rightTokens.size);
}

function parseClock(value: string): number {
  const match = /^(\d{2}):(\d{2})$/.exec(value);
  if (!match) throw new Error(`Invalid clock value: ${value}`);
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (hour > 23 || minute > 59) throw new Error(`Invalid clock value: ${value}`);
  return hour * 60 + minute;
}

function validateConfig(config: TimetableConfig): void {
  if (!config.semester?.name || !config.semester.startsAt || !config.semester.endsAt) {
    throw new Error("Semester name, startsAt, and endsAt are required");
  }
  if (!Array.isArray(config.courses) || !config.courses.length) throw new Error("At least one course is required");
  for (const course of config.courses) {
    if (!course.name) throw new Error("Course name is required");
    for (const schedule of course.schedules ?? []) {
      if (!Number.isInteger(schedule.isoWeekday) || schedule.isoWeekday < 1 || schedule.isoWeekday > 7) {
        throw new Error(`Invalid ISO weekday for ${course.name}`);
      }
      if (parseClock(schedule.endsAt) <= parseClock(schedule.startsAt)) {
        throw new Error(`Schedule must end after it starts for ${course.name}`);
      }
    }
  }
}
