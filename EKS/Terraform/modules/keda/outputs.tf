output "keda_namespace" {
  description = "KEDA installation namespace"
  value       = kubernetes_namespace.keda.metadata[0].name
}

output "keda_release_name" {
  description = "KEDA Helm release name"
  value       = helm_release.keda.name
}
