# Cutover checklist

## Before merge

- [x] CI host running; `curl https://ci…/healthz`
- [x] CodeBuild project `skipset-data-image` green on manual run
- [x] `SKIPSET_CI_URL` + `SKIPSET_CI_HOOK_SECRET` loaded via Secrets Manager on data API
- [x] Webhooks registered for 3 repos

## Merge order

1. `skipset.ci` (this repo) deployed to `/opt/skipset-ci`
2. `skipset.data` — sim/ci wiring + delete workflows + `scripts/ci_*.py`
3. `skipset.backend` / `skipset.web` — workflow deletes only (pipelines live here)

## After merge

- [ ] GitHub → disable Actions on each repo
- [ ] Billing → Actions: confirm $0 new usage
- [ ] Test: PR opens → `data-verify` job queued
- [ ] Test: push `main` on data → `data-deploy` coalesced
- [ ] Test: admin sim fix → job id returned, PR opened

## Rollback (emergency only)

Re-add `.github/workflows` from git history and re-enable Actions. Not supported in normal ops.