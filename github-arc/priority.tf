# -----------------------------------------------------------------------------
# Runner pod priority (optional, var.runner_priority_class). Runner pods are
# disposable and a job that loses its pod is re-run, so a negative priority is
# usually right on a shared cluster: a runner that doesn't fit waits instead of
# preempting other workloads, and under node pressure the kubelet evicts runner
# pods first.
# -----------------------------------------------------------------------------
resource "kubernetes_priority_class_v1" "ci_runner" {
  count = var.runner_priority_class != null ? 1 : 0

  metadata {
    name = var.runner_priority_class.name
  }

  value             = var.runner_priority_class.value
  preemption_policy = "PreemptLowerPriority"
  global_default    = false
  description       = "GitHub Actions runner pods (github-arc)"
}
