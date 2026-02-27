#!/usr/bin/env bash
#
# KEDA Scaling Watcher — Real-time terminal monitor + CSV logger
#
# Usage:
#   ./keda-watcher.sh --namespace php-job-demo --mode scaledobject
#   ./keda-watcher.sh --namespace php-job-demo --mode scaledjob
#
# Outputs:
#   - Live terminal dashboard refreshing every 5 seconds
#   - CSV file: scaling-log-<mode>-<timestamp>.csv

set -euo pipefail

# Defaults
NAMESPACE="php-job-demo"
MODE="scaledobject"
INTERVAL=5

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace|-n) NAMESPACE="$2"; shift 2 ;;
    --mode|-m) MODE="$2"; shift 2 ;;
    --interval|-i) INTERVAL="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--namespace <ns>] [--mode scaledobject|scaledjob] [--interval <seconds>]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="${SCRIPT_DIR}/scaling-log-${MODE}-${TIMESTAMP}.csv"
LABEL_SELECTOR="component=worker"

if [ "$MODE" = "scaledjob" ]; then
  LABEL_SELECTOR="component=worker-job"
fi

# Write CSV header
echo "timestamp,elapsed_sec,queue_depth,active_pods,pending_pods,running_pods,succeeded_pods,failed_pods,keda_desired,keda_active" > "$CSV_FILE"

echo "============================================="
echo "  KEDA Scaling Watcher"
echo "  Namespace: $NAMESPACE"
echo "  Mode: $MODE"
echo "  Interval: ${INTERVAL}s"
echo "  CSV: $CSV_FILE"
echo "  Press Ctrl+C to stop"
echo "============================================="
echo ""

START_TIME=$(date +%s)
ITERATION=0

# Trap Ctrl+C for clean exit
trap 'echo ""; echo "Stopped. CSV saved to: $CSV_FILE"; echo "Total data points: $ITERATION"; exit 0' INT

get_queue_depth() {
  # Get queue depth by exec'ing into the web pod and running a psql-like query
  local web_pod
  web_pod=$(kubectl get pods -n "$NAMESPACE" -l component=web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$web_pod" ]; then
    kubectl exec -n "$NAMESPACE" "$web_pod" -- php -r "
      \$dsn = getenv('DATABASE_URL');
      if (!\$dsn) { echo '0'; exit; }
      try {
        \$parsed = parse_url(\$dsn);
        \$host = \$parsed['host'] ?? 'localhost';
        \$port = \$parsed['port'] ?? 5432;
        \$user = \$parsed['user'] ?? 'app';
        \$pass = \$parsed['pass'] ?? '';
        \$db = ltrim(\$parsed['path'] ?? '/app', '/');
        \$db = explode('?', \$db)[0];
        \$pdo = new PDO(\"pgsql:host=\$host;port=\$port;dbname=\$db\", \$user, \$pass);
        \$stmt = \$pdo->query('SELECT COUNT(*) FROM messenger_messages WHERE delivered_at IS NULL AND available_at <= NOW()');
        echo \$stmt->fetchColumn();
      } catch (Exception \$e) { echo '0'; }
    " 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

get_pod_counts() {
  local all_pods
  all_pods=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --no-headers 2>/dev/null || echo "")

  PENDING_COUNT=0
  RUNNING_COUNT=0
  SUCCEEDED_COUNT=0
  FAILED_COUNT=0
  TOTAL_ACTIVE=0

  if [ -n "$all_pods" ]; then
    PENDING_COUNT=$(echo "$all_pods" | grep -c "Pending\|ContainerCreating\|Init:" || echo "0")
    RUNNING_COUNT=$(echo "$all_pods" | grep -c "Running" || echo "0")
    SUCCEEDED_COUNT=$(echo "$all_pods" | grep -c "Completed" || echo "0")
    FAILED_COUNT=$(echo "$all_pods" | grep -c "Error\|CrashLoopBackOff\|OOMKilled" || echo "0")
    TOTAL_ACTIVE=$((PENDING_COUNT + RUNNING_COUNT))
  fi
}

get_keda_status() {
  KEDA_DESIRED="N/A"
  KEDA_ACTIVE="N/A"

  if [ "$MODE" = "scaledobject" ]; then
    # ScaledObject creates an HPA — read desired replicas from it
    local hpa_info
    hpa_info=$(kubectl get hpa -n "$NAMESPACE" --no-headers 2>/dev/null | head -1 || echo "")
    if [ -n "$hpa_info" ]; then
      KEDA_DESIRED=$(echo "$hpa_info" | awk '{print $6}' || echo "N/A")
      KEDA_ACTIVE=$(echo "$hpa_info" | awk '{print $7}' || echo "N/A")
    fi
  else
    # ScaledJob — check active job count
    local sj_info
    sj_info=$(kubectl get scaledjob worker-scaled-job -n "$NAMESPACE" -o jsonpath='{.status.lastActiveTime} {.metadata.annotations}' 2>/dev/null || echo "")
    KEDA_ACTIVE=$((RUNNING_COUNT + PENDING_COUNT))
    KEDA_DESIRED="$KEDA_ACTIVE"
  fi
}

while true; do
  NOW=$(date +"%Y-%m-%d %H:%M:%S")
  ELAPSED=$(( $(date +%s) - START_TIME ))

  QUEUE_DEPTH=$(get_queue_depth)
  get_pod_counts
  get_keda_status

  # Write to CSV
  echo "${NOW},${ELAPSED},${QUEUE_DEPTH},${TOTAL_ACTIVE},${PENDING_COUNT},${RUNNING_COUNT},${SUCCEEDED_COUNT},${FAILED_COUNT},${KEDA_DESIRED},${KEDA_ACTIVE}" >> "$CSV_FILE"

  # Clear screen and display dashboard
  clear
  echo "================================================================"
  echo "  KEDA Scaling Watcher | Mode: ${MODE} | ${NOW}"
  echo "================================================================"
  echo ""
  printf "  %-25s %s\n" "Queue Depth:" "$QUEUE_DEPTH pending messages"
  printf "  %-25s %s\n" "Active Pods:" "$TOTAL_ACTIVE (${RUNNING_COUNT} running, ${PENDING_COUNT} pending)"
  printf "  %-25s %s\n" "Succeeded:" "$SUCCEEDED_COUNT"
  printf "  %-25s %s\n" "Failed:" "$FAILED_COUNT"
  printf "  %-25s %s\n" "KEDA Desired/Active:" "${KEDA_DESIRED} / ${KEDA_ACTIVE}"
  printf "  %-25s %s\n" "Elapsed:" "${ELAPSED}s"
  printf "  %-25s %s\n" "Data Points:" "$((ITERATION + 1))"
  echo ""
  echo "----------------------------------------------------------------"
  echo "  Recent Pod Activity:"
  echo "----------------------------------------------------------------"
  kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -8 || echo "  No worker pods"
  echo ""
  echo "----------------------------------------------------------------"
  echo "  Recent Events:"
  echo "----------------------------------------------------------------"
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp --field-selector reason!=Pulling 2>/dev/null | tail -5 || echo "  No events"
  echo ""
  echo "================================================================"
  echo "  CSV: $CSV_FILE | Ctrl+C to stop"
  echo "================================================================"

  ITERATION=$((ITERATION + 1))
  sleep "$INTERVAL"
done
