# deploy/k8s

Minimal quick-start manifests for running Vex on Kubernetes.

- **`quickstart.yaml`** — single-node Vex (RESP on 6380, AOF persistence) for
  trying Vex. Not a production HA topology.

Replicated/HA deployment, failover, backups, upgrades, and lifecycle
management live in the operator: **github.com/vex-db/vex-operator**.

Test, chaos, and benchmark manifests are not deployment artifacts — they live
under `tests/k8s/`.
