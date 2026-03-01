# EKS Infrastructure — OpenTofu / Terraform

Fully reproducible, modular OpenTofu code that provisions a VPC, EKS cluster, monitoring stack (Prometheus + Grafana), KEDA, Cluster Autoscaler, and AWS Load Balancer Controller — all in one `tofu apply`.

Built to support a **PHP Symfony application** that processes async jobs via Doctrine Messenger backed by PostgreSQL, with KEDA for event-driven autoscaling of worker pods.

---

## Architecture Overview

```
                          ┌──────────────────────────────────┐
                          │         AWS Cloud (us-east-1)    │
                          │                                  │
┌─────────┐   NLB    ┌───┴───────────────────────────────┐  │
│  User    │────────→ │  Public Subnets (10.0.101-102/24) │  │
│ Browser  │          │  ├─ NAT Gateway                   │  │
└─────────┘          │  └─ NLB → web pods                │  │
                      └───┬───────────────────────────────┘  │
                          │                                  │
                      ┌───┴───────────────────────────────┐  │
                      │  Private Subnets (10.0.1-2/24)    │  │
                      │                                   │  │
                      │  ┌─────────────────────────────┐  │  │
                      │  │     EKS Node Group           │  │  │
                      │  │     (c6a.large × 2-5)        │  │  │
                      │  │                              │  │  │
                      │  │  ┌──────┐  ┌─────────────┐  │  │  │
                      │  │  │ web  │  │  worker ×N   │  │  │  │
                      │  │  │ pod  │  │  (KEDA)      │  │  │  │
                      │  │  └──┬───┘  └──────┬──────┘  │  │  │
                      │  │     │              │         │  │  │
                      │  └─────┼──────────────┼─────────┘  │  │
                      │        │              │            │  │
                      └────────┼──────────────┼────────────┘  │
                               │              │               │
                          ┌────┴──────────────┴────┐          │
                          │  Akamai PostgreSQL DB   │          │
                          │  (messenger_messages)   │          │
                          └─────────────────────────┘          │
                          └────────────────────────────────────┘
```

**Data flow:**
1. User submits a job via the web UI (NLB → web pod)
2. Web pod writes a message to `messenger_messages` table in PostgreSQL
3. KEDA polls the table every 15s: `SELECT COUNT(*) FROM messenger_messages`
4. If messages exist → KEDA scales worker Deployment from 0 to N
5. Workers consume messages, process jobs, delete messages from table
6. Queue empty → KEDA scales workers back to 0

---

## Directory Structure

```
EKS/Terraform/
├── modules/
│   ├── vpc/                        # VPC with public/private subnets
│   │   ├── main.tf                 # terraform-aws-modules/vpc/aws wrapper
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── eks/                        # EKS cluster + node group + IRSA
│   │   ├── main.tf                 # aws_eks_cluster, node group, SG rules, add-ons
│   │   ├── irsa.tf                 # OIDC provider + 3 IRSA roles
│   │   ├── lb-controller-iam-policy.json
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── helm-monitoring/            # Prometheus, Grafana, LB Controller, Autoscaler
│   │   ├── main.tf                 # 4 Helm releases + namespaces + HPA
│   │   ├── dashboards.tf           # Grafana dashboard ConfigMaps (KEDA + Pod Lifecycle)
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── keda/                       # KEDA with Prometheus metrics
│       ├── main.tf                 # KEDA Helm release + namespace
│       ├── variables.tf
│       └── outputs.tf
└── environments/
    └── dev/                        # Dev environment root
        ├── main.tf                 # Wires all 4 modules together
        ├── providers.tf            # AWS, Kubernetes, Helm providers
        ├── backend.tf              # S3 remote state
        ├── versions.tf             # Provider version constraints
        ├── variables.tf
        ├── outputs.tf
        └── terraform.tfvars        # Concrete values
```

---

## Module Dependency Graph

```
module.vpc
    └──→ module.eks
             ├──→ OIDC Provider + 3 IRSA Roles
             ├──→ Node Group + EKS Add-ons
             └──→ data.aws_eks_cluster (provider auth)
                      ├──→ module.helm_monitoring
                      │        ├─ AWS LB Controller
                      │        ├─ Cluster Autoscaler
                      │        ├─ kube-prometheus-stack
                      │        ├─ Grafana + Dashboards
                      │        └─ HPA (web deployment)
                      └──→ module.keda (depends_on: helm_monitoring)
                               └─ KEDA Helm release + ServiceMonitors
```

