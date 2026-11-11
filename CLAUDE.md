# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Shared infrastructure scripts and reusable GitHub Actions workflows for `gideonogegaorg` app repos. There is no build or test suite: the deliverables are bash scripts that run on an Ubuntu EC2 host or an operator workstation, and `workflow_call` workflows that app repos consume as `uses: gideonogegaorg/DevOps/.github/workflows/<name>.yml@main`. Anything merged to `main` goes live for every caller at once. Callers stay on `@main`; introduce a version tag only for a breaking change (removed or renamed inputs, renamed jobs, defaults that fail existing callers), so callers can move to it deliberately.

## Layout rule

Tech-stack agnostic items live at the root (`aws/` for workstation-side AWS provisioning, `ec2/` for host ops). Stack-specific items live under `{stack}/` (`dotnet/`, `java/` is a placeholder). When adding a stack, create `{stack}/ci/` and `{stack}/ec2/` and thin entrypoints at `.github/workflows/{stack}-*.yml`.

## Workflows

- **The real implementation is `.github/workflows/*.yml`.** The files in `dotnet/ci/*.yml` are short reference stubs (input lists), not executed. `dotnet/ci/README.md` documents caller-facing inputs; update it when inputs or defaults change.
- **`dotnet-sonarqube-scan.yml` has two near-identical jobs**, `build` (with Postgres and RabbitMQ service containers) and `build_no_postgres`, selected by `postgres_enabled`. A change to Sonar, test or coverage logic must be made in both.
- SonarCloud branch handling is shared by `dotnet-sonarqube-scan.yml` and `sonarcloud-provision-project.yml` (a manual `workflow_dispatch` that provisions any org repo). The Sonar main branch defaults to `dev`; the scan renames the SonarCloud main branch to match it via the `project_branches/rename` API, and the quality gate is waited on only for pushes to that branch. Keep both workflows consistent.
- Third-party actions are pinned to full commit SHAs with a `# vN` comment. Keep that form when adding or bumping actions; Dependabot (`.github/dependabot.yml`) bumps them weekly.
- **GitHub masks the literal string `true` in inline SSH scripts.** Callers pass `yes`/`no` for flags such as `setup_changed` and `require_postgres`, and `dotnet/ec2/deploy-to-ec2.sh` must never contain the word. Prefer moving remote logic into a script that is SCP'd and run (`remote_deploy_script`) over inline heredocs.
- Check names appear as `{caller job} / {callee job}`; CodeQL and Trivy callers use job ids `CodeQL` / `Trivy`. Renaming a callee job breaks required-check rulesets in every app repo.

## Secrets and config conventions

- `PG_USER` / `PG_PASS` are organization secrets only; callers use `secrets: inherit` and must not redefine them per repo or environment.
- `PORT` and `SERVICE_NAME` come from GitHub environment variables (prod/dev) via a caller job with `environment:` set. `DEPLOY_PATH` must be under `/var/www/`.
- `appsettings.json` generated in CI is the single runtime config source on EC2; deploy removes legacy `.env` files and `deploy_env_lines` is deprecated.

## EC2 host scripts

- All files are LF with no BOM, enforced by `.gitattributes` and `.editorconfig`. CRLF or a BOM breaks shebangs, `set -o pipefail` and the cron file on the host.
- Scripts run as `sudo bash <script>` on Ubuntu and are expected to be idempotent (safe on every deploy), e.g. `ec2/redis/ensure-redis.sh`.
- `deploy-to-ec2.sh` resolves helper scripts from the staging dir in order: `DevOps/...`, then repo-root-relative, then the app's `scripts/`. Moving a script here changes those paths.
- Shared Redis: one loopback-only instance at `127.0.0.1:6379`; apps isolate by a service-name key prefix (`music:`, `music-dev:`), not DB numbers. Never expose 6379. See `ec2/redis/README.md`.
- Postgres backups: daily dump of every database to `s3://gideonogega-postgres-backups/ec2-ubuntu/{db}/{YYYY-MM-DD}.dump.gz`, installed by `ec2/postgres/install-postgres-backup.sh`.
- Hostname and database renames follow `ec2/domain-migration.md` and `aws/route53/README.md`. Route 53 scripts accept `ROUTE53_ZONE_ID` when `ListHostedZones` is denied.

## Checking changes

There is no local CI. Syntax-check a changed script with `bash -n path/to/script.sh`. Lint workflows, including their embedded shell, with `docker run --rm -v "$(pwd -W):/repo" -w /repo rhysd/actionlint:1.7.7 -no-color -oneline` from Git Bash (prefix `MSYS_NO_PATHCONV=1`); compare against `origin/main` because `dotnet-sonarqube-scan.yml` carries existing SC2086 notes. Workflow changes can only be proven by a run from a caller repo, so point a caller at the feature branch (`@<branch>` instead of `@main`) before merging.
