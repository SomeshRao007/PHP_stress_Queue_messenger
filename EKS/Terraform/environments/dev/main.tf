################################################################################
# VPC
################################################################################

module "vpc" {
  source = "../../modules/vpc"

  cluster_name    = var.cluster_name
  vpc_cidr        = "10.0.0.0/16"
  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]
  tags            = var.tags
}

################################################################################
# EKS Cluster + Node Group + IRSA Roles
################################################################################

module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  cluster_role_arn   = var.cluster_role_arn
  worker_role_arn    = var.worker_role_arn
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  node_instance_types = ["c6a.large"]
  node_desired_size   = 2
  node_min_size       = 2
  node_max_size       = 5
  node_disk_size      = 30

  tags = var.tags
}

################################################################################
# Monitoring Stack (LB Controller, Autoscaler, Prometheus, Grafana, HPA)
################################################################################

module "helm_monitoring" {
  source = "../../modules/helm-monitoring"

  cluster_name                     = module.eks.cluster_name
  vpc_id                           = module.vpc.vpc_id
  region                           = var.region
  lb_controller_irsa_role_arn      = module.eks.lb_controller_irsa_role_arn
  cluster_autoscaler_irsa_role_arn = module.eks.cluster_autoscaler_irsa_role_arn
  grafana_admin_password           = var.grafana_admin_password

  prometheus_storage_size = "10Gi"
  grafana_storage_size    = "5Gi"

  node_min_size = 2
  node_max_size = 5

  tags = var.tags

  depends_on = [module.eks]
}

################################################################################
# KEDA (with Prometheus metrics + ServiceMonitors)
################################################################################

module "keda" {
  source = "../../modules/keda"

  keda_namespace = "keda"
  tags           = var.tags

  # Must wait for LB Controller webhook to be ready, otherwise KEDA Service
  # creation fails with "no endpoints available for service aws-load-balancer-webhook-service"
  depends_on = [module.helm_monitoring]
}
