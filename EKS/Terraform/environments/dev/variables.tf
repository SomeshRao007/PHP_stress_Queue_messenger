variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "KEDA-symfony-queue"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.35"
}

variable "cluster_role_arn" {
  description = "Pre-existing IAM role ARN for EKS control plane"
  type        = string
}

variable "worker_role_arn" {
  description = "Pre-existing IAM role ARN for worker nodes"
  type        = string
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Environment = "dev"
    ManagedBy   = "opentofu"
    Project     = "php-keda-demo"
  }
}
