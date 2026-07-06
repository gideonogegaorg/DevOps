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
```

See `dotnet/ci/` for template source; `.github/workflows/dotnet-*.yml` are GitHub-required entrypoints.

**Postgres credentials:** set `PG_USER` and `PG_PASS` once at the **organization** level. App repos should use `secrets: inherit` on deploy jobs and must not duplicate these on repo or environment secrets.

**Deploy flags:** map paths-filter `setup_changed` to `yes`/`no` before passing to `dotnet-deploy-ec2` (GitHub masks the literal `true` in SSH scripts).

## Adding a new tech stack

1. Create `{stack}/ci/` and `{stack}/ec2/` as needed
2. Add thin wrappers under `.github/workflows/{stack}-*.yml`
3. Document required inputs in `{stack}/ci/README.md`
