# GitHub organization setup

Workstation scripts that configure the `gideonogegaorg` GitHub organization with `gh`.

| Script | Purpose |
|--------|---------|
| `set-org-postgres-secrets.sh` | Sets the `PG_USER` / `PG_PASS` organization secrets read by `dotnet-deploy-ec2.yml`. Needs `gh auth refresh -h github.com -s admin:org`; values come from the environment. |
