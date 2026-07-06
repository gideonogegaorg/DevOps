# Route 53 helpers

Requires AWS CLI and `jq` for delete operations.

```bash
# Add A records
bash aws/route53/upsert-a-records.sh goom.life \
  familytree.goom.life=35.172.36.171 \
  familytree-dev.goom.life=35.172.36.171

# Remove A records (uses current TTL/IP from the zone)
bash aws/route53/delete-a-records.sh goom.life \
  family.goom.life family-dev.goom.life
```
