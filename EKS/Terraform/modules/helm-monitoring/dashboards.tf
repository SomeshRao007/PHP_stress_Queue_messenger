################################################################################
# KEDA Scaling Dashboard — ConfigMap loaded by Grafana sidecar
################################################################################

resource "kubernetes_config_map" "keda_dashboard" {
  metadata {
    name      = "grafana-dashboard-keda"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "keda-scaling.json" = jsonencode({
      annotations = {
        list = []
      }
      editable    = true
      title       = "KEDA Scaling Overview"
      uid         = "keda-scaling-overview"
      version     = 1
      timezone    = "browser"
      schemaVersion = 39
      templating = {
        list = [
          {
            name       = "namespace"
            type       = "constant"
            query      = "php-job-demo"
            current    = { value = "php-job-demo", text = "php-job-demo" }
            hide       = 0
          }
        ]
      }
      panels = [
        {
          id         = 1
          title      = "KEDA Scaler Metric Value (Queue Depth)"
          type       = "timeseries"
          gridPos    = { h = 8, w = 12, x = 0, y = 0 }
          datasource = { type = "prometheus", uid = "prometheus" }
          targets = [
            {
              expr         = "keda_scaler_metrics_value{exported_namespace=\"$namespace\"}"
              legendFormat = "{{scaledObject}} - {{scaler}}"
              refId        = "A"
            }
          ]
          fieldConfig = {
            defaults = {
              unit = "short"
              custom = {
                drawStyle    = "line"
                lineWidth    = 2
                fillOpacity  = 20
                pointSize    = 5
                showPoints   = "auto"
              }
            }
          }
        },
        {
          id         = 2
          title      = "Worker Deployment Replicas (Desired vs Actual)"
          type       = "timeseries"
          gridPos    = { h = 8, w = 12, x = 12, y = 0 }
          datasource = { type = "prometheus", uid = "prometheus" }
          targets = [
            {
              expr         = "kube_deployment_spec_replicas{namespace=\"$namespace\", deployment=\"worker\"}"
              legendFormat = "Desired Replicas"
              refId        = "A"
            },
            {
              expr         = "kube_deployment_status_replicas{namespace=\"$namespace\", deployment=\"worker\"}"
              legendFormat = "Actual Replicas"
              refId        = "B"
            },
            {
              expr         = "kube_deployment_status_replicas_ready{namespace=\"$namespace\", deployment=\"worker\"}"
              legendFormat = "Ready Replicas"
              refId        = "C"
            }
          ]
          fieldConfig = {
            defaults = {
              unit = "short"
              custom = {
                drawStyle    = "line"
                lineWidth    = 2
                fillOpacity  = 10
              }
            }
          }
        },
        {
          id         = 3
          title      = "KEDA ScaledObject Status"
          type       = "stat"
          gridPos    = { h = 4, w = 6, x = 0, y = 8 }
          datasource = { type = "prometheus", uid = "prometheus" }
          targets = [
            {
              expr         = "keda_scaler_active{exported_namespace=\"$namespace\"}"
              legendFormat = "{{scaledObject}}"
              refId        = "A"
            }
          ]
          fieldConfig = {
            defaults = {
              mappings = [
                { type = "value", options = { "1" = { text = "Active", color = "green" } } },
                { type = "value", options = { "0" = { text = "Inactive", color = "red" } } }
              ]
            }
          }
        },
        {
          id         = 4
          title      = "KEDA Scaler Errors"
          type       = "timeseries"
          gridPos    = { h = 4, w = 6, x = 6, y = 8 }
          datasource = { type = "prometheus", uid = "prometheus" }
          targets = [
            {
              expr         = "rate(keda_scaled_object_errors_total{exported_namespace=\"$namespace\"}[5m])"
              legendFormat = "{{scaledObject}} errors/sec"
              refId        = "A"
            }
          ]
          fieldConfig = {
            defaults = {
              unit = "ops"
              custom = {
                drawStyle   = "bars"
                fillOpacity = 80
              }
              thresholds = {
                steps = [
                  { value = 0, color = "green" },
                  { value = 0.1, color = "red" }
                ]
              }
            }
          }
        },
        {
          id         = 5
          title      = "KEDA Trigger Totals"
          type       = "stat"
          gridPos    = { h = 4, w = 6, x = 12, y = 8 }
          datasource = { type = "prometheus", uid = "prometheus" }
          targets = [
            {
              expr         = "keda_trigger_registered_total{type=\"postgresql\"}"
              legendFormat = "{{type}} triggers"
              refId        = "A"
            }
          ]
        },
        {
          id         = 6
          title      = "ScaledJob — Active / Succeeded / Failed"
          type       = "timeseries"
          gridPos    = { h = 8, w = 12, x = 0, y = 12 }
          datasource = { type = "prometheus", uid = "prometheus" }
          targets = [
            {
              expr         = "count(kube_job_status_active{namespace=\"$namespace\"} == 1) OR vector(0)"
              legendFormat = "Active Jobs"
              refId        = "A"
            },
            {
              expr         = "count(kube_job_status_succeeded{namespace=\"$namespace\"} == 1) OR vector(0)"
              legendFormat = "Succeeded Jobs"
              refId        = "B"
            },
            {
              expr         = "count(kube_job_status_failed{namespace=\"$namespace\"} > 0) OR vector(0)"
              legendFormat = "Failed Jobs"
              refId        = "C"
            }
          ]
          fieldConfig = {
            defaults = {
              unit = "short"
              custom = {
                drawStyle    = "line"
                lineWidth    = 2
                fillOpacity  = 20
              }
            }
            overrides = [
              { matcher = { id = "byName", options = "Active Jobs" }, properties = [{ id = "color", value = { fixedColor = "blue" } }] },
              { matcher = { id = "byName", options = "Succeeded Jobs" }, properties = [{ id = "color", value = { fixedColor = "green" } }] },
              { matcher = { id = "byName", options = "Failed Jobs" }, properties = [{ id = "color", value = { fixedColor = "red" } }] }
            ]
          }
        },
        {
          id         = 7
          title      = "ScaledJob — Job Pods (Running / Completed)"
          type       = "timeseries"
          gridPos    = { h = 8, w = 12, x = 12, y = 12 }
          datasource = { type = "prometheus", uid = "prometheus" }
          targets = [
            {
              expr         = "count(kube_pod_status_phase{namespace=\"$namespace\", phase=\"Running\"} * on(pod) group_left kube_pod_labels{namespace=\"$namespace\", label_component=\"worker-job\"} == 1) OR vector(0)"
              legendFormat = "Running Job Pods"
              refId        = "A"
            },
            {
              expr         = "count(kube_pod_status_phase{namespace=\"$namespace\", phase=\"Succeeded\"} * on(pod) group_left kube_pod_labels{namespace=\"$namespace\", label_component=\"worker-job\"} == 1) OR vector(0)"
              legendFormat = "Completed Job Pods"
              refId        = "B"
            },
            {
              expr         = "count(kube_pod_status_phase{namespace=\"$namespace\", phase=\"Pending\"} * on(pod) group_left kube_pod_labels{namespace=\"$namespace\", label_component=\"worker-job\"} == 1) OR vector(0)"
              legendFormat = "Pending Job Pods"
              refId        = "C"
            }
          ]
          fieldConfig = {
            defaults = {
              unit = "short"
              custom = {
                drawStyle    = "line"
                lineWidth    = 2
                fillOpacity  = 15
              }
            }
            overrides = [
              { matcher = { id = "byName", options = "Running Job Pods" }, properties = [{ id = "color", value = { fixedColor = "green" } }] },
              { matcher = { id = "byName", options = "Completed Job Pods" }, properties = [{ id = "color", value = { fixedColor = "blue" } }] },
              { matcher = { id = "byName", options = "Pending Job Pods" }, properties = [{ id = "color", value = { fixedColor = "yellow" } }] }
            ]
          }
        }
      ]
      time = {
        from = "now-1h"
        to   = "now"
      }
      refresh = "10s"
    })
  }
}

