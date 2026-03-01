# Symfony Messenger Job Queue - KEDA Scaling Demo

A PHP 8.4 / Symfony 8.0 application designed to demonstrate **KEDA (Kubernetes Event-Driven Autoscaling)** with ScaledJobs and ScaledObjects on AWS EKS. The app provides a web dashboard to dispatch async jobs of varying workload types, which are queued in PostgreSQL and consumed by worker pods that KEDA scales automatically based on queue depth.

---

## Architecture Overview

```
                        +-----------------------+
                        |    Web Dashboard      |
                        |   (Apache + PHP)      |
                        |   Port 80             |
                        +-----------+-----------+
                                    |
                          POST /job/create
                                    |
                                    v
                    +-------------------------------+
                    |       PostgreSQL Database      |
                    |                               |
                    |  +-------------------------+  |
                    |  |     jobs (table)         |  |
                    |  |  id, uuid, type, status  |  |
                    |  |  progress, log, result   |  |
                    |  +-------------------------+  |
                    |                               |
                    |  +-------------------------+  |
                    |  |  messenger_messages      |  |
                    |  |  (Symfony queue table)   |  |
                    |  |  body, headers,          |  |
                    |  |  delivered_at,           |  |
                    |  |  available_at            |  |
                    |  +-------------------------+  |
                    +-------------------------------+
                                    ^
                                    |
                    KEDA polls: SELECT COUNT(*)
                    FROM messenger_messages
                    WHERE delivered_at IS NULL
                    AND available_at <= NOW()
                                    |
                                    v
                    +-------------------------------+
                    |        KEDA Operator          |
                    |  Scales workers 0-10 based    |
                    |  on pending message count     |
                    +-------------------------------+
                                    |
                        +-----------+-----------+
                        |                       |
                        v                       v
              +------------------+    +------------------+
              |  ScaledObject    |    |  ScaledJob       |
              |  (Deployment)    |    |  (K8s Jobs)      |
              |  Long-running    |    |  One-shot per    |
              |  consumers       |    |  message          |
              +------------------+    +------------------+
                        |                       |
                        v                       v
              +-------------------------------------------+
              |           Worker Pods                      |
              |  php bin/console messenger:consume async   |
              |                                           |
              |  Handlers:                                |
              |  - CpuStressHandler (primes / pi calc)    |
              |  - DataTransferHandler (S3 upload)        |
              |  - RemoteCommandHandler (SSH exec)        |
              |  - IdleWaitHandler (sleep/keep-alive)     |
              +-------------------------------------------+
```

---

## Application Components

### Web Dashboard (`src/Controller/DashboardController.php`)

The dashboard serves as the control plane for job management:

| Route | Method | Purpose |
|-------|--------|---------|
| `/` | GET | Dashboard — job list + creation form |
| `/job/create` | POST | Dispatch 1–100 jobs of a selected type |
| `/job/{id}` | GET | View individual job details, logs, result |
| `/job/{id}/cancel` | POST | Cancel a pending job (removes from queue) |
| `/job/{id}/delete` | POST | Delete a job record |
| `/api/job/{id}/status` | GET | JSON API for real-time status polling |

The dashboard auto-refreshes every 5 seconds when jobs are processing, showing live progress bars and log output.

### Scaling Metrics Page (`src/Controller/ScalingMetricsController.php`)

| Route | Method | Purpose |
|-------|--------|---------|
| `/scaling-metrics` | GET | Chart.js dashboard comparing ScaledObject vs ScaledJob |
| `/api/scaling-metrics` | GET | JSON API returning historical queue depth + pod counts |

Displays queue depth vs active pods over time, filterable by scaling mode. Data is recorded by a Kubernetes CronJob every minute.

---

## Job Types

### 1. CPU Stress (`cpu_stress`)

**Handler:** `CpuStressHandler.php`

Generates CPU-intensive workloads using two algorithms:

