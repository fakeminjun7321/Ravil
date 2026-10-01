export interface NormalizedTranscriptSegment {
  id: string;
  startMs: number;
  endMs: number;
  text: string;
  speakerId: string | null;
  provenance: {
    provider: string;
    externalSourceId: string;
    chunkIndex: number;
    segmentIndex: number;
  };
}

export interface NormalizedLectureInput {
  schemaVersion: number;
  source: {
    provider: string;
    externalId: string;
    importedAt: string;
  };
  lecture: {
    externalId: string;
    title: string;
    lectureDate: string;
    sourceStatus: string;
  };
  audio: null | {
    externalId: string;
    fileRefId: string | null;
    path: string | null;
    originalName: string | null;
    mimeType: string | null;
    bytes: number | null;
  };
  transcript: {
    externalId: string;
    segments: NormalizedTranscriptSegment[];
  };
  altSummary: {
    externalId: string | null;
    text: string;
  };
}

export interface ImportResult {
  lectureId: string;
  externalSourceId: string;
  created: boolean;
  segmentCount: number;
  evidenceCount: number;
  importRunId: string;
}
