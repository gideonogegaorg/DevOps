# DevOps

Shared infrastructure scripts and CI templates for gideonogegaorg projects.

## Layout

| Path | Purpose |
|------|---------|
| `aws/` | Tech-stack agnostic AWS provisioning (IAM, S3, Route 53, SES inbound mail) |
| `github/` | GitHub organization setup with `gh` (org secrets) |
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

## Inbound mail (SES)

Org infrastructure shared by every app. Each Route 53 domain (`goom.life`, `gideonogega.com`, `goomtech.com`, `blademasterx.com`) receives `support@<domain>`, stored in S3 and forwarded to the owner's mailbox. `claude-test@goom.life` is stored only (Claude's test accounts confirm with it) and expires after 30 days. Other addresses bounce: there is no catch-all.

| Piece | Name |
|-------|------|
| Bucket (private, SSE-S3, SES may write for this account only) | `goom-life-mail`, one folder per address: `<domain>/<local part>/<SES message id>` |
| Receipt rule set (active) | `org-inbound`, one rule per address, named like `support-at-goom-life` |
| Forwarder | Lambda and IAM role `ses-inbound-forwarder` (`aws/ses-forwarder/forwarder.py`) |
| DNS per domain | apex `MX 10 inbound-smtp.us-east-1.amazonaws.com`, `amazonses.com` in the apex SPF, three Easy DKIM CNAMEs |

The forwarder resends each message from the address it was sent to (`support@gideonogega.com` forwards as `support@gideonogega.com`), with `Reply-To` and `X-Original-From` set to the original sender, so replying from the inbox reaches them. SES sends only from verified identities, so a domain forwards (and receives) only once its DKIM verifies; the script prints a `PENDING` line per unverified domain. The forward target lives only in the Lambda's `FORWARD_RULES` variable, never in this repo.

`aws/ses-inbound.ps1` builds and repairs all of it and is safe to rerun. Check the plan first, then apply, with the target given at run time:

```powershell
pwsh -File aws/ses-inbound.ps1 -ForwardTo <owner-mailbox> -WhatIf
pwsh -File aws/ses-inbound.ps1 -ForwardTo <owner-mailbox>
```

Rerun with the same `-ForwardTo` every time; the script refuses a run without `-ForwardTo` or `-ForwardRules` unless `-NoForward` asks for storage only. To add an address, pass the full list, e.g. `-Addresses support@goom.life,noreply@goom.life,claude-test@goom.life,support@gideonogega.com,support@goomtech.com,support@blademasterx.com`; `-ForwardRules @{ 'noreply@goom.life' = '<mailbox>' }` forwards a non-support address. To add a domain, add it to `-Domains` (its hosted zone is looked up by name, or pass `-HostedZoneIds`). Rules for addresses no longer listed are reported, not deleted. The script refuses to replace an existing different apex MX or another active rule set without `-Force`, and keeps every other apex TXT value when it adds SPF.

Reading mail:

- Console: S3, bucket `goom-life-mail`, folder `<domain>/<local part>/`; each object is a raw `.eml` (the `AMAZON_SES_SETUP_NOTIFICATION` object is SES's own test write).
- Script: `pwsh -File aws/Get-SesMail.ps1 -Address claude-test@goom.life -From noreply@music-dev.goom.life -Count 1 -Links` lists the newest messages (newest first, `-Since` defaults to 7 days, `-Subject` filters too), downloads them to a temp folder (`-OutDir` to choose), and with `-Links` prints every http(s) link decoded from quoted-printable or base64 parts, ready to open. `-PassThru` returns objects.

Tests: `python -m unittest discover -s aws/ses-forwarder` and, with Pester 5, `Invoke-Pester aws/tests`.

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
