# DevOps

Shared infrastructure scripts and CI templates for gideonogegaorg projects.

## Layout

| Path | Purpose |
|------|---------|
| `aws/` | Tech-stack agnostic AWS provisioning (IAM, S3, Route 53) |
| `ec2/` | Tech-stack agnostic EC2 host ops (Postgres backup, nginx, domain migration) |
| `dotnet/` | .NET-specific CI templates and EC2 runtime installers |
| `java/` | Java-specific (add when needed) |
| `.github/workflows/` | Callable GitHub Actions entrypoints (thin wrappers) |

**Rule:** agnostic items at repo root; stack-specific items under `{techstack}/`.

## Route 53 and S3

```bash
# DNS A records
bash aws/route53/upsert-a-records.sh goom.life app.example.com=1.2.3.4

# Copy S3 objects between key prefixes (e.g. app rename)
bash aws/s3/migrate-prefix.sh gideonogega-internal old-app/prod new-app/prod --dry-run
```

See `aws/route53/README.md` and `ec2/domain-migration.md` for full hostname/DB rename workflows.

## Postgres S3 backups

Daily 1 AM backup of all PostgreSQL databases on EC2 to `s3://gideonogega-postgres-backups/ec2-ubuntu/{db}/{YYYY-MM-DD}.dump.gz`.

```bash
# One-time AWS setup (workstation)
bash aws/s3/create-postgres-backups-bucket.sh
aws iam put-role-policy --role-name EC2-Certbot-Role \
  --policy-name PostgresBackupS3Policy \
  --policy-document file://aws/iam/postgres-backup-s3-policy.json

# Install on EC2
git clone https://github.com/gideonogegaorg/DevOps.git /tmp/devops
sudo bash /tmp/devops/ec2/postgres/install-postgres-backup.sh
```

## CI templates (.NET)

App repos call reusable workflows:

```yaml
uses: gideonogegaorg/DevOps/.github/workflows/dotnet-lint.yml@main
uses: gideonogegaorg/DevOps/.github/workflows/dotnet-js-lint.yml@main
uses: gideonogegaorg/DevOps/.github/workflows/dotnet-sonarqube-scan.yml@main
uses: gideonogegaorg/DevOps/.github/workflows/dotnet-codeql.yml@main
uses: gideonogegaorg/DevOps/.github/workflows/security-trivy.yml@main
uses: gideonogegaorg/DevOps/.github/workflows/dotnet-tag.yml@main
uses: gideonogegaorg/DevOps/.github/workflows/dotnet-deploy-ec2.yml@main
```

See `dotnet/ci/` for template source; `.github/workflows/dotnet-*.yml` (and `security-trivy.yml`) are GitHub-required entrypoints.

**Check names:** reusable workflow jobs appear on PRs as `{caller} / {callee}` (e.g. `lint / lint`, `build / build`). Require those contexts in branch rulesets. CodeQL/Trivy callers should use job ids `CodeQL` / `Trivy` so checks are `CodeQL / CodeQL` and `Trivy / Trivy`. Private repos without GitHub Code Security should set `upload_results: false` on CodeQL (analysis still runs) and keep Trivy SARIF upload best-effort.

**Postgres build job** also starts RabbitMQ (`localhost:5672`) for apps that need a broker during integration tests.

**Postgres credentials:** set `PG_USER` and `PG_PASS` once at the **organization** level. App repos should use `secrets: inherit` on deploy jobs and must not duplicate these on repo or environment secrets.

**Deploy flags:** map paths-filter `setup_changed` to `yes`/`no` before passing to `dotnet-deploy-ec2` (GitHub masks the literal `true` in SSH scripts).

## Shared Redis

Applications share one host-local Redis service and isolate keys with their
service-name prefix. Deployment pipelines run the idempotent recovery script:

```bash
sudo bash ec2/redis/ensure-redis.sh
```

See [ec2/redis/README.md](ec2/redis/README.md) for recovery and isolation rules.

## Adding a new tech stack

1. Create `{stack}/ci/` and `{stack}/ec2/` as needed
2. Add thin wrappers under `.github/workflows/{stack}-*.yml`
3. Document required inputs in `{stack}/ci/README.md`
