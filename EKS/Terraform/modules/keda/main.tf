################################################################################
# KEDA Namespace
################################################################################

resource "kubernetes_namespace" "keda" {
  metadata {
    name = var.keda_namespace
    labels = {
      name = var.keda_namespace
    }
  }
}

################################################################################
# KEDA Helm Release
################################################################################

resource "helm_release" "keda" {
  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  namespace  = kubernetes_namespace.keda.metadata[0].name

  # Enable Prometheus metrics on the KEDA metrics server
  set {
    name  = "prometheus.metricServer.enabled"
    value = "true"
  }

  # Create ServiceMonitor for Prometheus Operator to auto-discover KEDA metrics
  set {
    name  = "prometheus.metricServer.serviceMonitor.enabled"
    value = "true"
  }

  # Enable metrics on the KEDA operator
  set {
    name  = "prometheus.operator.enabled"
    value = "true"
  }

  # Create ServiceMonitor for KEDA operator metrics
  set {
    name  = "prometheus.operator.serviceMonitor.enabled"
    value = "true"
  }

  # Enable webhook metrics
  set {
    name  = "prometheus.webhooks.enabled"
    value = "true"
  }

  set {
    name  = "prometheus.webhooks.serviceMonitor.enabled"
    value = "true"
  }
}
