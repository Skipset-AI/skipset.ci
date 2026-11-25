from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel, Field

from controller.db import JobStore
from controller.worker import Worker

logger = logging.getLogger(__name__)

DB_PATH = Path(os.environ.get("SKIPSET_CI_DB", "/var/lib/skipset-ci/jobs.sqlite3"))
store = JobStore(DB_PATH)
worker = Worker(store)

REPO_MAP = {
    "Skipset-AI/skipset.data": "data",
    "skipset-ai/skipset.data": "data",
    "Skipset-AI/skipset.backend": "backend",
    "skipset-ai/skipset.backend": "backend",
    "Skipset-AI/skipset.web": "web",
    "skipset-ai/skipset.web": "web",
}


class JobCreate(BaseModel):
    ref: str = "dev"
    inputs: dict[str, str] = Field(default_factory=dict)
    head_sha: Optional[str] = None
    title: Optional[str] = None
    coalesce: bool = False


app = FastAPI(title="Skipset CI", version="1.0.0")


@app.on_event("startup")
def _startup() -> None:
    worker.start()


@app.on_event("shutdown")
def _shutdown() -> None:
    worker.stop()


def _auth_bearer(authorization: Optional[str]) -> None:
    secret = os.environ.get("SKIPSET_CI_HOOK_SECRET", "")
    if not secret:
        return
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing bearer token")
    token = authorization.removeprefix("Bearer ").strip()
    if not hmac.compare_digest(token, secret):
        raise HTTPException(401, "invalid token")


def _parse_github_ts(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


@app.post("/v1/jobs/{job_type}")
def create_job(
    job_type: str,
    body: JobCreate,
    authorization: Optional[str] = Header(None),
    x_repo: Optional[str] = Header(None, alias="X-Skipset-Repo"),
) -> dict[str, Any]:
    _auth_bearer(authorization)
    repo = x_repo or os.environ.get("SKIPSET_CI_DEFAULT_REPO", "Skipset-AI/skipset.data")
    title = body.title
    if job_type == "sim-fix" and "run_id" in body.inputs:
        title = f"sim-fix {body.inputs['run_id']}"
    coalesce_key = None
    cancel = False
    if job_type == "data-deploy" and body.inputs.get("environment", "prod") == "prod":
        coalesce_key = f"deploy-prod"
        cancel = body.coalesce
    job = store.create(
        job_type=job_type,
        repo=repo,
        ref=body.ref,
        inputs=body.inputs,
        head_sha=body.head_sha,
        title=title,
        coalesce_key=coalesce_key,
        cancel_queued_same_key=cancel,
    )
    return {"job_id": job.id, "html_url": job.html_url or f"/v1/jobs/{job.id}"}


@app.get("/v1/jobs/{job_id}")
def get_job(job_id: int) -> dict[str, Any]:
    job = store.get(job_id)
    return job.as_run() | {"job_type": job.job_type, "inputs": job.inputs, "worker_log": job.worker_log}


@app.get("/v1/jobs/{job_id}/jobs")
def list_job_steps(job_id: int) -> dict[str, Any]:
    job = store.get(job_id)
    return {
        "jobs": [
            {
                "name": job.job_type,
                "status": "completed" if job.status in ("completed", "cancelled") else job.status,
                "conclusion": job.conclusion,
            }
        ]
    }


@app.post("/v1/jobs/{job_id}/cancel")
def cancel_job(job_id: int, authorization: Optional[str] = Header(None)) -> dict[str, Any]:
    _auth_bearer(authorization)
    store.cancel(job_id)
    return {"ok": True}


@app.get("/v1/jobs")
def query_jobs(
    job_type: Optional[str] = None,
    created_after: Optional[str] = None,
    title_contains: Optional[str] = None,
    head_sha: Optional[str] = None,
    branch: Optional[str] = None,
) -> dict[str, Any]:
    after_ts = _parse_github_ts(created_after) if created_after else None
    jobs = store.find_jobs(
        job_type=job_type,
        created_after=after_ts,
        title_contains=title_contains,
        head_sha=head_sha,
        ref=branch,
    )
    return {"workflow_runs": [j.as_run() for j in jobs]}


@app.post("/hooks/github")
async def github_webhook(
    request: Request,
    x_hub_signature_256: Optional[str] = Header(None),
    x_github_event: Optional[str] = Header(None),
) -> dict[str, Any]:
    body = await request.body()
    secret = os.environ.get("GITHUB_WEBHOOK_SECRET", "")
    if secret:
        if not x_hub_signature_256 or not x_hub_signature_256.startswith("sha256="):
            raise HTTPException(401, "missing signature")
        digest = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(f"sha256={digest}", x_hub_signature_256):
            raise HTTPException(401, "bad signature")
    payload = json.loads(body)
    repo_full = (payload.get("repository") or {}).get("full_name", "")
    prefix = REPO_MAP.get(repo_full)
    if not prefix:
        return {"ignored": True, "reason": "repo not configured"}

    if x_github_event == "pull_request":
        action = payload.get("action")
        if action not in ("opened", "synchronize", "reopened", "ready_for_review"):
            return {"ignored": True, "action": action}
        pr = payload.get("pull_request") or {}
        head = pr.get("head") or {}
        store.create(
            job_type=f"{prefix}-verify",
            repo=repo_full,
            ref=head.get("ref") or "dev",
            head_sha=head.get("sha"),
            title=pr.get("title"),
        )
        return {"enqueued": f"{prefix}-verify"}

    if x_github_event == "push":
        ref = payload.get("ref", "")
        after = payload.get("after")
        if ref == "refs/heads/main" and prefix == "data":
            store.create(
                job_type="data-deploy",
                repo=repo_full,
                ref="main",
                head_sha=after,
                inputs={"environment": "prod"},
                coalesce_key="deploy-prod",
                cancel_queued_same_key=True,
            )
            return {"enqueued": "data-deploy"}
        if ref == "refs/heads/dev" and prefix == "web":
            store.create(
                job_type="web-verify",
                repo=repo_full,
                ref="dev",
                head_sha=after,
            )
            return {"enqueued": "web-verify"}
        if ref in ("refs/heads/main", "refs/heads/dev") and prefix == "backend":
            branch = ref.removeprefix("refs/heads/")
            store.create(
                job_type="backend-deploy",
                repo=repo_full,
                ref=branch,
                head_sha=after,
            )
            return {"enqueued": "backend-deploy"}

    return {"ignored": True, "event": x_github_event}


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"ok": "true"}