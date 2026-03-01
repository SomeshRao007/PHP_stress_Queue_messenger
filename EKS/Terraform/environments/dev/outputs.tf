output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  description = "Run this command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "grafana_access" {
  description = "How to access Grafana"
  value       = "kubectl get svc -n monitoring grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "keda_namespace" {
  description = "KEDA installation namespace"
  value       = module.keda.keda_namespace
}

output "monitoring_namespace" {
  description = "Monitoring stack namespace"
  value       = module.helm_monitoring.monitoring_namespace
}
