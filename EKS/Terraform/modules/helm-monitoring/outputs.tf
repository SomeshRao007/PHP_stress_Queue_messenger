output "monitoring_namespace" {
  description = "The monitoring namespace name"
  value       = kubernetes_namespace.monitoring.metadata[0].name
}

output "grafana_release_name" {
  description = "Grafana Helm release name"
  value       = helm_release.grafana.name
}

output "lb_controller_release_name" {
  description = "AWS Load Balancer Controller Helm release name"
  value       = helm_release.aws_lb_controller.name
}

output "prometheus_release_name" {
  description = "kube-prometheus-stack Helm release name"
  value       = helm_release.kube_prometheus_stack.name
}

output "app_namespace" {
  description = "Application namespace (php-job-demo)"
  value       = kubernetes_namespace.app.metadata[0].name
}