- **Primes** — Iteratively tests prime numbers, counting how many are found within the duration
- **Pi (Leibniz)** — Approximates Pi using the Leibniz series formula

| Parameter | Default | Description |
|-----------|---------|-------------|
| `duration` | 30s | How long the stress test runs |
| `algorithm` | `primes` | `primes` or `pi` |

Reports progress every 10% with metrics (primes found / pi approximation value).

### 2. S3 Backup / Data Transfer (`s3_backup`)

**Handler:** `DataTransferHandler.php`

Simulates a backup workflow with I/O-intensive operations:

1. Generates 5 dummy data files (1000 lines each)
2. Creates a ZIP archive from the generated files
3. Uploads the ZIP to an AWS S3 bucket via Flysystem
4. Cleans up local temporary files

| Parameter | Default | Description |
|-----------|---------|-------------|
| `bucket` | `s3-stress-demo` | S3 bucket name |
| `s3_key` | `backups/demo.zip` | S3 object key |

Requires AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).

### 3. Remote SSH Command (`ssh_command`)

**Handler:** `RemoteCommandHandler.php`

Executes commands on a remote server via SSH using phpseclib3:

1. Establishes SSH connection with password authentication
2. Executes the specified command
3. Captures stdout/stderr and exit code
4. Reports success or failure based on exit code

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ssh_command` | `uptime` | Command to execute |
| `ssh_port` | `22` | SSH port |

Host, user, and password are injected from environment variables.

### 4. Idle Wait (`idle_wait`)

**Handler:** `IdleWaitHandler.php`

A minimal-resource job that sleeps for a specified duration. Useful for:
- Testing KEDA scaling behavior without consuming CPU
- Keeping worker pods alive to observe scale-down timing
- Simulating long-running but idle workloads

| Parameter | Default | Description |
|-----------|---------|-------------|
| `idle_duration` | 300s | Total sleep duration |
| `idle_interval` | 10s | Progress update frequency |

---

## Queue System: Symfony Messenger

The application uses **Symfony Messenger** with the **Doctrine transport** for async job processing. This means the message queue lives inside the same PostgreSQL database as the application data.

### How It Works

```
DashboardController                   messenger_messages table
       |                                        |
       |  $bus->dispatch(CpuStressMessage)      |
       +--------------------------------------->|
                                                |
                                                |  KEDA watches this table
                                                |  via SQL query
                                                |
       Worker Pod                               |
       |  messenger:consume async               |
       |<---------------------------------------+
       |                                        |
       |  CpuStressHandler->__invoke()          |
       |  (processes the message)               |
       |                                        |
       |  delivered_at = NOW()  ----------------+  (claimed by worker)
       |  DELETE after success  ----------------+  (removed from queue)
```

### Configuration (`config/packages/messenger.yaml`)

```yaml
framework:
    messenger:
        transports:
            async:
                dsn: '%env(MESSENGER_TRANSPORT_DSN)%'   # doctrine://default
                options:
                    table_name: messenger_messages
                    queue_name: default
                    auto_setup: true
                retry_strategy:
                    max_retries: 3
                    delay: 1000          # 1 second initial
                    multiplier: 2        # exponential backoff
                    max_delay: 60000     # cap at 60 seconds
```

### Message Routing

All four message types are routed to the `async` transport:

```yaml
routing:
    'App\Message\CpuStressMessage': async
    'App\Message\DataTransferMessage': async
    'App\Message\RemoteCommandMessage': async
    'App\Message\IdleWaitMessage': async
