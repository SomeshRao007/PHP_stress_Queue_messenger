################################################################################
# Namespaces
################################################################################

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      name = "monitoring"
    }
  }
}

resource "kubernetes_namespace" "app" {
  metadata {
    name = "php-job-demo"
    labels = {
      app = "php-job-demo"
    }
  }
}

################################################################################
# AWS Load Balancer Controller
################################################################################

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.lb_controller_irsa_role_arn
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }
}

################################################################################
# Cluster Autoscaler
################################################################################

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "awsRegion"
    value = var.region
  }

  set {
    name  = "rbac.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.cluster_autoscaler_irsa_role_arn
  }

  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }

  set {
    name  = "extraArgs.skip-nodes-with-system-pods"
    value = "false"
  }
}

################################################################################
# kube-prometheus-stack (Prometheus + kube-state-metrics + ServiceMonitor CRDs)
################################################################################

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  # Prometheus server configuration
  set {
    name  = "prometheus.prometheusSpec.replicas"
    value = "1"
  }

  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "15d"
  }

  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]"
    value = "ReadWriteOnce"
  }

  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"
    value = var.prometheus_storage_size
  }

  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName"
    value = "gp2"
  }

  # Enable ServiceMonitor for auto-discovery (picks up KEDA ServiceMonitors)
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  set {
    name  = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  # kube-state-metrics — enabled for pod lifecycle tracking
  set {
    name  = "kubeStateMetrics.enabled"
    value = "true"
  }

  # Node exporter — enabled for cluster-level metrics
  set {
    name  = "nodeExporter.enabled"
    value = "true"
  }

  # Alertmanager — disabled (not needed)
  set {
    name  = "alertmanager.enabled"
    value = "false"
  }

  # Disable the built-in Grafana from kube-prometheus-stack (we deploy our own)
  set {
    name  = "grafana.enabled"
    value = "false"
  }
}

################################################################################
# Grafana (standalone Helm chart with custom dashboards)
################################################################################

resource "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "grafana-admin-credentials"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    admin-user     = "admin"
    admin-password = var.grafana_admin_password
  }

  type = "Opaque"
}

resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set {
    name  = "replicas"
    value = "1"
  }

  # Persistence
  set {
    name  = "persistence.enabled"
    value = "true"
  }

  set {
    name  = "persistence.size"
    value = var.grafana_storage_size
  }

  set {
    name  = "persistence.storageClassName"
    value = "gp2"
  }

  # Admin credentials from K8s secret
  set {
    name  = "admin.existingSecret"
    value = kubernetes_secret.grafana_admin.metadata[0].name
  }

  set {
    name  = "admin.userKey"
    value = "admin-user"
  }

  set {
    name  = "admin.passwordKey"
    value = "admin-password"
  }

  # Expose via LoadBalancer (internet-facing NLB)
  set {
    name  = "service.type"
    value = "LoadBalancer"
  }

  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }

  # Prometheus data source
  set {
    name  = "datasources.datasources\\.yaml.apiVersion"
    value = "1"
  }

  set {
    name  = "datasources.datasources\\.yaml.datasources[0].name"
    value = "Prometheus"
  }

  set {
    name  = "datasources.datasources\\.yaml.datasources[0].type"
    value = "prometheus"
  }

  set {
    name  = "datasources.datasources\\.yaml.datasources[0].url"
    value = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
  }

  set {
    name  = "datasources.datasources\\.yaml.datasources[0].isDefault"
    value = "true"
  }

  set {
    name  = "datasources.datasources\\.yaml.datasources[0].access"
    value = "proxy"
  }

  set {
    name  = "datasources.datasources\\.yaml.datasources[0].uid"
    value = "prometheus"
  }

  # Dashboard provider — auto-load dashboards from ConfigMaps with label grafana_dashboard=1
  set {
    name  = "sidecar.dashboards.enabled"
    value = "true"
  }

  set {
    name  = "sidecar.dashboards.label"
    value = "grafana_dashboard"
  }

  set {
    name  = "sidecar.dashboards.searchNamespace"
    value = "monitoring"
  }

  depends_on = [
    helm_release.kube_prometheus_stack,
    kubernetes_secret.grafana_admin,
  ]
}

################################################################################
# HPA for Web Deployment
################################################################################

resource "kubernetes_horizontal_pod_autoscaler_v2" "web_hpa" {
  metadata {
    name      = "web-hpa"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "web"
    }

    min_replicas = 1
    max_replicas = 3

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }
}
