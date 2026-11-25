from __future__ import annotations

import logging
import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional

from controller.db import JobStore

logger = logging.getLogger(__name__)

_PIPELINES = Path(__file__).resolve().parent.parent / "pipelines"
_RUN_JOB = _PIPELINES / "run-job.sh"


def _pipeline_for(job_type: str) -> str:
    mapping = {
        "data-verify": "data-verify.sh",
        "data-deploy": "data-deploy.sh",
        "sim-fix": "sim-fix.sh",
        "backend-verify": "backend-verify.sh",
        "backend-deploy": "backend-deploy.sh",
        "web-verify": "web-verify.sh",
        "web-sync": "web-sync.sh",
    }
    name = mapping.get(job_type)
    if not name:
        raise ValueError(f"unknown job type: {job_type}")
    return str(_PIPELINES / name)


class Worker:
    def __init__(self, store: JobStore) -> None:
        self.store = store
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._loop, name="skipset-ci-worker", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)

    def _loop(self) -> None:
        while not self._stop.is_set():
            job = self.store.claim_next()
            if not job:
                time.sleep(1.0)
                continue
            self._run(job.id)

    def _run(self, job_id: int) -> None:
        job = self.store.get(job_id)
        log_path = Path(os.environ.get("SKIPSET_CI_LOG_DIR", "/var/log/skipset-ci")) / f"job-{job_id}.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env.update(
            {
                "JOB_ID": str(job.id),
                "JOB_TYPE": job.job_type,
                "JOB_REPO": job.repo,
                "JOB_REF": job.ref,
                "JOB_SHA": job.head_sha or "",
                "JOB_INPUTS_JSON": __import__("json").dumps(job.inputs),
                "SKIPSET_CI_PUBLIC_URL": os.environ.get("SKIPSET_CI_PUBLIC_URL", ""),
            }
        )
        try:
            pipeline = _pipeline_for(job.job_type)
            with open(log_path, "w", encoding="utf-8") as logf:
                proc = subprocess.run(
                    ["bash", str(_RUN_JOB), pipeline],
                    env=env,
                    stdout=logf,
                    stderr=subprocess.STDOUT,
                    timeout=int(os.environ.get("SKIPSET_CI_JOB_TIMEOUT", "7200")),
                )
            conclusion = "success" if proc.returncode == 0 else "failure"
        except subprocess.TimeoutExpired:
            conclusion = "failure"
            log_path.write_text("job timed out\n", encoding="utf-8")
        except Exception as exc:
            conclusion = "failure"
            log_path.write_text(f"worker error: {exc}\n", encoding="utf-8")
        log = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
        pub = os.environ.get("SKIPSET_CI_PUBLIC_URL", "").rstrip("/")
        html_url = f"{pub}/v1/jobs/{job_id}" if pub else None
        self.store.finish(job_id, conclusion=conclusion, log=log, html_url=html_url)
        logger.info("job %s %s -> %s", job_id, job.job_type, conclusion)