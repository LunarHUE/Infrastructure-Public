# publish-infrastructure

Reusable infrastructure modules, each in its own directory with its own state
and README.

| Directory     | What it is                                                     |
|---------------|----------------------------------------------------------------|
| `github-arc/` | Self-hosted GitHub Actions runners on Kubernetes with actions-runner-controller |
| `entra-secret-rotation/` | CronJob that rotates Entra client secrets with Tofu, with no downtime |
