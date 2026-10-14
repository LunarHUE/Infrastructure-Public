# Entra client secret rotation

A CronJob runs `tofu plan` on your rotation roots each day. It applies only when every change is a rotation.

- `module/`: a client secret that rotates every `rotation_days`. The new one is created before the old is deleted, and stays valid `grace_days` past rotation.
- `example-app-secret/`: a rotation root. It writes the secret to a Kubernetes Secret, restarts the app, then deletes the old secret.
- `rotator/`: the CronJob. It uses an Entra app with `Application.ReadWrite.OwnedBy` and a federated credential, so it holds no secret of its own.

## Setup

1. `rotator/`: fill in `terraform.tfvars` and run `tofu apply` as an Entra admin.
2. Copy `example-app-secret/` for each app. Set a unique `secret_suffix` and `rotator_object_id`, then `KUBE_CONFIG_PATH=~/.kube/config tofu apply`.
3. Point the app at the Kubernetes Secret.

Force a rotation: `tofu apply -replace=module.client_secret.time_rotating.this`.

## Notes

- The cluster's service-account issuer must be publicly reachable by Entra.
- Keep rotation roots small. The job needs access to everything a root manages.
- If another root also manages a restarted Deployment, ignore the `entra-secret-rotation/key-id` annotation there.