```

### Concurrency Safety

When KEDA scales up multiple workers, they all consume from the same `messenger_messages` table. Symfony's Doctrine transport uses `SELECT ... FOR UPDATE SKIP LOCKED` to prevent duplicate processing — each message is claimed by exactly one worker.

### The KEDA Query

KEDA monitors the queue using this PostgreSQL query:

```sql
SELECT COUNT(*) FROM messenger_messages
WHERE delivered_at IS NULL
AND available_at <= NOW()
```

- `delivered_at IS NULL` — message hasn't been picked up by any worker
- `available_at <= NOW()` — message is ready (not in retry backoff delay)

---

## Database: PostgreSQL

The application uses a single PostgreSQL database with three tables:

### `jobs` — Job Metadata

Stores the state and results of every dispatched job.

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Auto-increment primary key |
| `uuid` | VARCHAR(36) | Unique job identifier (UUID v4) |
| `type` | VARCHAR | Enum: `cpu_stress`, `s3_backup`, `ssh_command`, `idle_wait` |
| `status` | VARCHAR | Enum: `pending`, `processing`, `completed`, `failed`, `cancelled` |
| `parameters` | JSON | Job-specific configuration |
| `log` | TEXT | Timestamped execution log |
| `progress` | INTEGER | 0–100 percentage |
| `created_at` | TIMESTAMP | When the job was dispatched |
| `started_at` | TIMESTAMP | When a worker picked it up |
| `completed_at` | TIMESTAMP | When it finished (success or failure) |
| `result` | TEXT | Final output or error message |

### `messenger_messages` — Symfony Queue

Auto-created by Symfony Messenger's Doctrine transport. This is the table KEDA monitors.

| Column | Type | Description |
|--------|------|-------------|
| `id` | BIGSERIAL | Message ID |
| `body` | TEXT | Serialized PHP message object |
| `headers` | TEXT | Serialized message metadata (class, stamps) |
| `queue_name` | VARCHAR | Always `default` in this app |
| `created_at` | TIMESTAMP | When the message was dispatched |
| `available_at` | TIMESTAMP | When the message becomes consumable |
| `delivered_at` | TIMESTAMP | Set when a worker claims the message; NULL = pending |

### `scaling_metrics` — Monitoring Data

Populated by the Kubernetes CronJob (`08-scaling-monitor.yaml`) every minute.

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL | Auto-increment |
| `recorded_at` | TIMESTAMP | When the metric was recorded |
| `queue_depth` | INTEGER | Pending messages in queue |
| `active_pods` | INTEGER | Running worker pods |
| `pending_pods` | INTEGER | Pods in Pending/ContainerCreating state |
| `completed_jobs` | INTEGER | Succeeded K8s Jobs (ScaledJob mode) |
| `failed_jobs` | INTEGER | Failed K8s Jobs |
| `scaling_mode` | VARCHAR(20) | `scaledobject` or `scaledjob` |
| `notes` | TEXT | Optional annotations |

---

## Job Lifecycle

```
                    User submits form
                           |
                           v
                  +------------------+
                  |     PENDING      |  Job created, message in queue
                  +--------+---------+
                           |
                    Worker picks up
                           |
                           v
                  +------------------+
                  |   PROCESSING     |  Handler executing, progress 0-100%
                  +--------+---------+
                          / \
                         /   \
                        v     v
              +-----------+ +-----------+
              | COMPLETED | |  FAILED   |  Handler finished or threw exception
              +-----------+ +-----------+

              +-------------+
              |  CANCELLED  |  User cancelled while PENDING
              +-------------+