**Why KEDA depends on helm_monitoring:** The AWS Load Balancer Controller registers a mutating webhook. If KEDA tries to create Services before the webhook has endpoints, it fails with `"no endpoints available for service aws-load-balancer-webhook-service"`.

---

## Module Details

### 1. VPC Module (`modules/vpc/`)

Wraps `terraform-aws-modules/vpc/aws` (~> 5.0) to create a production VPC.

| Setting | Value | Reason |
|---------|-------|--------|
| CIDR | 10.0.0.0/16 | 65k IPs, plenty for EKS pods |
| AZs | us-east-1a, us-east-1b | Multi-AZ for HA |
| Private subnets | 10.0.1.0/24, 10.0.2.0/24 | Worker nodes (no direct internet) |
| Public subnets | 10.0.101.0/24, 10.0.102.0/24 | NAT gateway + NLB placement |
| NAT gateway | Single | Cost optimization (trade-off: single AZ for outbound) |
| DNS | Enabled | Required for EKS service discovery |

**Critical subnet tags for EKS auto-discovery:**

```hcl
# Public subnets — AWS LB Controller finds these for internet-facing NLBs
"kubernetes.io/role/elb" = "1"

# Private subnets — for internal load balancers
"kubernetes.io/role/internal-elb" = "1"

# Both — cluster ownership
"kubernetes.io/cluster/${cluster_name}" = "shared"
```

Without these tags, the AWS Load Balancer Controller cannot discover which subnets to place NLBs in.

---

### 2. EKS Module (`modules/eks/`)

Uses **raw AWS resources** (`aws_eks_cluster`, `aws_eks_node_group`) instead of the community EKS module. This avoids conflicts with pre-existing IAM roles that the community module would try to create.

#### Cluster Configuration

- **K8s version:** 1.35 (EKS GA since Jan 2026)
- **Endpoint access:** Public + Private (kubectl from anywhere, nodes use private endpoint)
- **IAM roles:** Pre-existing, passed as variables — **not created by Terraform**

#### Node Group

- **Instance type:** c6a.large (2 vCPU, 4 GiB RAM, AMD EPYC, ~29 max pods/node)
- **Scaling:** 2 desired / 2 min / 5 max (Cluster Autoscaler manages within these bounds)
- **Placement:** Private subnets only (outbound via NAT gateway)
- **Disk:** 30 GiB gp3

#### Security Group Rules

EKS creates a cluster security group automatically. We add two ingress rules:

```hcl
# NodePort range — NLB routes traffic to pods via NodePorts
aws_security_group_rule "nodeport_ingress"  → 30000-32767/tcp from 0.0.0.0/0

# HTTP direct — for NLB instance mode with target port 80
aws_security_group_rule "http_ingress"      → 80/tcp from 0.0.0.0/0
```

Without these, the web application would return `ERR_CONNECTION_REFUSED` because NLB health checks and traffic get blocked.

#### EKS Add-ons

| Add-on | Purpose | IRSA |
|--------|---------|------|
| vpc-cni | Pod networking (assigns VPC IPs to pods) | AWS-managed |
| coredns | Cluster DNS resolution | AWS-managed |
| kube-proxy | Service networking (iptables rules) | AWS-managed |
| aws-ebs-csi-driver | EBS volume provisioning for PVCs | Custom IRSA role |

All add-ons use `resolve_conflicts_on_update = "OVERWRITE"` for seamless cluster upgrades.

#### IRSA (IAM Roles for Service Accounts) — `irsa.tf`

IRSA replaces node-level IAM with per-pod permissions using OIDC federation. Each service gets only the permissions it needs.

**OIDC Provider:** Created from the cluster's identity issuer URL. Establishes trust between AWS IAM and Kubernetes service accounts.

| IRSA Role | Service Account | Namespace | Policy |
|-----------|-----------------|-----------|--------|
| EBS CSI Driver | `ebs-csi-controller-sa` | kube-system | `AmazonEBSCSIDriverPolicy` (AWS managed) |
| AWS LB Controller | `aws-load-balancer-controller` | kube-system | Custom JSON (250 lines, scoped by cluster tag) |
| Cluster Autoscaler | `cluster-autoscaler` | kube-system | Inline (EC2 + ASG + EKS describe permissions) |

