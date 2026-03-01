variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID (required by AWS LB Controller)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "lb_controller_irsa_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller service account"
  type        = string
}

variable "cluster_autoscaler_irsa_role_arn" {
  description = "IAM role ARN for Cluster Autoscaler service account"
  type        = string
}

variable "node_min_size" {
  description = "Minimum nodes for Cluster Autoscaler"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum nodes for Cluster Autoscaler"
  type        = number
  default     = 5
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}

variable "prometheus_storage_size" {
  description = "Prometheus PVC size"
  type        = string
  default     = "10Gi"
}

variable "grafana_storage_size" {
  description = "Grafana PVC size"
  type        = string
  default     = "5Gi"
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
