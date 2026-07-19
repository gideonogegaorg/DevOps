# Shared Redis on EC2

One host-local Redis service is shared by applications on the EC2 instance, like
the shared PostgreSQL server.

## Reconcile or recover

Application deployment pipelines should stage and run:

```bash
sudo bash ec2/redis/ensure-redis.sh
```

The script is idempotent and suitable for every deployment. On a clean host it
installs Redis; on an existing host it reconciles localhost binding,
protected mode, systemd startup, and append-only persistence before checking
`redis-cli ping`.

## Application isolation

All applications connect to:

```text
127.0.0.1:6379,abortConnect=false
```

Each application/environment must use a distinct key prefix derived from its
service name, for example:

- `music:`
- `music-dev:`
- `familytree:`
- `familytree-dev:`

Do not rely only on Redis database numbers for isolation.

## Network policy

Redis is bound to loopback and protected mode is enabled. Do not expose port
6379 through an EC2 security group or public load balancer.