**Why IRSA over node IAM roles:**
- **Least privilege:** Each pod gets only its required permissions
- **Temporary credentials:** STS tokens, auto-rotated (no long-lived keys)
- **Audit trail:** CloudTrail shows which service account assumed which role
- **Multi-tenant safe:** Worker pods can't access LB Controller permissions

**LB Controller IAM Policy** (`lb-controller-iam-policy.json`): Committed as a static file from the official AWS repo. Includes permissions for EC2 security groups, ELB management, ACM certificates, and WAF — all scoped to resources tagged with `elbv2.k8s.aws/cluster`.

---

### 3. Helm Monitoring Module (`modules/helm-monitoring/`)

Installs the full observability and autoscaling stack via 4 Helm releases + K8s resources.

#### Components

**a) AWS Load Balancer Controller** (kube-system)
- Chart: `aws-load-balancer-controller` from `https://aws.github.io/eks-charts`
- Annotated with LB Controller IRSA role
- Creates NLBs when Services have `service.beta.kubernetes.io/aws-load-balancer-type: nlb`

**b) Cluster Autoscaler** (kube-system)
- Chart: `cluster-autoscaler` from `https://kubernetes.github.io/autoscaler`
- Auto-discovers the cluster by name
- `skip-nodes-with-system-pods = false` — allows scaling nodes with system pods (important when KEDA creates many job pods)
- Annotated with Cluster Autoscaler IRSA role

**c) kube-prometheus-stack** (monitoring)
- Chart: `kube-prometheus-stack` from `https://prometheus-community.github.io/helm-charts`
- Includes: Prometheus server, kube-state-metrics, node-exporter, ServiceMonitor CRDs
- **NOT included:** Grafana (we use standalone), Alertmanager (not needed for demo)

Key Prometheus settings:
```
Replicas:         1
Retention:        15 days
Storage:          10 Gi PVC (gp2)

# Cross-namespace ServiceMonitor discovery (finds KEDA metrics in keda namespace)
serviceMonitorSelectorNilUsesHelmValues: false
podMonitorSelectorNilUsesHelmValues: false
```

The `serviceMonitorSelectorNilUsesHelmValues: false` setting is critical — without it, Prometheus only discovers ServiceMonitors with the Helm release's labels, missing KEDA's ServiceMonitors in the `keda` namespace.

**d) Grafana** (monitoring)
- Chart: `grafana` from `https://grafana.github.io/helm-charts`
- Standalone (not kube-prometheus-stack's built-in Grafana) for full customization
- Exposed via internet-facing NLB
- Admin credentials stored in K8s Secret (`grafana-admin-credentials`)
- Prometheus pre-configured as default datasource with UID `prometheus`
- Sidecar loads dashboards from ConfigMaps with label `grafana_dashboard=1`

**e) HPA for Web Deployment** (php-job-demo)
- Targets the `web` Deployment
- Scale range: 1–3 replicas
- Metric: CPU utilization > 70% average

#### Grafana Dashboards (`dashboards.tf`)

Two dashboards provisioned as ConfigMaps:

**Dashboard 1: KEDA Scaling Overview**

| Panel | Metric | What It Shows |
|-------|--------|---------------|
| Queue Depth | `keda_scaler_metrics_value{exported_namespace=...}` | Messages in PostgreSQL table over time |
| Worker Replicas | `kube_deployment_spec_replicas` / `status_replicas` / `status_replicas_ready` | Desired vs Actual vs Ready worker count |
| ScaledObject Status | `keda_scaler_active{exported_namespace=...}` | Active (green) / Inactive (red) |
| Scaler Errors | `rate(keda_scaled_object_errors_total[5m])` | DB connection failures, query errors |
| Trigger Totals | `keda_trigger_registered_total{type="postgresql"}` | Number of registered triggers |
| ScaledJob Active/Succeeded/Failed | `kube_job_status_active/succeeded/failed` | Job lifecycle when using ScaledJob |
| ScaledJob Pod Phases | `kube_pod_status_phase` × `kube_pod_labels{component="worker-job"}` | Running / Completed / Pending job pods |

**Important label note:** KEDA metrics use `namespace="keda"` (operator namespace) and `exported_namespace="php-job-demo"` (target namespace). Queries must filter on `exported_namespace`, not `namespace`.

**Dashboard 2: Pod Lifecycle - Scale Events**

| Panel | What It Shows |
|-------|---------------|
| Pods by Phase | Stacked chart of Pending/Running/Succeeded/Failed pods |
| Container Waiting Reasons | ContainerCreating, CrashLoopBackOff, ImagePullBackOff (empty = healthy) |
| Container Restarts | Per-pod restart count (highlights crash loops) |
| Web Deployment Replicas | HPA scaling of the web tier |
| Node Count | Total vs Ready nodes (shows Cluster Autoscaler activity) |

