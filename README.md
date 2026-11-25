# Skipset CI

Replaces GitHub Actions for `skipset.data`, `skipset.backend`, and `skipset.web`.

## Cost target

~**$40–65/mo** (t3.medium controller + CodeBuild for data Docker) vs **~$150–180/mo** Actions overage.

## Quick start (controller host)

```bash
sudo mkdir -p /var/lib/skipset-ci /var/log/skipset-ci
python3 -m venv /opt/skipset-ci/venv
source /opt/skipset-ci/venv/bin/activate
pip install -r /path/to/skipset.ci/requirements.txt

export SKIPSET_CI_DB=/var/lib/skipset-ci/jobs.sqlite3
export SKIPSET_CI_HOOK_SECRET='…'          # same as SKIPSET_CI_HOOK_SECRET on data ECS
export SKIPSET_CI_PUBLIC_URL='https://ci.skipset.ai'
export GITHUB_WEBHOOK_SECRET='…'
export GITHUB_TOKEN='…'                    # read private repos
export CODEBUILD_PROJECT='skipset-data-image'
export AMPLIFY_APP_ID='…'

uvicorn controller.app:app --host 0.0.0.0 --port 8080
```

Install **bun**, **docker** (optional if CodeBuild builds images), **aws cli**, **git**.

## GitHub setup (cutover)

1. Create a GitHub App or org webhook → `POST https://<ci>/hooks/github` (`push`, `pull_request`).
2. **Disable Actions** on all three repos (Settings → Actions → Disable).
3. Branch protection: require external checks when GitHub Checks API is wired (optional phase 2).
4. On **skipset.data** ECS task / secrets: `SKIPSET_CI_URL`, `SKIPSET_CI_HOOK_SECRET`, `GITHUB_SIM_TOKEN` (for sim-fix push).

## Job API (used by sim/fix)

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/jobs/sim-fix` | `{"ref":"dev","inputs":{"run_id":"…"}}` |
| `POST /v1/jobs/data-deploy` | `{"ref":"main","inputs":{"environment":"prod"},"coalesce":true}` |
| `GET /v1/jobs/{id}` | Poll status (GHA-compatible fields) |

## CodeBuild

See [`infra/buildspec-data.yml`](infra/buildspec-data.yml). Project source = GitHub `Skipset-AI/skipset.data`, buildspec in repo or inline.

## Pipelines

Shell scripts under `pipelines/` — invoked by the worker via `run-job.sh`.