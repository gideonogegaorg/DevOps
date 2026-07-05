# .NET CI templates

Reference implementations for GitHub reusable workflows. Callable entrypoints live in `.github/workflows/dotnet-*.yml`.

## sonarqube-scan-standalone.yml

Port of GitLab `sonarqube-scan-standalone.yaml`. Inputs:

| Input | Required | Default |
|-------|----------|---------|
| `solution_file` | no | (auto) |
| `calculate_coverage` | no | `true` |
| `test_filter` | no | `""` |
| `sonar_coverage_exclusions` | no | `""` |
| `sonar_exclusions` | no | `""` |
| `sonar_project_version` | no | `""` |
| `sonar_project_key` | yes | — |
| `sonar_organization` | no | caller owner |
| `sonar_project_name` | no | repo name |
| `production_branch` | no | `prod` |
| `development_branch` | no | `dev` |
| `coverlet_runsettings` | no | `coverlet.runsettings` |
| `playwright_install_path` | no | `""` |

Secrets: `SONAR_TOKEN`, `GH_CLASSIC_PAT` (as `GITHUB_PAT`), `GH_USER` (as `GITHUB_USERNAME`).