---

### 4. KEDA Module (`modules/keda/`)

Installs KEDA with full Prometheus observability.

```hcl
helm_release "keda" {
  chart = "keda"
  repository = "https://kedacore.github.io/charts"
}
```

**Prometheus integration enabled:**
- `prometheus.metricServer.enabled` + ServiceMonitor
- `prometheus.operator.enabled` + ServiceMonitor
- `prometheus.webhooks.enabled` + ServiceMonitor

This creates 3 ServiceMonitors that Prometheus auto-discovers (thanks to `serviceMonitorSelectorNilUsesHelmValues: false`), exposing metrics like:
- `keda_scaler_metrics_value` — current queue depth as seen by KEDA
- `keda_scaler_active` — whether the scaler trigger is firing
- `keda_scaled_object_errors_total` — scaler errors (DB connection timeouts, etc.)
- `keda_internal_scale_loop_latency_seconds` — time between KEDA polling cycles

---

## Environment Configuration (`environments/dev/`)

### Provider Authentication Pattern

The Kubernetes and Helm providers need the EKS cluster endpoint and auth token, but the cluster doesn't exist yet during the first `tofu apply`. This chicken-and-egg problem is solved with `depends_on`:

```hcl
# providers.tf
data "aws_eks_cluster" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]              # Wait until cluster exists
}

data "aws_eks_cluster_auth" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}
```

**First-apply note:** If provider auth fails (plan includes EKS changes), use a two-step apply:
```bash
tofu apply -target=module.vpc -target=module.eks
tofu apply
```

### Remote State

```hcl
# backend.tf
backend "s3" {
  bucket       = "ecs-fragate-tf-file"
  key          = "php-keda/terraform.tfstate"
  region       = "ap-south-1"           # Bucket region (not cluster region)
  use_lockfile = true                   # S3 native locking (OpenTofu >= 1.8)
}
```

### Concrete Values

```hcl
# terraform.tfvars
region          = "us-east-1"
cluster_name    = "KEDA-symfony-queue"
cluster_version = "1.35"

cluster_role_arn = "arn:aws:iam::469563970583:role/EKSclusterROLE"
worker_role_arn  = "arn:aws:iam::469563970583:role/Workernodepolicy_EKS"

grafana_admin_password = "admin123"
```

---

## Key Design Decisions

### Why raw EKS resources instead of the community EKS module?

The `terraform-aws-modules/eks/aws` community module creates its own IAM roles, OIDC provider, and security groups. Since we use **pre-existing IAM roles** (managed outside Terraform by the security team), the community module would conflict. Raw resources give full control over what gets created.

### Why separate Grafana instead of kube-prometheus-stack's built-in?

kube-prometheus-stack includes Grafana but with limited customization. A standalone Grafana chart lets us:
- Load custom dashboards via ConfigMap sidecar
- Configure persistence independently
- Set a dedicated LoadBalancer service
- Manage admin credentials separately

### Why two worker scaling strategies (ScaledObject + ScaledJob)?

| | ScaledObject | ScaledJob |
|---|---|---|
| **How it works** | Scales Deployment replicas (0–10) | Creates K8s Job per message |
| **Worker lifetime** | Long-lived (1 hour `--time-limit=3600`) | Short-lived (1 message `--limit=1`) |
| **Pod reuse** | Same pod handles many messages | New pod per message |
| **Scale-down** | KEDA reduces replica count (can kill pods) | Jobs run to completion independently |
| **Best for** | Sustained queue load, connection pooling | Variable message complexity, clean isolation |

**Critical query difference:**

```sql
-- ScaledObject: COUNT(*) — include messages being processed
-- (prevents KEDA from killing workers mid-processing)
SELECT COUNT(*) FROM messenger_messages

-- ScaledJob: only unclaimed messages
-- (prevents duplicate jobs for messages already being processed)
SELECT COUNT(*) FROM messenger_messages
WHERE delivered_at IS NULL AND available_at <= NOW()
```

ScaledObject needs `COUNT(*)` because KEDA controls replica count — if it only counts unclaimed messages, it scales to 0 and kills workers mid-processing. ScaledJob needs the WHERE clause because jobs run to completion and we only want new jobs for unclaimed messages.

