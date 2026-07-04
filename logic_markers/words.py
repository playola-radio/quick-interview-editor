"""Word / segment model shared across transcription, editing, and slicing.

WhisperX gives per-word start AND end times grouped into segments (roughly
sentences). We assign stable ids — word id and segment id — so an edited
transcript can be mapped back to exact audio positions by bookkeeping rather
than fuzzy guesswork.
"""

from __future__ import annotations

from dataclasses import dataclass

_HEADER = (
    "# Delete lines/chunks you don't want. Blank line = split into a new file.\n"
    "# Keep the [n] tag at the start of each line; edit the words after it freely.\n"
)


@dataclass(frozen=True)
class Word:
    id: int
    text: str
    start: float
    end: float | None = None

    def to_dict(self) -> dict:
        return {"id": self.id, "text": self.text, "start": self.start, "end": self.end}

    @classmethod
    def from_dict(cls, d: dict) -> "Word":
        return cls(id=d["id"], text=d["text"], start=d["start"], end=d.get("end"))


@dataclass(frozen=True)
class Segment:
    id: int
    word_ids: tuple[int, ...]
    text: str

    def to_dict(self) -> dict:
        return {"id": self.id, "word_ids": list(self.word_ids), "text": self.text}

    @classmethod
    def from_dict(cls, d: dict) -> "Segment":
        return cls(id=d["id"], word_ids=tuple(d["word_ids"]), text=d["text"])


@dataclass(frozen=True)
class Transcript:
    words: tuple[Word, ...]
    segments: tuple[Segment, ...]

    def word(self, word_id: int) -> Word:
        return self._by_id[word_id]

    @property
    def _by_id(self) -> dict[int, Word]:
        return {w.id: w for w in self.words}

    def to_dict(self) -> dict:
        return {
            "words": [w.to_dict() for w in self.words],
            "segments": [s.to_dict() for s in self.segments],
        }

    @classmethod
    def from_dict(cls, d: dict) -> "Transcript":
        return cls(
            words=tuple(Word.from_dict(w) for w in d["words"]),
            segments=tuple(Segment.from_dict(s) for s in d["segments"]),
        )


def render_transcript(transcript: Transcript) -> str:
    """Render the editable `[n] words...` transcript file."""
    lines = [_HEADER]
    for seg in transcript.segments:
        lines.append(f"[{seg.id}] {seg.text}")
    return "\n".join(lines) + "\n"