################################################################################
# Pod Lifecycle Dashboard — tracks pod states during scale events
################################################################################

resource "kubernetes_config_map" "pod_lifecycle_dashboard" {
  metadata {
    name      = "grafana-dashboard-pod-lifecycle"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "pod-lifecycle.json" = jsonencode({
      annotations = {
        list = []
      }
      editable    = true
      title       = "Pod Lifecycle - Scale Events"
      uid         = "pod-lifecycle-scale-events"
      version     = 1
      timezone    = "browser"
      schemaVersion = 39
      templating = {
        list = [
          {
            name       = "namespace"
            type       = "constant"
            query      = "php-job-demo"
            current    = { value = "php-job-demo", text = "php-job-demo" }
            hide       = 0
          }
        ]
      }
      panels = [
        {
          id         = 1
          title      = "Pods by Phase (Pending / Running / Succeeded / Failed)"
          type       = "timeseries"
          gridPos    = { h = 8, w = 24, x = 0, y = 0 }
          datasource = { type = "prometheus", uid = "prometheus" }
          targets = [
            {
              expr         = "sum by (phase) (kube_pod_status_phase{namespace=\"$namespace\"})"
              legendFormat = "{{phase}}"
              refId        = "A"
            }
          ]
          fieldConfig = {
            defaults = {
              unit = "short"
              custom = {
                drawStyle    = "line"
                lineWidth    = 2
                fillOpacity  = 30
                stacking     = { mode = "normal" }
              }
            }
            overrides = [
              { matcher = { id = "byName", options = "Running" }, properties = [{ id = "color", value = { fixedColor = "green" } }] },
              { matcher = { id = "byName", options = "Pending" }, properties = [{ id = "color", value = { fixedColor = "yellow" } }] },
              { matcher = { id = "byName", options = "Succeeded" }, properties = [{ id = "color", value = { fixedColor = "blue" } }] },
              { matcher = { id = "byName", options = "Failed" }, properties = [{ id = "color", value = { fixedColor = "red" } }] }
            ]
          }
        },
        {
          id         = 2
          title      = "Container States (Waiting Reasons)"
          type       = "timeseries"
          gridPos    = { h = 8, w = 12, x = 0, y = 8 }
          datasource = { type = "prometheus", uid = "prometheus" }
          targets = [
            {
              expr         = "sum by (reason) (kube_pod_container_status_waiting_reason{namespace=\"$namespace\"})"
              legendFormat = "Waiting: {{reason}}"
              refId        = "A"
            }
          ]
          fieldConfig = {
            defaults = {
              unit = "short"
              custom = {
                drawStyle   = "bars"
                fillOpacity = 80
              }
            }
          }
        },
        {
          id         = 3
          title      = "Container Restarts"
          type       = "timeseries"
          gridPos    = { h = 8, w = 12, x = 12, y = 8 }
          datasource = { type = "prometheus", uid = "prometheus" }
          targets = [
            {
              expr         = "sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace=\"$namespace\"}[5m]))"
              legendFormat = "{{pod}}"
              refId        = "A"
            }
          ]
          fieldConfig = {
            defaults = {
              unit = "short"
              custom = {
                drawStyle   = "bars"
                fillOpacity = 60
              }
              thresholds = {
                steps = [
                  { value = 0, color = "green" },
                  { value = 1, color = "orange" },
                  { value = 3, color = "red" }
                ]
              }
            }
          }
        },
        {
          id         = 4
          title      = "Web Deployment Replicas (HPA)"
          type       = "timeseries"
          gridPos    = { h = 8, w = 12, x = 0, y = 16 }
          datasource = { type = "prometheus", uid = "prometheus" }
          targets = [
            {
              expr         = "kube_deployment_spec_replicas{namespace=\"$namespace\", deployment=\"web\"}"
              legendFormat = "Web Desired"
              refId        = "A"
            },
            {
              expr         = "kube_deployment_status_replicas_ready{namespace=\"$namespace\", deployment=\"web\"}"
              legendFormat = "Web Ready"
              refId        = "B"
            }
          ]
          fieldConfig = {
            defaults = {
              unit = "short"
              custom = {
                drawStyle    = "line"
                lineWidth    = 2
                fillOpacity  = 15
              }
            }
          }
        },
        {
          id         = 5
          title      = "Node Count"
          type       = "timeseries"
          gridPos    = { h = 8, w = 12, x = 12, y = 16 }
          datasource = { type = "prometheus", uid = "prometheus" }
          targets = [
            {
              expr         = "count(kube_node_info)"
              legendFormat = "Total Nodes"
              refId        = "A"
            },
            {
              expr         = "sum(kube_node_status_condition{condition=\"Ready\", status=\"true\"})"
              legendFormat = "Ready Nodes"
              refId        = "B"
            }
          ]
          fieldConfig = {
            defaults = {
              unit = "short"
              custom = {
                drawStyle    = "line"
                lineWidth    = 2
                fillOpacity  = 15
              }
            }
          }
        }
      ]
      time = {
        from = "now-1h"
        to   = "now"
      }
      refresh = "10s"
    })
  }
}
