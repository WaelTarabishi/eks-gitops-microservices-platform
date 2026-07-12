#!/usr/bin/env bash
# =============================================================================
# AIOps Assistant - Lambda Deployment Script
#
# What this script does:
#   - Packages all 3 Lambda functions
#   - Creates them if missing
#   - Updates code and configuration if they already exist
#
# Usage:
#   chmod +x create-lambdas.sh
#   ./create-lambdas.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-aiops-lambda-role}"
LAMBDA_RUNTIME="${LAMBDA_RUNTIME:-python3.12}"
LAMBDA_TIMEOUT="${LAMBDA_TIMEOUT:-30}"
LAMBDA_MEMORY_SIZE="${LAMBDA_MEMORY_SIZE:-256}"
DEFAULT_CLUSTER="${DEFAULT_CLUSTER:-eks-cluster}"
DEFAULT_NAMESPACE="${DEFAULT_NAMESPACE:-boutique}"
LOG_GROUP_NAME="${LOG_GROUP_NAME:-/eks/boutique/pods}"
PROMETHEUS_URL="${PROMETHEUS_URL:-}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[error] Required command not found: $1"
    exit 1
  fi
}

normalize_prometheus_url() {
  local url="$1"
  url="${url%/}"
  if [[ "$url" != http://* && "$url" != https://* ]]; then
    url="http://$url"
  fi
  printf '%s' "$url"
}

discover_prometheus_url() {
  if ! command -v kubectl >/dev/null 2>&1; then
    return 1
  fi

  local hostname
  hostname="$(kubectl get svc kube-prometheus-stack-prometheus -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  local ip
  ip="$(kubectl get svc kube-prometheus-stack-prometheus -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

  if [ -n "$hostname" ]; then
    printf 'http://%s:9090' "$hostname"
    return 0
  fi

  if [ -n "$ip" ]; then
    printf 'http://%s:9090' "$ip"
    return 0
  fi

  return 1
}

package_lambda() {
  local source_dir="$1"
  local output_zip="$2"

  python3 - "$source_dir" "$output_zip" <<'PYEOF'
import os
import sys
import zipfile

source_dir = sys.argv[1]
output_zip = sys.argv[2]

with zipfile.ZipFile(output_zip, "w", zipfile.ZIP_DEFLATED) as archive:
    for root, _, files in os.walk(source_dir):
        for name in files:
            path = os.path.join(root, name)
            arcname = os.path.relpath(path, source_dir)
            archive.write(path, arcname)
PYEOF
}

wait_for_lambda_state() {
  local waiter_name="$1"
  local function_name="$2"
  aws lambda wait "$waiter_name" \
    --function-name "$function_name" \
    --region "$AWS_REGION"
}

deploy_lambda() {
  local function_name="$1"
  local source_subdir="$2"
  local environment_json="$3"
  local zip_path="$TMP_DIR/${function_name}.zip"

  package_lambda "$SCRIPT_DIR/lambda/$source_subdir" "$zip_path"

  if aws lambda get-function --function-name "$function_name" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "  [update] $function_name"
    aws lambda update-function-code \
      --function-name "$function_name" \
      --zip-file "fileb://$zip_path" \
      --region "$AWS_REGION" \
      --query 'FunctionName' --output text >/dev/null
    wait_for_lambda_state "function-updated" "$function_name"
    aws lambda update-function-configuration \
      --function-name "$function_name" \
      --role "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}" \
      --handler "lambda_function.lambda_handler" \
      --runtime "$LAMBDA_RUNTIME" \
      --timeout "$LAMBDA_TIMEOUT" \
      --memory-size "$LAMBDA_MEMORY_SIZE" \
      --environment "$environment_json" \
      --region "$AWS_REGION" \
      --query 'FunctionName' --output text >/dev/null
    wait_for_lambda_state "function-updated" "$function_name"
  else
    echo "  [create] $function_name"
    aws lambda create-function \
      --function-name "$function_name" \
      --runtime "$LAMBDA_RUNTIME" \
      --role "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}" \
      --handler "lambda_function.lambda_handler" \
      --timeout "$LAMBDA_TIMEOUT" \
      --memory-size "$LAMBDA_MEMORY_SIZE" \
      --zip-file "fileb://$zip_path" \
      --environment "$environment_json" \
      --region "$AWS_REGION" \
      --query 'FunctionName' --output text >/dev/null
    wait_for_lambda_state "function-active" "$function_name"
  fi

  echo "  [ok] $function_name"
}

require_command aws
require_command python3

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

if [ -z "$PROMETHEUS_URL" ]; then
  if PROMETHEUS_URL="$(discover_prometheus_url)"; then
    :
  else
    echo "[error] PROMETHEUS_URL is not set and could not be discovered from kubectl."
    echo "        Set PROMETHEUS_URL in .env or export it before running this script."
    exit 1
  fi
fi

if [[ "$PROMETHEUS_URL" == *"your-prometheus-elb-or-ip"* ]]; then
  echo "[error] PROMETHEUS_URL still has the placeholder value from .env.example."
  echo "        Replace it in .env or remove it so the script can auto-discover the service URL."
  exit 1
fi

PROMETHEUS_URL="$(normalize_prometheus_url "$PROMETHEUS_URL")"

echo ""
echo "============================================="
echo " AIOps - Lambda Deployment"
echo " Account         : $ACCOUNT_ID"
echo " Region          : $AWS_REGION"
echo " Lambda role     : $LAMBDA_ROLE_NAME"
echo " Prometheus URL  : $PROMETHEUS_URL"
echo " Default cluster : $DEFAULT_CLUSTER"
echo " Default ns      : $DEFAULT_NAMESPACE"
echo " Log group       : $LOG_GROUP_NAME"
echo "============================================="
echo ""

LOGS_ENV="Variables={LOG_GROUP_NAME=${LOG_GROUP_NAME}}"
METRICS_ENV="Variables={PROMETHEUS_URL=${PROMETHEUS_URL},DEFAULT_NAMESPACE=${DEFAULT_NAMESPACE}}"
HEALTH_ENV="Variables={PROMETHEUS_URL=${PROMETHEUS_URL},DEFAULT_CLUSTER=${DEFAULT_CLUSTER},DEFAULT_NAMESPACE=${DEFAULT_NAMESPACE}}"

echo "[1/1] Deploying Lambda functions..."
deploy_lambda "aiops-fetch-logs" "fetch_logs" "$LOGS_ENV"
deploy_lambda "aiops-fetch-metrics" "fetch_metrics" "$METRICS_ENV"
deploy_lambda "aiops-fetch-health" "fetch_health" "$HEALTH_ENV"

echo ""
echo "============================================="
echo " Done!"
echo "============================================="
echo ""
echo " Next step:"
echo "   Run ./deploy.sh to create or update the Bedrock Agent."
echo ""