### Why IRSA instead of node IAM roles?

Node IAM roles grant permissions to every pod on the node. IRSA uses OIDC federation to give each service account its own temporary credentials — principle of least privilege.

### Why single NAT gateway?

Cost optimization. A single NAT gateway handles all outbound traffic from private subnets. Trade-off: if us-east-1a goes down, outbound connectivity is lost. For production, use `enable_nat_gateway = true` with `one_nat_gateway_per_az = true`.

---

## Deployment

### Prerequisites

- AWS account with pre-existing EKS cluster and worker node IAM roles
- OpenTofu >= 1.8.0 (or Terraform >= 1.5.0)
- AWS CLI configured (`aws sts get-caller-identity` works)
- S3 bucket for remote state

### First-time Setup

```bash
cd EKS/Terraform/environments/dev

# Initialize (downloads providers + modules)
tofu init

# Preview changes
tofu plan -out=tfplan

# Apply (~10-15 minutes)
tofu apply tfplan

# Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name KEDA-symfony-queue

# Verify cluster
kubectl get nodes
kubectl get pods -A
```

### Deploy Application

```bash
kubectl apply -f EKS/00-namespace.yaml
kubectl apply -f EKS/01-secrets.yaml
kubectl apply -f EKS/02-web-deployment.yaml
kubectl apply -f EKS/03-web-service.yaml
kubectl apply -f EKS/04-worker-deployment.yaml
kubectl apply -f EKS/05-keda-trigger-auth.yaml
kubectl apply -f EKS/06-keda-scaled-object.yaml    # OR 07-keda-scaled-job.yaml
```

### Access Services

```bash
# Web application URL
kubectl get svc web -n php-job-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Grafana URL
kubectl get svc grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# Login: admin / admin123
```

---

## Monitoring & Debugging

### Check KEDA Scaling

```bash
# ScaledObject status
kubectl get scaledobject -n php-job-demo

# Watch worker pods scale
watch -n 2 'kubectl get pods -n php-job-demo -l component=worker'

# KEDA operator logs (scaling decisions)
kubectl logs -n keda -l app=keda-operator -f --tail=50

# Queue depth from Prometheus
kubectl exec -n monitoring $(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o name | head -1) \
  -c prometheus -- wget -qO- \
  'http://localhost:9090/api/v1/query?query=keda_scaler_metrics_value{exported_namespace="php-job-demo"}'
```

### Check Cluster Autoscaler

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler -f --tail=50
```

### Check Web HPA

```bash
kubectl get hpa -n php-job-demo
```

---

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `ERR_CONNECTION_REFUSED` on web | Missing NodePort security group rules | Verify `aws_security_group_rule` resources exist |
| `ERR_TIMED_OUT` on Grafana | NLB is internal (missing annotation) | Add `aws-load-balancer-scheme: internet-facing` |
| KEDA `ACTIVE=False` with pending jobs | Wrong query (only counting unclaimed messages in ScaledObject) | Use `SELECT COUNT(*) FROM messenger_messages` |
| Duplicate ScaledJob pods doing nothing | Wrong query (counting all messages in ScaledJob) | Use `WHERE delivered_at IS NULL AND available_at <= NOW()` |
| `Kubernetes cluster unreachable` | Provider chicken-and-egg during first apply | `tofu apply -target=module.vpc -target=module.eks` first |
| KEDA webhook failure | LB Controller not ready when KEDA deploys | Ensure `depends_on = [module.helm_monitoring]` on KEDA module |
| Web pod crash-looping | External DB not reachable from private subnets | Add NAT gateway public IP to DB allowlist |
| Grafana dashboards show "No data" | KEDA metrics use `exported_namespace` not `namespace` | Query with `exported_namespace="php-job-demo"` |

---

## Cost Considerations

| Resource | Approx. Monthly Cost | Notes |
|----------|---------------------|-------|
| EKS control plane | $73 | Fixed cost |
| 2× c6a.large (on-demand) | ~$124 | Min nodes always running |
| NAT gateway | ~$32 + data transfer | Single AZ |
| 2× NLB (web + Grafana) | ~$32 + LCU charges | Internet-facing |
| EBS volumes (3× gp2) | ~$3 | Prometheus 10Gi + Grafana 5Gi + node 30Gi |
| S3 state storage | < $1 | Negligible |
| **Total baseline** | **~$265/month** | Before autoscaling |

Workers scale to 0 when idle — no cost for worker pods outside of active processing.
