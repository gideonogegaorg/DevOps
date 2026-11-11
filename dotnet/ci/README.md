# .NET CI templates

Reference implementations for GitHub reusable workflows. Callable entrypoints live in `.github/workflows/dotnet-*.yml`.

## dotnet-lint.yml

| Input | Default | Purpose |
|-------|---------|---------|
| `solution_file` | required | Solution to restore/format |
| `use_gmo_feed` | `true` | When `false`, skip GMO NuGet auth |
| `verify_appsettings_not_tracked` | `true` | Fail if committed appsettings files exist |
| `generate_appsettings_script` | `""` | Optional pre-restore script |
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

## dotnet-codeql.yml

| Input | Default | Purpose |
|-------|---------|---------|
| `solution_file` | required | Solution to build for analysis |
| `use_gmo_feed` | `true` | Skip GMO NuGet auth when `false` |
| `generate_appsettings_script` | `""` | Optional pre-build script |
| `pre_build_script` | `""` | Repo script run with `bash` after setup-dotnet, before build (toolchain setup such as `mono-complete` for net48) |
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
