# EKS Deployment Guide - KEDA Autoscaling Demo

Complete guide to deploying the PHP Job Queue application on AWS EKS with KEDA autoscaling. Covers the Dockerfile, all Kubernetes manifests, KEDA configuration, the scaling comparison test procedure, and every error encountered during deployment with their resolutions.

---

## Table of Contents

1. [Docker Image](#1-docker-image)
2. [Kubernetes Manifest Reference](#2-kubernetes-manifest-reference)
3. [EKS Cluster Setup Walkthrough](#3-eks-cluster-setup-walkthrough)
4. [KEDA Installation](#4-keda-installation)
5. [Deployment Steps](#5-deployment-steps)
6. [How KEDA Scaling Works](#6-how-keda-scaling-works)
7. [ScaledObject vs ScaledJob Comparison](#7-scaledobject-vs-scaledjob-comparison)
8. [Scaling Monitor & Analyzer](#8-scaling-monitor--analyzer)
9. [Running the Comparison Test](#9-running-the-comparison-test)
10. [Errors Encountered & Resolutions](#10-errors-encountered--resolutions)

---

## 1. Docker Image

### Dockerfile Breakdown

The application is containerized using `php:8.4-apache` as the base image.

```dockerfile
FROM php:8.4-apache

# System dependencies for PHP extensions
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev libicu-dev libzip-dev unzip

# PHP extensions required by the app
RUN docker-php-ext-install pdo_pgsql intl zip opcache

# Apache mod_rewrite for Symfony routing
RUN a2enmod rewrite
COPY docker/apache.conf /etc/apache2/sites-available/000-default.conf

# Composer for dependency management
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

# Install dependencies (production, optimized autoloader)
COPY composer.json composer.lock symfony.lock ./
RUN composer install --no-dev --optimize-autoloader --no-scripts --no-interaction

# Copy source and warm cache
COPY . .
RUN DATABASE_URL="..." composer run-script post-install-cmd \
    && DATABASE_URL="..." php bin/console cache:warmup

RUN chown -R www-data:www-data var/
EXPOSE 80
```

**Key decisions:**
- **`pdo_pgsql`** — Required for Doctrine ORM and Messenger's Doctrine transport
- **`intl`** — Required by Symfony's internationalization component
- **`zip`** — Required by the DataTransfer handler for creating ZIP archives
- **`opcache`** — PHP opcode caching for production performance
- **`--no-dev`** — Excludes development dependencies (debug toolbar, profiler) from the image
- **Cache warmup at build time** — Avoids slow first-request startup in Kubernetes pods. The `DATABASE_URL` is needed at build time because Symfony resolves it during cache compilation

### Apache Configuration (`docker/apache.conf`)

```apache
DocumentRoot /var/www/html/public
FallbackResource /index.php
```

Symfony requires all requests to route through `public/index.php`. The `FallbackResource` directive handles this without `.htaccess` files.

### Building and Pushing

```bash
cd /home/somesh/Desktop/k8s/Scale_KEDA/PHP_application_demo

# Build
docker build -t somesh0007/myrepo:php-job-extrdb .

# Push to Docker Hub
docker push somesh0007/myrepo:php-job-extrdb
```

The image is public on Docker Hub — no `imagePullSecrets` needed in Kubernetes.

---

## 2. Kubernetes Manifest Reference

All manifests live in this directory. They are numbered to indicate apply order.

```
EKS/
├── 00-namespace.yaml           # Namespace isolation
├── 01-secrets.yaml             # All sensitive configuration
├── 02-web-deployment.yaml      # Web dashboard (Apache + PHP)
├── 03-web-service.yaml         # NLB for external access
├── 04-worker-deployment.yaml   # Worker pods (KEDA-managed)
├── 05-keda-trigger-auth.yaml   # KEDA database authentication
├── 06-keda-scaled-object.yaml  # ScaledObject — scales Deployment replicas
├── 07-keda-scaled-job.yaml     # ScaledJob — creates K8s Jobs per message
├── 08-scaling-monitor.yaml     # CronJob + RBAC for metrics collection
└── scripts/
    └── keda-watcher.sh         # Terminal monitoring script
```

### `00-namespace.yaml` — Namespace

Creates the `php-job-demo` namespace. All resources are scoped to this namespace to keep them isolated from other workloads.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: php-job-demo
```

### `01-secrets.yaml` — Secrets

Contains **two** Kubernetes Secrets:

**`app-secrets`** — Injected into both web and worker pods via `envFrom`:

| Key | Purpose |
|-----|---------|
| `APP_ENV` | Symfony environment (`prod`) |
| `APP_SECRET` | Symfony framework secret |
| `DATABASE_URL` | Full PostgreSQL DSN for Doctrine |
| `MESSENGER_TRANSPORT_DSN` | Always `doctrine://default` |
| `AWS_ACCESS_KEY_ID` | For S3 DataTransfer jobs |
| `AWS_SECRET_ACCESS_KEY` | For S3 DataTransfer jobs |
| `AWS_REGION`, `S3_BUCKET`, `S3_ENDPOINT` | S3 configuration |
| `SSH_DEFAULT_HOST`, `SSH_DEFAULT_USER`, `SSH_DEFAULT_PASS` | For SSH jobs |

**`db-keda-secret`** — Used only by KEDA's TriggerAuthentication:

| Key | Purpose |
|-----|---------|
| `connection` | PostgreSQL connection string in libpq format |

Why two secrets: KEDA only needs the database connection string. Giving it a separate secret follows the principle of least privilege — KEDA never sees AWS credentials or SSH passwords.

`stringData` is used instead of `data` so values are human-readable in the manifest. Kubernetes base64-encodes them at rest automatically.

### `02-web-deployment.yaml` — Web Dashboard

```yaml
image: somesh0007/myrepo:php-job-extrdb
ports: [80]
resources:
  requests: { cpu: 250m, memory: 256Mi }
  limits:   { cpu: "1",  memory: 512Mi }
readinessProbe:  GET / port 80, delay 30s, timeout 5s
livenessProbe:   GET / port 80, delay 45s, timeout 5s
```

- **No `command` override** — Uses the Dockerfile's default entrypoint (Apache)
- **`envFrom: secretRef: app-secrets`** — All env vars injected from the Secret
- **Health probes hit `/`** — The dashboard route. Returns 200 when the app + DB are healthy
- **Higher initial delay** (30s/45s) — Symfony cache warmup on first request takes time
- **512Mi memory limit** — PHP + Apache + OPcache needs this much headroom

### `03-web-service.yaml` — LoadBalancer Service

```yaml
type: LoadBalancer
annotations:
  service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
  service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
```

- **`internet-facing`** — Creates a publicly accessible NLB (vs internal which is VPC-only)
- **`nlb`** — Required because EKS uses the AWS Load Balancer Controller, which only supports NLB for `type: LoadBalancer` services (not Classic LB)
- The NLB routes external traffic on port 80 to the web pods via NodePort

### `04-worker-deployment.yaml` — Worker Deployment

```yaml
replicas: 0                    # KEDA manages this
command: ["php", "bin/console", "messenger:consume", "async", "--time-limit=3600"]
```

- **`replicas: 0`** — Critical. KEDA scales from zero. When the queue is empty, no worker pods run
- **`command` override** — Replaces Apache with the Symfony Messenger consumer. The `--time-limit=3600` flag gracefully exits the worker after 1 hour, preventing memory leaks
- **No readiness/liveness probes** — Workers don't serve HTTP traffic. Adding HTTP probes would cause false-positive failures
- **Labels `component: worker`** — Used by KEDA's ScaledObject to target this Deployment

### `05-keda-trigger-auth.yaml` — TriggerAuthentication

```yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-pg-auth
spec:
  secretTargetRef:
    - parameter: connection
      name: db-keda-secret
      key: connection
```

Maps the `connection` key from `db-keda-secret` to the KEDA PostgreSQL scaler's `connection` parameter. This tells KEDA how to authenticate to the database for running the queue depth query.

### `06-keda-scaled-object.yaml` — ScaledObject

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
spec:
  scaleTargetRef:
    name: worker                        # Target: worker Deployment
  pollingInterval: 15                   # Query DB every 15 seconds
  cooldownPeriod: 60                    # Wait 60s before scaling down
  minReplicaCount: 0                    # Scale to zero
  maxReplicaCount: 10                   # Upper bound
  triggers:
    - type: postgresql
      metadata:
        targetQueryValue: "5"           # 1 replica per 5 messages
        activationTargetQueryValue: "1" # Scale from 0 on first message
        query: >-
          SELECT COUNT(*) FROM messenger_messages
          WHERE delivered_at IS NULL AND available_at <= NOW()
```

**How the scaling math works:**
- KEDA runs the query → gets count (e.g., 23 pending messages)
- `desiredReplicas = ceil(currentValue / targetQueryValue)` = `ceil(23 / 5)` = **5 replicas**
- `activationTargetQueryValue: "1"` means even 1 pending message scales from 0 → 1

**Under the hood**, KEDA creates an HPA (Horizontal Pod Autoscaler) that manages the worker Deployment's replica count.

### `07-keda-scaled-job.yaml` — ScaledJob

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
spec:
  jobTargetRef:
    parallelism: 1
    completions: 1
    backoffLimit: 3
    activeDeadlineSeconds: 120
    template:
      spec:
        containers:
          - command: ["php", "bin/console", "messenger:consume", "async",
                      "--limit=1", "--time-limit=60"]
        restartPolicy: Never
  scalingStrategy:
    strategy: accurate        # 1 Job per pending message
  maxReplicaCount: 10
```

**Key differences from ScaledObject:**

| Aspect | ScaledObject | ScaledJob |
|--------|-------------|-----------|
| Creates | Deployment replicas (long-running) | Kubernetes Jobs (one-shot) |
| Worker command | `--time-limit=3600` (runs for 1 hr) | `--limit=1 --time-limit=60` (1 msg, exit) |
| Scale down | Cooldown period, then reduce replicas | Pod terminates after processing |
| Idle cost | Pods may idle during cooldown | Zero — pods exit immediately |
| Cold start | Only on first scale-up from zero | Every single message |

- **`--limit=1`** — Process exactly 1 message then exit (so the K8s Job completes)
- **`restartPolicy: Never`** — Jobs shouldn't restart; KEDA creates new ones
- **`backoffLimit: 3`** — Retry failed Jobs up to 3 times
- **`activeDeadlineSeconds: 120`** — Hard kill after 2 minutes (prevents zombie Jobs)
- **`scalingStrategy: accurate`** — Creates exactly 1 Job per pending message (vs the default ratio-based strategy)

### `08-scaling-monitor.yaml` — Monitoring CronJob

Contains 5 Kubernetes resources:

1. **ServiceAccount** (`scaling-monitor`) — Identity for the CronJob pods
2. **Role** — Permissions to list pods, jobs, scaledobjects, scaledjobs
3. **RoleBinding** — Binds the Role to the ServiceAccount
4. **ConfigMap** (`scaling-monitor-script`) — Shell script that:
   - Detects which scaling mode is active
   - Queries PostgreSQL for queue depth
   - Queries Kubernetes API for pod/job counts
   - Inserts a row into `scaling_metrics` table
5. **CronJob** (`scaling-monitor`) — Runs every minute, installs psql client, executes the script

The metrics are consumed by the `/scaling-metrics` dashboard page for visual comparison of ScaledObject vs ScaledJob behavior.

---

## 3. EKS Cluster Setup Walkthrough

### Prerequisites

- AWS account with EKS access
- AWS CLI v2 installed (`aws --version`)
- `kubectl` installed
- `helm` installed

### Connecting to an Existing EKS Cluster

If you created the cluster from the AWS Console UI:

```bash
# 1. Configure AWS credentials (must be the same account that created the cluster)
aws configure
# Enter: Access Key ID, Secret Key, Region

# 2. Update kubeconfig
aws eks update-kubeconfig --region <YOUR_REGION> --name <YOUR_CLUSTER_NAME>

# 3. Verify
kubectl get nodes
```

### Required EKS Configuration

**Worker nodes**: Ensure your cluster has a managed node group with at least 2 nodes. Check the "Compute" tab in the EKS Console. Without nodes, pods will stay in `Pending` state.

**Subnet tags**: For LoadBalancer services to work, your VPC subnets must be tagged:

| Tag Key | Tag Value | Subnet Type |
|---------|-----------|-------------|
| `kubernetes.io/role/elb` | `1` | Public subnets |
| `kubernetes.io/role/internal-elb` | `1` | Private subnets |

Add these via **AWS Console > VPC > Subnets > Tags**.

**IAM access**: If `kubectl` returns "the server has asked for the client to provide credentials", your IAM user isn't in the cluster's access list:

1. AWS Console > EKS > Your Cluster > **Access** tab
2. Set authentication mode to **"EKS API and ConfigMap"**
3. Click **"Create access entry"**
4. Select your IAM user ARN (from `aws sts get-caller-identity`)
5. Attach policy: **`AmazonEKSClusterAdminPolicy`**

---

## 4. KEDA Installation

```bash
# Add Helm repo
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

# Create KEDA namespace and install
kubectl create namespace keda
helm install keda kedacore/keda --namespace keda

# Verify — all 3 pods must be Running
kubectl get pods -n keda
```

Expected pods:
- `keda-operator-*` — Main controller that manages ScaledObjects/ScaledJobs
- `keda-operator-metrics-apiserver-*` — Exposes external metrics to the HPA
- `keda-admission-webhooks-*` — Validates KEDA CRD resources

KEDA must be running **before** applying files `05-keda-trigger-auth.yaml`, `06-keda-scaled-object.yaml`, or `07-keda-scaled-job.yaml`, because those use KEDA Custom Resource Definitions.

---

## 5. Deployment Steps

```bash
cd /home/somesh/Desktop/k8s/Scale_KEDA/PHP_application_demo/EKS/

# Core infrastructure
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-secrets.yaml
kubectl apply -f 02-web-deployment.yaml
kubectl apply -f 03-web-service.yaml

# KEDA authentication (required for both ScaledObject and ScaledJob)
kubectl apply -f 05-keda-trigger-auth.yaml

# Option A: ScaledObject (long-running workers)
kubectl apply -f 04-worker-deployment.yaml
kubectl apply -f 06-keda-scaled-object.yaml

# Option B: ScaledJob (one-shot workers)
kubectl apply -f 07-keda-scaled-job.yaml

# Monitoring (optional, for scaling metrics dashboard)
kubectl apply -f 08-scaling-monitor.yaml
```

**Important**: Deploy **either** ScaledObject (Option A) **or** ScaledJob (Option B) at a time, not both. They consume from the same queue and would compete for messages.

### Verify Deployment

```bash
# Pods should show 1/1 Running for web, 0 workers (queue empty)
kubectl get pods -n php-job-demo

# Get the dashboard URL (NLB hostname)
kubectl get svc web -n php-job-demo

# Check KEDA resources
kubectl get scaledobject -n php-job-demo    # or scaledjob
kubectl get triggerauthentication -n php-job-demo

# KEDA operator logs (check for scaler errors)
kubectl logs -n keda -l app=keda-operator --tail=50
```

---

## 6. How KEDA Scaling Works

### The PostgreSQL Scaler

KEDA's PostgreSQL scaler executes a SQL query against the database at a regular interval and uses the result to make scaling decisions.

**The query:**

```sql
SELECT COUNT(*) FROM messenger_messages
WHERE delivered_at IS NULL
AND available_at <= NOW()
```

This counts "pending" messages — those that:
- **`delivered_at IS NULL`** — No worker has claimed them yet. Symfony Messenger sets `delivered_at` when a worker begins consuming a message.
- **`available_at <= NOW()`** — They are ready for consumption. Messages in retry backoff have `available_at` set to a future timestamp.

This matches exactly how Symfony's Doctrine transport internally decides which messages are available.

### Scaling Flow

```
Every 15 seconds:

  KEDA Operator
       |
       |  Runs SQL query against PostgreSQL
       |  → Result: 12 pending messages
       |
       v
  ScaledObject:                          ScaledJob:
  desiredReplicas = ceil(12/5) = 3       Creates 10 Jobs (min of count, maxReplicaCount)
  Updates HPA → scales Deployment         Each Job: --limit=1 (process 1 msg, exit)
  to 3 replicas                           scalingStrategy: accurate
       |                                        |
       v                                        v
  3 worker pods running                  10 Job pods created
  messenger:consume (long-running)       Each processes 1 message, then exits
  Each consumes multiple messages         Pods go to Completed state
```

### Scale-to-Zero

When the query returns 0:
- **ScaledObject**: After `cooldownPeriod` (60s), reduces replicas to 0
- **ScaledJob**: No new Jobs created. Existing Jobs finish and complete.

When the first message arrives (`activationTargetQueryValue: "1"`):
- KEDA detects count >= 1 and scales up from zero

---

## 7. ScaledObject vs ScaledJob Comparison

| Metric | ScaledObject | ScaledJob |
|--------|-------------|-----------|
| **What it scales** | Deployment replica count | Creates Kubernetes Jobs |
| **Worker lifecycle** | Long-running (1 hour), processes many messages | One-shot, processes 1 message then exits |
| **Scale-up latency** | Fast if already >0 replicas; cold start from zero | Always cold start (new pod per message) |
| **Scale-down** | Waits for `cooldownPeriod` (60s) | Pod exits immediately after completion |
| **Idle resource waste** | Possible — pods run during cooldown even if queue empty | None — no idle pods |
| **Best for** | Steady streams of work | Bursty workloads, batch processing |
| **Max throughput** | Higher — no pod startup overhead per message | Lower — pod creation overhead per message |
| **Resource cleanup** | Pods stay running, managed by Deployment | Completed Job pods auto-cleaned (history limit: 5) |

### When to use ScaledObject
- High-throughput, steady workloads
- When cold-start latency matters
- When workers need warm caches or persistent connections

### When to use ScaledJob
- Burst/batch processing (process 100 jobs, then go to zero)
- Cost optimization (pay only for active processing time)
- When each job is independent and self-contained
- When you want clear per-job visibility in `kubectl get jobs`

---

## 8. Scaling Monitor & Analyzer

### Terminal Watcher (`scripts/keda-watcher.sh`)

A bash script that polls the cluster every 5 seconds and displays a live terminal dashboard.

```bash
# Watch ScaledObject mode
./scripts/keda-watcher.sh --namespace php-job-demo --mode scaledobject

# Watch ScaledJob mode
./scripts/keda-watcher.sh --namespace php-job-demo --mode scaledjob
```

**What it captures:**
- Queue depth (queries DB via `kubectl exec` into the web pod)
- Active/pending/completed/failed pod counts
- KEDA desired vs actual replica count
- Recent Kubernetes events

**Output:**
- Live terminal dashboard (refreshes every 5s)
- CSV file at `scripts/scaling-log-<mode>-<timestamp>.csv` for post-analysis

### CronJob Monitor (`08-scaling-monitor.yaml`)

Records metrics into the `scaling_metrics` PostgreSQL table every minute. Data is visualized at `/scaling-metrics` on the web dashboard with Chart.js charts showing:
- Queue depth vs active pods over time (dual Y-axis line chart)
- Pod state breakdown (stacked bar chart)
- Summary stats (peak queue, peak pods, total completed)

---

## 9. Running the Comparison Test

### Test A: ScaledObject

```bash
# 1. Deploy ScaledObject setup
kubectl apply -f 04-worker-deployment.yaml
kubectl apply -f 05-keda-trigger-auth.yaml
kubectl apply -f 06-keda-scaled-object.yaml
kubectl apply -f 08-scaling-monitor.yaml

# 2. Start terminal watcher
./scripts/keda-watcher.sh --namespace php-job-demo --mode scaledobject

# 3. Open dashboard at NLB URL, submit 20 "Idle Wait" jobs (batch create)

# 4. Observe in terminal:
#    - Scale-up speed (how fast pods appear)
#    - Queue drain rate (messages processed per minute)
#    - Steady-state behavior (pods reusing for multiple messages)

# 5. Wait for queue to empty, observe scale-down:
#    - cooldownPeriod = 60s before replicas reduce
#    - Pods gradually terminate

# 6. Ctrl+C to stop watcher (CSV saved automatically)
```

### Test B: ScaledJob

```bash
# 1. Tear down ScaledObject, deploy ScaledJob
kubectl delete -f 06-keda-scaled-object.yaml
kubectl delete -f 04-worker-deployment.yaml
kubectl apply -f 07-keda-scaled-job.yaml

# 2. Start terminal watcher
./scripts/keda-watcher.sh --namespace php-job-demo --mode scaledjob

# 3. Submit same number of jobs

# 4. Observe:
#    - Job creation pattern (one Job pod per message)
#    - Pod lifecycle (ContainerCreating → Running → Completed)
#    - No idle pods after processing

# 5. Stop watcher

# 6. Compare CSV files from both runs
```

### What to Compare

- **Cold-start latency**: Time from message dispatch to pod `Running`. ScaledJob has this on every message; ScaledObject only on first scale-up.
- **Throughput**: How fast the queue drains. ScaledObject typically wins due to zero pod-startup overhead.
- **Scale-down behavior**: ScaledObject holds pods for 60s cooldown; ScaledJob pods exit instantly.
- **Resource efficiency**: ScaledJob uses zero resources when idle; ScaledObject may have idle pods during cooldown.

---

## 10. Errors Encountered & Resolutions

### Error 1: kubectl Authentication Failure

**When**: First attempt to run `kubectl get svc` after creating the EKS cluster from the AWS UI.

**Error:**
```
E0227 18:20:14.383530 memcache.go:265] "Unhandled Error" err="couldn't get current server API group list:
the server has asked for the client to provide credentials"

error: You must be logged in to the server (the server has asked for the client to provide credentials)
```

**Root Cause**: The IAM user used locally (via `aws configure`) was different from the identity that created the EKS cluster. By default, only the cluster creator has Kubernetes API access.

**Resolution**:
1. Went to **AWS Console > EKS > Cluster > Access tab**
2. Set authentication mode to **"EKS API and ConfigMap"**
3. Created an **access entry** for the local IAM user's ARN
4. Assigned the **`AmazonEKSClusterAdminPolicy`** policy
5. Ran `aws eks update-kubeconfig --region <REGION> --name <CLUSTER_NAME>`

---

### Error 2: LoadBalancer Stuck in `<pending>` — Subnet Tags Missing

**When**: After applying `03-web-service.yaml` with `type: LoadBalancer`.

**Symptom**: The service EXTERNAL-IP stayed `<pending>` for 14+ hours.

**Error** (from `kubectl describe svc web -n php-job-demo`):
```
Warning  FailedBuildModel  3m46s (x55 over 10h)  service
Failed build model due to unable to resolve at least one subnet
(0 match VPC and tags: [kubernetes.io/role/internal-elb])
```

**Root Cause**: The AWS Load Balancer Controller (which ships with EKS Auto) requires VPC subnets to be tagged for auto-discovery. Without tags, the controller cannot find subnets to place the load balancer in.

The error specifically mentions `internal-elb` because without an explicit scheme annotation, the controller defaults to internal mode.

**Resolution** (two changes):

1. **Added subnet tags** in AWS Console > VPC > Subnets:
   - Tag: `kubernetes.io/role/elb` = `1` on public subnets

2. **Added annotations** to the Service manifest to explicitly request an internet-facing NLB:
   ```yaml
   annotations:
     service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
     service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
   ```

   The `nlb` type is required because the AWS Load Balancer Controller (used by EKS Auto) only creates Network Load Balancers for `type: LoadBalancer` services — it does not support Classic Load Balancers.

---

### Error 3: Web Pod CrashLoopBackOff — OOMKilled (Exit Code 137)

**When**: After applying `02-web-deployment.yaml` with initial resource limits.

**Symptom**: Pod restarted 217 times, status `CrashLoopBackOff`.

**Error** (from `kubectl describe pod`):
```
Last State:  Terminated
  Reason:    Error
  Exit Code: 137
Restart Count: 217
Limits:
  cpu:     500m
  memory:  256Mi
```

**Root Cause**: Exit code 137 = SIGKILL = OOMKilled. The initial memory limit of 256Mi was too low for PHP 8.4 + Apache + Symfony cache warmup + OPcache. The container would start, Apache would fork child processes, Symfony would compile its DI container and routing cache, and the combined memory usage exceeded 256Mi, causing the Linux OOM killer to terminate the process.

**Resolution**: Increased resource limits in `02-web-deployment.yaml`:

| Resource | Before | After |
|----------|--------|-------|
| CPU request | 100m | 250m |
| CPU limit | 500m | 1000m |
| Memory request | 128Mi | 256Mi |
| Memory limit | 256Mi | **512Mi** |

Also increased health probe timings:

| Probe | Before | After | Reason |
|-------|--------|-------|--------|
| Readiness initialDelay | 10s | 30s | Symfony needs time to warm cache |
| Liveness initialDelay | 15s | 45s | Prevent killing during startup |
| Timeout | 1s | 5s | Dashboard queries DB, first request can be slow |

---

### Error 4: NLB Accessible But `ERR_CONNECTION_TIMED_OUT` — Database Unreachable

**When**: After the NLB was provisioned and had a hostname, but the dashboard wouldn't load.

**Symptom**: Browser showed `ERR_CONNECTION_TIMED_OUT`. NLB had a hostname but no traffic reached the app.

**Error** (from `kubectl logs -n php-job-demo -l component=web --previous --tail=50`):
```
[critical] Uncaught PHP Exception Doctrine\DBAL\Exception\ConnectionException:
"An exception occurred in the driver: SQLSTATE[08006] [7] connection to server at
"a434815-akamai-prod-3365827-default.g2a.akamaidb.net" (172.237.36.106), port 28213
failed: timeout expired

connection to server at "a434815-akamai-prod-3365827-default.g2a.akamaidb.net"
(2600:3c16::2000:f7ff:fe1c:c72f), port 28213 failed: Network is unreachable"
```

The readiness probe was hitting `/` which triggers a database query. Since the DB was unreachable, every request returned HTTP 500, the readiness probe failed, and Kubernetes removed the pod from the service endpoints — so the NLB had no healthy targets to forward to.

**Root Cause**: The external Akamai-hosted PostgreSQL database had IP whitelisting enabled. The EKS worker nodes' public IPs were not in the allowlist.

Two sub-issues:
- **IPv6**: `Network is unreachable` — The EKS VPC didn't have IPv6 egress configured, so the IPv6 connection attempt failed immediately
- **IPv4**: `timeout expired` — The connection from EKS node IPs (54.172.200.48, 18.234.187.40) was blocked by Akamai's firewall

**Resolution**:
1. Found the EKS node public IPs via `kubectl get nodes -o wide`
2. Added both IPs to the Akamai database's **IP allowlist** (trusted sources)
3. Verified connectivity from inside the cluster:
   ```bash
   kubectl run pg-test --rm -it --image=postgres:16-alpine -n php-job-demo -- \
     pg_isready -h a434815-akamai-prod-3365827-default.g2a.akamaidb.net -p 28213
   # Output: accepting connections
   ```
4. Restarted the web deployment to pick up the now-working connectivity:
   ```bash
   kubectl rollout restart deployment web -n php-job-demo
   ```

---

### Error 5: NLB Provisioned But `ERR_CONNECTION_TIMED_OUT` — AZ Mismatch

**When**: NLB had an external hostname, app was responding inside the pod (`curl localhost` returned 200), health probes passing, but browser showed `ERR_CONNECTION_TIMED_OUT`.

**Symptom**: Everything looked healthy — pod 1/1 Running, 0 restarts, readiness/liveness probes passing, NLB hostname assigned, endpoint registered. But the app was unreachable from the internet.

**Error** (from `aws elbv2 describe-target-health`):
```json
{
    "TargetHealth": {
        "State": "unused",
        "Reason": "Target.NotInUse",
        "Description": "Target is in an Availability Zone that is not enabled for the load balancer"
    }
}
```

The pod's IP (`172.31.90.102`) was registered as a target, but the NLB wasn't sending any traffic to it because the target was in an AZ the NLB didn't cover.

**Root Cause**: The pod was scheduled onto a node in **us-east-1d**, but the NLB was created with subnets only from other AZs (e.g., us-east-1a, us-east-1b). NLBs only route traffic to targets in AZs where they have a subnet enabled. Since the only target was in us-east-1d (an AZ not enabled on the NLB), the target was marked `unused` and received zero traffic.

This happens when:
- The EKS node group spans more AZs than the subnets tagged for LB auto-discovery
- The Kubernetes scheduler places the pod on a node in an AZ without a tagged public subnet

**Diagnosis steps:**
```bash
# 1. Verify app works inside the pod
kubectl exec -n php-job-demo <POD_NAME> -- curl -s -o /dev/null -w "%{http_code}" http://localhost:80/
# → 200 (app is fine)

# 2. Check NLB target health
aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName, 'phpjobde')].TargetGroupArn" --output text
aws elbv2 describe-target-health --target-group-arn <ARN>
# → "State": "unused", "Target is in an Availability Zone that is not enabled for the load balancer"

# 3. Check which AZs the NLB covers
aws elbv2 describe-load-balancers --names <NLB_NAME> --query "LoadBalancers[0].AvailabilityZones" --output table

# 4. Check which AZ the pod is in
kubectl get pod <POD_NAME> -n php-job-demo -o wide
# → Shows the node; cross-reference with `kubectl get nodes -o wide` for AZ
```

**Resolution**: Enable the missing AZ's subnet on the NLB:

```bash
# 1. Find the subnet in the missing AZ
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<VPC_ID>" "Name=availability-zone,Values=us-east-1d" \
  --query "Subnets[*].{SubnetId:SubnetId,AZ:AvailabilityZone,Public:MapPublicIpOnLaunch}" \
  --output table

# 2. Get currently enabled subnets on the NLB
aws elbv2 describe-load-balancers --names <NLB_NAME> \
  --query "LoadBalancers[0].AvailabilityZones[*].SubnetId" --output text

# 3. Set subnets (must include ALL existing + the new one)
aws elbv2 set-subnets \
  --load-balancer-arn <NLB_ARN> \
  --subnets <EXISTING_SUBNET_1> <EXISTING_SUBNET_2> <NEW_US_EAST_1D_SUBNET>
```

**Alternative fix**: Tag the public subnet in us-east-1d with `kubernetes.io/role/elb=1`, then delete and re-create the Service so the NLB is recreated with all tagged subnets:
```bash
kubectl delete -f 03-web-service.yaml
kubectl apply -f 03-web-service.yaml
```

---

### Error Summary Table

| # | Error | Exit Code / Status | Root Cause | Fix |
|---|-------|--------------------|------------|-----|
| 1 | `client to provide credentials` | kubectl auth error | IAM user not in EKS access entries | Add IAM user via EKS Console Access tab |
| 2 | `FailedBuildModel: 0 match VPC and tags` | Service `<pending>` | Subnets missing `kubernetes.io/role/elb` tag | Tag public subnets + add NLB annotations |
| 3 | `CrashLoopBackOff`, Exit 137 | OOMKilled | 256Mi too low for PHP+Apache+Symfony | Increase to 512Mi, adjust probe timings |
| 4 | `SQLSTATE[08006] connection timeout` | HTTP 500 on all requests | External DB IP whitelist blocked EKS nodes | Add node public IPs to DB allowlist |
| 5 | `Target.NotInUse: AZ not enabled` | NLB target `unused` | Pod in AZ not covered by NLB subnets | Add missing AZ subnet to NLB |

---

## Useful Commands

```bash
# Check all resources in the namespace
kubectl get all -n php-job-demo

# Watch pods in real-time (useful during scaling)
kubectl get pods -n php-job-demo -w

# View web pod logs
kubectl logs -n php-job-demo -l component=web --tail=100

# View worker pod logs
kubectl logs -n php-job-demo -l component=worker --tail=100

# Check KEDA scaling status
kubectl get scaledobject -n php-job-demo -o yaml
kubectl get scaledjob -n php-job-demo -o yaml

# Check HPA created by KEDA (ScaledObject mode)
kubectl get hpa -n php-job-demo

# View completed ScaledJob K8s Jobs
kubectl get jobs -n php-job-demo

# KEDA operator logs (debugging scaler issues)
kubectl logs -n keda -l app=keda-operator --tail=100

# Test DB connectivity from inside the cluster
kubectl run pg-test --rm -it --image=postgres:16-alpine -n php-job-demo -- \
  pg_isready -h <DB_HOST> -p <DB_PORT>

# Force restart a deployment
kubectl rollout restart deployment web -n php-job-demo
kubectl rollout restart deployment worker -n php-job-demo

# Switch from ScaledObject to ScaledJob
kubectl delete -f 06-keda-scaled-object.yaml
kubectl delete -f 04-worker-deployment.yaml
kubectl apply -f 07-keda-scaled-job.yaml

# Switch from ScaledJob to ScaledObject
kubectl delete -f 07-keda-scaled-job.yaml
kubectl apply -f 04-worker-deployment.yaml
kubectl apply -f 06-keda-scaled-object.yaml

# Clean up everything
kubectl delete namespace php-job-demo
```
