# .NET CI templates

Reference implementations for GitHub reusable workflows. Callable entrypoints live in `.github/workflows/dotnet-*.yml`.

## dotnet-lint.yml

| Input | Default | Purpose |
|-------|---------|---------|
| `solution_file` | required | Solution to restore/format |
| `use_gmo_feed` | `true` | When `false`, skip GMO NuGet auth |
| `verify_appsettings_not_tracked` | `true` | Fail if committed appsettings files exist |
| `generate_appsettings_script` | `""` | Optional pre-restore script |

Secrets `GH_USER` / `GH_CLASSIC_PAT` are optional when `use_gmo_feed` is `false`.

## dotnet-sonarqube-scan.yml

| Input | Default | Purpose |
|-------|---------|---------|
| `use_gmo_feed` | `true` | Skip GMO NuGet auth when `false` |
| `postgres_enabled` | `true` | When `false`, run build without Postgres service |
| `playwright_install_glob` | `""` | Path to `playwright.ps1` after build |
| `setup_paths_filter` | `""` | Path filter for `setup_changed` output |

When `postgres_enabled` is `true`, the job also starts RabbitMQ on port 5672 for integration tests that need a broker.

## dotnet-codeql.yml

| Input | Default | Purpose |
|-------|---------|---------|
| `solution_file` | required | Solution to build for analysis |
| `use_gmo_feed` | `true` | Skip GMO NuGet auth when `false` |
| `generate_appsettings_script` | `""` | Optional pre-build script |
| `upload_results` | `true` | Set `false` on private repos without GitHub Code Security |

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

Secrets: `REMOTE_HOST`, `SSH_PRIVATE_KEY`, `AWS_*`, `SEC_GROUP_ID` (repo or org). **`PG_USER` / `PG_PASS`**: organization secrets only (`gideonogegaorg`); callers use `secrets: inherit`.
