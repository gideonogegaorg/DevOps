# Domain and infrastructure rename runbook

Use when changing public hostnames, deploy paths, systemd service names, Postgres database names, and S3 photo prefixes for an app on shared EC2.

## Prerequisites

- AWS CLI authenticated (`aws login`)
- SSH access to EC2 as `ubuntu`
- Clone this repo: `git clone https://github.com/gideonogegaorg/DevOps.git /tmp/devops`

## Order of operations

1. **DNS** — `aws/route53/upsert-a-records.sh` for new hostnames
2. **S3** — `aws/s3/migrate-prefix.sh` to copy photo objects to new prefix; update EC2 IAM (`aws/iam/s3-photos-prefix-policy.json`)
3. **App CI** — update hostname patterns, `PHOTOS_APP_NAME`, `SERVICE_NAME` GitHub environment variables
4. **EC2 www** — `ec2/deploy/migrate-www-path.sh`
5. **Stop apps** — `systemctl stop <old-service>...`
6. **Postgres** — `ec2/postgres/rename-database.sh --backup <old-db> <new-db>`
7. **Provision** — `ec2/nginx/configure-subdomain.sh` with new hostname and service name
8. **Remove old** — `ec2/postgres/remove-systemd-service.sh`, `ec2/nginx/remove-site.sh`, `aws/route53/delete-a-records.sh`
9. **Deploy** — push to `dev` then `prod`; verify `/health` and photos
10. **OAuth** — update redirect URIs in Google Cloud Console

## FamilyTree example (family → familytree)

```bash
DEVOPS=/tmp/devops
BUCKET=gideonogega-internal
IP=35.172.36.171
export ROUTE53_ZONE_ID=Z06793181SRD5TKXV643G  # goom.life hosted zone

bash $DEVOPS/aws/route53/upsert-a-records.sh goom.life \
  familytree.goom.life=$IP familytree-dev.goom.life=$IP

bash $DEVOPS/aws/iam/apply-ec2-s3-photos-policy.sh  # requires root/admin IAM

bash $DEVOPS/aws/s3/migrate-prefix.sh $BUCKET family/prod familytree/prod
bash $DEVOPS/aws/s3/migrate-prefix.sh $BUCKET family/dev familytree/dev

# On EC2:
sudo bash $DEVOPS/ec2/deploy/migrate-www-path.sh \
  /var/www/family.goom.life /var/www/familytree.goom.life
sudo bash $DEVOPS/ec2/deploy/migrate-www-path.sh \
  /var/www/family-dev.goom.life /var/www/familytree-dev.goom.life

sudo systemctl stop family family-dev
sudo bash $DEVOPS/ec2/postgres/rename-database.sh --backup family familytree
sudo bash $DEVOPS/ec2/postgres/rename-database.sh --backup family-dev familytree-dev

export DLL_NAME=GMO.FamilyTree.Web.dll
sudo -E bash $DEVOPS/ec2/nginx/configure-subdomain.sh \
  familytree-dev.goom.life 5003 familytree-dev goom.life false
sudo -E bash $DEVOPS/ec2/nginx/configure-subdomain.sh \
  familytree.goom.life 5002 familytree goom.life true

sudo bash $DEVOPS/ec2/postgres/remove-systemd-service.sh family
sudo bash $DEVOPS/ec2/postgres/remove-systemd-service.sh family-dev
```

After verification, retire old DNS and nginx sites (see `delete-a-records.sh`, `remove-site.sh`, `archive-www-path.sh`).
