from __future__ import annotations

import json
import sqlite3
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

_SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_type TEXT NOT NULL,
  repo TEXT NOT NULL,
  ref TEXT NOT NULL,
  head_sha TEXT,
  title TEXT,
  status TEXT NOT NULL DEFAULT 'queued',
  conclusion TEXT,
  inputs_json TEXT NOT NULL DEFAULT '{}',
  created_at REAL NOT NULL,
  started_at REAL,
  finished_at REAL,
  worker_log TEXT,
  html_url TEXT,
  coalesce_key TEXT
);
CREATE INDEX IF NOT EXISTS idx_jobs_type_created ON jobs(job_type, created_at);
CREATE INDEX IF NOT EXISTS idx_jobs_sha ON jobs(head_sha);
CREATE INDEX IF NOT EXISTS idx_jobs_coalesce ON jobs(coalesce_key, status);
"""

_lock = threading.Lock()


@dataclass
class Job:
    id: int
    job_type: str
    repo: str
    ref: str
    head_sha: Optional[str]
    title: Optional[str]
    status: str
    conclusion: Optional[str]
    inputs: dict[str, Any]
    created_at: float
    started_at: Optional[float]
    finished_at: Optional[float]
    worker_log: Optional[str]
    html_url: Optional[str]
    coalesce_key: Optional[str]

    def as_run(self) -> dict[str, Any]:
        """Shape compatible with sim/ship.py GHA run dict."""
        st = "completed" if self.status in ("completed", "cancelled") else (
            "in_progress" if self.status == "running" else "queued"
        )
        return {
            "id": self.id,
            "status": st,
            "conclusion": self.conclusion if st == "completed" else None,
            "html_url": self.html_url or f"/jobs/{self.id}",
            "head_sha": self.head_sha,
            "created_at": _iso(self.created_at),
            "display_title": self.title or self.job_type,
            "name": self.title or self.job_type,
        }


def _iso(ts: float) -> str:
    from datetime import datetime, timezone

    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _row_to_job(row: sqlite3.Row) -> Job:
    return Job(
        id=row["id"],
        job_type=row["job_type"],
        repo=row["repo"],
        ref=row["ref"],
        head_sha=row["head_sha"],
        title=row["title"],
        status=row["status"],
        conclusion=row["conclusion"],
        inputs=json.loads(row["inputs_json"] or "{}"),
        created_at=row["created_at"],
        started_at=row["started_at"],
        finished_at=row["finished_at"],
        worker_log=row["worker_log"],
        html_url=row["html_url"],
        coalesce_key=row["coalesce_key"],
    )


class JobStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._conn() as conn:
            conn.executescript(_SCHEMA)

    @contextmanager
    def _conn(self):
        with _lock:
            conn = sqlite3.connect(self.path, timeout=30)
            conn.row_factory = sqlite3.Row
            try:
                yield conn
                conn.commit()
            finally:
                conn.close()

    def create(
        self,
        *,
        job_type: str,
        repo: str,
        ref: str,
        inputs: Optional[dict[str, Any]] = None,
        head_sha: Optional[str] = None,
        title: Optional[str] = None,
        coalesce_key: Optional[str] = None,
        cancel_queued_same_key: bool = False,
    ) -> Job:
        now = time.time()
        inputs = inputs or {}
        with self._conn() as conn:
            if cancel_queued_same_key and coalesce_key:
                conn.execute(
                    "UPDATE jobs SET status='cancelled', conclusion='cancelled', finished_at=? "
                    "WHERE coalesce_key=? AND status='queued'",
                    (now, coalesce_key),
                )
            cur = conn.execute(
                """
                INSERT INTO jobs (job_type, repo, ref, head_sha, title, inputs_json, created_at, coalesce_key)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (job_type, repo, ref, head_sha, title, json.dumps(inputs), now, coalesce_key),
            )
            jid = int(cur.lastrowid)
        return self.get(jid)

    def get(self, job_id: int) -> Job:
        with self._conn() as conn:
            row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            raise KeyError(job_id)
        return _row_to_job(row)

    def claim_next(self) -> Optional[Job]:
        now = time.time()
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM jobs WHERE status='queued' ORDER BY id ASC LIMIT 1"
            ).fetchone()
            if not row:
                return None
            conn.execute(
                "UPDATE jobs SET status='running', started_at=? WHERE id=? AND status='queued'",
                (now, row["id"]),
            )
        return self.get(int(row["id"]))

    def finish(
        self, job_id: int, *, conclusion: str, log: str = "", html_url: Optional[str] = None
    ) -> None:
        now = time.time()
        with self._conn() as conn:
            if html_url:
                conn.execute(
                    """
                    UPDATE jobs SET status='completed', conclusion=?, finished_at=?, worker_log=?, html_url=?
                    WHERE id=?
                    """,
                    (conclusion, now, log[-500_000:], html_url, job_id),
                )
            else:
                conn.execute(
                    """
                    UPDATE jobs SET status='completed', conclusion=?, finished_at=?, worker_log=?
                    WHERE id=?
                    """,
                    (conclusion, now, log[-500_000:], job_id),
                )

    def cancel(self, job_id: int) -> None:
        now = time.time()
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE jobs SET status='cancelled', conclusion='cancelled', finished_at=?
                WHERE id=? AND status IN ('queued', 'running')
                """,
                (now, job_id),
            )

    def find_jobs(
        self,
        *,
        job_type: Optional[str] = None,
        created_after: Optional[float] = None,
        title_contains: Optional[str] = None,
        head_sha: Optional[str] = None,
        ref: Optional[str] = None,
        limit: int = 20,
    ) -> list[Job]:
        clauses = ["1=1"]
        params: list[Any] = []
        if job_type:
            clauses.append("job_type=?")
            params.append(job_type)
        if created_after is not None:
            clauses.append("created_at>=?")
            params.append(created_after)
        if title_contains:
            clauses.append("title LIKE ?")
            params.append(f"%{title_contains}%")
        if head_sha:
            clauses.append("head_sha=?")
            params.append(head_sha)
        if ref:
            clauses.append("ref=?")
            params.append(ref)
        sql = f"SELECT * FROM jobs WHERE {' AND '.join(clauses)} ORDER BY id DESC LIMIT ?"
        params.append(limit)
        with self._conn() as conn:
            rows = conn.execute(sql, params).fetchall()
        jobs = [_row_to_job(r) for r in rows]
        if title_contains:
            jobs = [j for j in jobs if title_contains in (j.title or "")]
        return jobs