```

The `JobTracker` service (`src/Service/JobTracker.php`) manages all state transitions. Handlers call `markProcessing()`, `updateProgress()`, and `markCompleted()` or `markFailed()` during execution.

---

## Project Structure

```
PHP_application_demo/
├── src/
│   ├── Controller/
│   │   ├── DashboardController.php        # Web UI + job management
│   │   └── ScalingMetricsController.php   # Scaling comparison dashboard
│   ├── Entity/
│   │   ├── Job.php                        # Job Doctrine entity
│   │   └── ScalingMetric.php              # Monitoring metrics entity
│   ├── Enum/
│   │   ├── JobType.php                    # cpu_stress, s3_backup, ssh_command, idle_wait
│   │   └── JobStatus.php                  # pending, processing, completed, failed, cancelled
│   ├── Message/
│   │   ├── CpuStressMessage.php           # CPU stress job message
│   │   ├── DataTransferMessage.php        # S3 upload job message
│   │   ├── RemoteCommandMessage.php       # SSH command job message
│   │   └── IdleWaitMessage.php            # Idle wait job message
│   ├── MessageHandler/
│   │   ├── CpuStressHandler.php           # Prime/Pi computation
│   │   ├── DataTransferHandler.php        # S3 file generation + upload
│   │   ├── RemoteCommandHandler.php       # SSH remote execution
│   │   └── IdleWaitHandler.php            # Sleep with progress updates
│   ├── Repository/
│   │   ├── JobRepository.php              # Job queries
│   │   └── ScalingMetricRepository.php    # Metrics queries
│   └── Service/
│       └── JobTracker.php                 # Job state management
├── config/
│   ├── packages/
│   │   ├── messenger.yaml                 # Queue transport + retry config
│   │   └── doctrine.yaml                  # ORM + database config
│   └── services.yaml                      # DI container + parameters
├── templates/
│   ├── base.html.twig                     # Layout (Tailwind CSS)
│   ├── dashboard/
│   │   ├── index.html.twig                # Job list + creation form
│   │   └── show.html.twig                 # Job detail view
│   └── scaling_metrics/
│       └── index.html.twig                # Chart.js scaling dashboard
├── docker/
│   └── apache.conf                        # Apache VirtualHost config
├── Dockerfile                             # PHP 8.4 + Apache image
├── compose.yaml                           # Docker Compose (app + worker + DB)
├── EKS/                                   # Kubernetes manifests (see EKS/README.md)
└── .env                                   # Environment variables
```

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `APP_ENV` | Yes | Symfony environment (`dev` or `prod`) |
| `APP_SECRET` | Yes | Symfony framework secret key |
| `DATABASE_URL` | Yes | PostgreSQL DSN (`postgresql://user:pass@host:port/db`) |
| `MESSENGER_TRANSPORT_DSN` | Yes | Always `doctrine://default` |
| `AWS_ACCESS_KEY_ID` | For S3 jobs | AWS IAM access key |
| `AWS_SECRET_ACCESS_KEY` | For S3 jobs | AWS IAM secret key |
| `AWS_REGION` | For S3 jobs | AWS region (default: `us-east-1`) |
| `S3_BUCKET` | For S3 jobs | S3 bucket name |
| `S3_ENDPOINT` | Optional | Custom S3 endpoint (for MinIO, etc.) |
| `SSH_DEFAULT_HOST` | For SSH jobs | SSH target hostname/IP |
| `SSH_DEFAULT_USER` | For SSH jobs | SSH username |
| `SSH_DEFAULT_PASS` | For SSH jobs | SSH password |

---

## Running Locally (Docker Compose)

```bash
# Build and start all services
docker compose up --build -d

# Run database migrations
docker compose exec app php bin/console doctrine:migrations:migrate --no-interaction

# Access the dashboard
open http://localhost:8080
```

This starts three containers:
- **app** — Web dashboard on port 8080
- **worker** — Background consumer (auto-restarts every hour)
- **database** — PostgreSQL 16

---

## Running on Kubernetes (EKS)

See [EKS/README.md](EKS/README.md) for the complete EKS deployment guide, including KEDA installation, manifest descriptions, error troubleshooting, and the scaling comparison test procedure.

---

## Tech Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| PHP | 8.4 | Runtime |
| Symfony | 8.0 | Framework |
| Doctrine ORM | 3.6 | Database ORM |
| Symfony Messenger | 8.0 | Async job queue |
| PostgreSQL | 16 | Database + queue storage |
| Apache | 2.4 | Web server |
| AWS SDK | 3.x | S3 integration |
| phpseclib | 3.0 | SSH client |
| League Flysystem | 3.x | Filesystem abstraction (S3 adapter) |
| Tailwind CSS | CDN | Frontend styling |
| Chart.js | 4.x | Scaling metrics charts |
| KEDA | 2.x | Kubernetes event-driven autoscaling |
