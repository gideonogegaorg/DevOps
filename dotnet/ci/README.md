# .NET CI templates

Reference implementations for GitHub reusable workflows. Callable entrypoints live in `.github/workflows/dotnet-*.yml`.

## dotnet-lint.yml

| Input | Default | Purpose |
|-------|---------|---------|
| `solution_file` | required | Solution to restore/format |
| `use_gmo_feed` | `true` | When `false`, skip GMO NuGet auth |
| `verify_appsettings_not_tracked` | `true` | Fail if committed appsettings files exist |
| `generate_appsettings_script` | `""` | Optional pre-restore script |
| `appsettings_template` | `""` | Render this template with the [generic generator](#generic-appsettings-generator) instead of running `generate_appsettings_script` |
| `appsettings_defaults` | `""` | Defaults file for `appsettings_template` |
| `devops_ref` | `main` | DevOps ref checked out for the generator when `appsettings_template` is set |
| `fail_on_vulnerable` | `true` | Fail when `dotnet list package --vulnerable --include-transitive` reports any known vulnerability; `false` downgrades it to a warning |

Secrets `GH_USER` / `GH_CLASSIC_PAT` are optional when `use_gmo_feed` is `false`.

Callers do not need a separate NuGet audit job; this one covers direct and transitive packages.

## dotnet-sonarqube-scan.yml

| Input | Default | Purpose |
|-------|---------|---------|
| `use_gmo_feed` | `true` | Skip GMO NuGet auth when `false` |
| `postgres_enabled` | `true` | When `false`, run build without Postgres service |
| `playwright_install_glob` | `""` | Path to `playwright.ps1` after build |
| `setup_paths_filter` | `""` | Path filter for `setup_changed` output |
| `pre_build_script` | `""` | Repo script run with `bash` after setup-dotnet, before build (toolchain setup such as `mono-complete` for net48) |
| `coverlet_runsettings` | `coverlet.runsettings` | Runsettings passed to `dotnet test --settings`; omitted when the file does not exist |
| `test_framework` | `""` | When set, `dotnet test --framework <value>`; use for multi-targeted solutions since coverlet collects no coverage under Mono for net48 |
| `sonar_test_exclusions` | `""` | When set, passed as `sonar.test.exclusions`: test files matching these comma-separated globs are not analyzed |
| `sonar_extra_properties` | `""` | Newline-separated `key=value` lines, each passed to the scanner begin step as `/d:key=value`. Blank lines and lines starting with `#` are skipped; any other line without `=` fails the step |
| `appsettings_template` / `appsettings_defaults` / `devops_ref` | `""` / `""` / `main` | As in `dotnet-lint.yml`; applies to both jobs. The DevOps checkout is deleted after generation so the scanner never sees it |

When `postgres_enabled` is `true`, the job also starts RabbitMQ on port 5672 for integration tests that need a broker.

`generate_appsettings_script` is for app configuration; put toolchain setup in `pre_build_script`. A solution that multi-targets net48 builds on the Linux runner only with Mono installed:

```yaml
with:
  solution_file: src/MyLib.sln
  postgres_enabled: false
  pre_build_script: .github/scripts/install-mono.sh
  test_framework: net10.0
```

With `test_framework` set and `--no-build`, every test project in the solution must target that TFM.

`sonar_extra_properties` carries analysis settings that have no dedicated input, such as issue-ignore rules. Each line is passed to the scanner as one literal argument, never evaluated by the shell. To keep test code out of analysis and ignore rule `csharpsquid:S8969` on library sources:

```yaml
with:
  sonar_test_exclusions: "**/tst/**"
  sonar_extra_properties: |
    sonar.issue.ignore.multicriteria=e1
    sonar.issue.ignore.multicriteria.e1.ruleKey=csharpsquid:S8969
    sonar.issue.ignore.multicriteria.e1.resourceKey=src/**/*.cs
```

Properties set here and in the SonarCloud UI do not merge for multi-value keys: `sonar.issue.ignore.multicriteria` passed by the scanner replaces the project's UI-defined ignore list for that analysis. List every ignore rule the project needs, numbered `e1,e2,...`.

## dotnet-codeql.yml

| Input | Default | Purpose |
|-------|---------|---------|
| `solution_file` | required | Solution to build for analysis |
| `use_gmo_feed` | `true` | Skip GMO NuGet auth when `false` |
| `generate_appsettings_script` | `""` | Optional pre-build script |
| `pre_build_script` | `""` | Repo script run with `bash` after setup-dotnet, before build (toolchain setup such as `mono-complete` for net48) |
| `upload_results` | `true` | Set `false` on private repos without GitHub Code Security |
| `appsettings_template` / `appsettings_defaults` / `devops_ref` | `""` / `""` / `main` | As in `dotnet-lint.yml` |

## dotnet-js-lint.yml

| Input | Default | Purpose |
|-------|---------|---------|
| `node_version` | `26` | Node.js version for `npm ci` and `npm run lint:js` |

## security-trivy.yml

Filesystem + secret scan. Job name is `Trivy`. SARIF upload is best-effort (`continue-on-error`) so private repos without Code Security still get a failing Actions check when `fail_on_findings` is `true`.

## dotnet-deploy-ec2.yml

| Input | Default | Purpose |
|-------|---------|---------|
| `require_postgres` | `yes` | When `no`, skip PG secret validation |
| `setup_changed` | `no` | Pass `yes`/`no` from caller (map paths-filter `true` → `yes`) |
| `is_production` | `development` | `true`/`production` or `false`/`development` for configure-service.sh |
| `generate_appsettings_script` | `scripts/generate-appsettings.sh` | Skip when empty |
| `deploy_env_lines` | `""` | **Deprecated.** Use `appsettings.json` from CI instead; deploy removes legacy `.env` files. |
| `extra_deploy_dirs` | `uploads` | Comma-separated dirs under deploy path |
| `remote_deploy_script` | `""` | Staging-relative script SCP'd and run instead of the inline SSH script, e.g. `DevOps/dotnet/ec2/deploy-to-ec2.sh` |
| `ssh_host` | `""` | SSH/SCP target; empty uses the `REMOTE_HOST` secret, and the job fails if both are empty |
| `appsettings_env` | `""` | Newline-separated non-secret `KEY=VALUE` lines exported to the generate-appsettings step after its built-in variables, so they override them. Blank lines and `#` lines are skipped; a line without `=` or with an invalid name fails the step. Values are taken literally, never evaluated |
| `appsettings_secret_names` | `""` | Space-separated secret names exported, masked, to the generate-appsettings step. A missing secret fails the step unless the name ends in `?` |
| `ensure_redis` | `no` | `yes` runs `ec2/redis/ensure-redis.sh` from DevOps on the host before the deploy step |
| `devops_ref` | `main` | DevOps ref checked out to `./DevOps` when `ensure_redis` is `yes`, `appsettings_template` is set, or a script input starts with `DevOps/` |
| `appsettings_template` | `""` | Render this template with the [generic generator](#generic-appsettings-generator) instead of running `generate_appsettings_script`; `appsettings_env` and `appsettings_secret_names` still apply |
| `appsettings_defaults` | `""` | Defaults file for `appsettings_template` |
| `robots_path` | `""` | Repo-relative `robots.txt` path (e.g. `src/App.Web/wwwroot/robots.txt`); the workflow writes allow-all for production and disallow-all otherwise, and skips `generate_robots_script` |
| `health_path` | `/` | Exported as `HEALTH_PATH` to `remote_deploy_script`; `deploy-to-ec2.sh` then expects HTTP 200 from it on the local port after `/health`, and the public check expects 200 from it after `/health` (empty: the public check uses `/`). Point it at an anonymous page when `/` redirects |
| `dll_name` | `""` | Exported as `DLL_NAME` to `remote_deploy_script`; `deploy-to-ec2.sh` needs it when the app dll is not `*.Web.dll` |
| `restrict_appsettings` | `no` | `yes` sets `site/appsettings.json` to mode 600; the service must run as `ubuntu` |
| `clean_site` | `no` | `yes` empties `site/` on the host before the copy. Without it the copy overlays the old build, so DLLs of removed packages linger, and Serilog.Settings.Configuration crashes at startup on a stale `*serilog*.dll` missing from `deps.json`. List every path the app writes at runtime under `site/` in `clean_site_keep`, or it is deleted (SSP keeps Data Protection keys in `site/data`; Family falls back to `wwwroot/uploads` when `Paths:Uploads` is empty) |
| `clean_site_keep` | `""` | Comma-separated site-relative paths moved aside before `clean_site` empties `site/` and restored after the copy, replacing any staged copy, e.g. `data,wwwroot/uploads` |
| `use_gmo_feed` | `false` | `true` authenticates the `GMO` source from the caller's `nuget.config` with `GH_USER` / `GH_CLASSIC_PAT` before publish |

Secrets: `SSH_PRIVATE_KEY`, `AWS_*`, `SEC_GROUP_ID`, and `REMOTE_HOST` unless `ssh_host` is set (repo or org). **`PG_USER` / `PG_PASS`**: organization secrets only (`gideonogegaorg`); callers use `secrets: inherit`.

`appsettings_secret_names` reads the job's `secrets` context. With `secrets: inherit` that context holds every secret the caller can see (org, repo, and the callee job's `github.ref_name` environment), not only the ones declared under `workflow_call.secrets`, so app-specific secrets need no declaration here. Without `secrets: inherit` only declared secrets are visible.

With `remote_deploy_script: DevOps/dotnet/ec2/deploy-to-ec2.sh`, the workflow exports `CONFIGURE_SCRIPT_PATH`, `RUNTIME_SCRIPT_PATH` (the `configure_service_script` / `install_runtime_script` inputs), `EXTRA_DEPLOY_DIRS`, `RESTRICT_APPSETTINGS`, `CLEAN_SITE`, `CLEAN_SITE_KEEP`, `HEALTH_PATH` and `DLL_NAME`; the script prefers the two script paths over its built-in candidates. Point `install_runtime_script` at `DevOps/dotnet/ec2/install-aspnetcore-runtime.sh` when the app has no copy:

```yaml
with:
  remote_deploy_script: DevOps/dotnet/ec2/deploy-to-ec2.sh
  install_runtime_script: DevOps/dotnet/ec2/install-aspnetcore-runtime.sh
  configure_service_script: scripts/configure-service.sh
  dll_name: Web.dll
  extra_deploy_dirs: data
  ensure_redis: "yes"
  restrict_appsettings: "yes"
  appsettings_env: |
    RABBITMQ_HOSTNAME=localhost
  appsettings_secret_names: "LAST_FM_API_KEY OPEN_AI_KEY?"
secrets: inherit
```

The configure script receives `production` or `development` as its fifth argument, never `true`/`false`.

`configure_service_script` and `install_runtime_script` keep their app-local defaults (`scripts/...`) until every caller has moved, so pass the DevOps paths explicitly: `DevOps/ec2/nginx/configure-subdomain.sh` (needs `dll_name` unless the dll matches `*.Web.dll`) and `DevOps/dotnet/ec2/install-aspnetcore-runtime.sh`. `configure-subdomain.sh` validates its arguments, uses `DEPLOY_PATH` (exported by `deploy-to-ec2.sh`, must be under `/var/www/`) as the web root, and checks the nginx site with `nginx -t` before touching systemd: on failure it restores the previous site file and symlink, or removes new ones, and exits non-zero, failing the deploy.

To drop an app's own generator scripts:

```yaml
with:
  appsettings_template: src/App.Web/appsettings.json.template
  appsettings_defaults: src/App.Web/appsettings.defaults.env
  robots_path: src/App.Web/wwwroot/robots.txt
```

`PORT`, `SERVICE_NAME` and `IS_PRODUCTION` are environment variables, which a `uses:` caller job cannot read; resolve them in a caller job with `environment:` set and pass its outputs. A job output that contains any secret's value is dropped, so keep secret-derived values (such as hostnames built from `DEPLOY_DOMAIN`) out of those outputs.

## Generic appsettings generator

`dotnet/ci/generate-appsettings.sh <template> <output> [defaults-file]` replaces every `^^TOKEN^^` in the template. Token names are `[A-Z_][A-Z0-9_]*`; a token with lower-case letters fails the run. The workflows write the output next to the template, with `.template` removed.

Each token's value, first match wins:

1. Environment variable `TOKEN`, when set and non-empty.
2. `TOKEN=VALUE` in the defaults file.
3. Empty string, when `TOKEN` is set but empty, or listed in `APPSETTINGS_OPTIONAL_TOKENS` (space or comma separated).

Anything else is unresolved: the run fails with an `::error::` that names the tokens, never their values, and writes no output. Declare a token in the defaults file (`KEY=` for empty) so a missing value is caught by intent, not by accident.

Placement sets the encoding. Inside a JSON string (`"…^^TOKEN^^…"`) the value is JSON-string escaped (`\`, `"`, control characters), so passwords with `|`, `&`, `\` or quotes are safe; no `sed` is involved. Outside a string (`"Enabled": ^^TOKEN^^`) the value must be `true`/`yes`/`on`/`1` (written `true`), `false`/`no`/`off`/`0`/empty (written `false`) or a JSON number, in any case; anything else fails. A numeric setting that may be `0` or `1` belongs in quotes (`"Retries": "^^RETRIES^^"`): .NET configuration binds quoted numbers and booleans. The output is validated with `jq` (or `python3`) and removed if it is not valid JSON.

Defaults file: one `KEY=VALUE` per line; blank lines and `#` lines are skipped, CRLF is accepted. Values are never evaluated by the shell. `${NAME}`, `${NAME:-word}` and `${NAME:+word}` expand from the environment and from keys on earlier lines, and `word` may nest references; `$${` is a literal `${`. Surrounding `"…"` are removed; `'…'` are removed and disable expansion. An environment value always beats the file, including for keys used only as intermediates:

```bash
SERILOG_LOG_PATH=../../logs
GOOGLE_CLIENT_ID=
IS_PRODUCTION=false
EMAIL_FROM_ADDRESS=${EMAIL_DOMAIN:+noreply@${EMAIL_DOMAIN}}
PHOTOS_PREFIX_FROM_ENV=${PHOTOS_APP_NAME:+${PHOTOS_ENVIRONMENT:+${PHOTOS_APP_NAME}/${PHOTOS_ENVIRONMENT}}}
PHOTOS_PREFIX_FROM_TELEMETRY=${PHOTOS_APP_NAME:+${TELEMETRY_ENVIRONMENT_NAME:+${PHOTOS_APP_NAME}/${TELEMETRY_ENVIRONMENT_NAME}}}
PHOTOS_STORAGE_PREFIX=${PHOTOS_PREFIX_FROM_ENV:-${PHOTOS_PREFIX_FROM_TELEMETRY}}
```

In `dotnet-deploy-ec2.yml` the generator sees the job environment (`FULL_HOSTNAME`, `DEPLOY_PATH`, `SERVICE_NAME`, `PORT`, `BRANCH`, `POSTGRES_CONNECTION_STRING`, the `GOOGLE_*` and `OPENTELEMETRY_*` secrets), the step's built-ins (`SERILOG_LOG_PATH`, `UPLOADS_PATH`, `PHOTOS_*`, `S3_PHOTOS_BUCKET`, `TELEMETRY_ENVIRONMENT_NAME`), then `appsettings_env` and `appsettings_secret_names`. With `appsettings_template`, `IS_PRODUCTION` is `true` or `false` (from `is_production`), so `"IsProduction": ^^IS_PRODUCTION^^` needs no tracked value. Lint, Sonar and CodeQL run it without secrets, so the defaults file must resolve every token there.

Local development: keep a thin `scripts/generate-appsettings.sh` that calls a sibling DevOps checkout, overridable with `DEVOPS_DIR`:

```bash
#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
devops_dir="${DEVOPS_DIR:-$repo_root/../DevOps}"
web="$repo_root/src/App.Web"
exec bash "$devops_dir/dotnet/ci/generate-appsettings.sh" "$web/appsettings.json.template" "$web/appsettings.json" "$web/appsettings.defaults.env"
```

Tests: `bash dotnet/ci/tests/test-generate-appsettings.sh` (needs `jq`) and `bash dotnet/ec2/tests/test-replace-site.sh`.
