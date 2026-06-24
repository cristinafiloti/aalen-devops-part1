#!/usr/bin/env bash
###############################################################################
# scripts/deploy.sh
#
# Build & deploy the FastAPI application to the Linux App Service that
# Terraform has just provisioned. Use this when you want to deploy from your
# laptop instead of running the Azure DevOps pipeline.
#
# Prerequisites:
#   - You ran `terraform apply` in ../terraform and the outputs are available
#   - You are logged in with `az login` against the right subscription
#   - zip is on PATH
#
# Usage:
#   ./scripts/deploy.sh
###############################################################################

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

# ----- read Terraform outputs --------------------------------------------------

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform CLI not found on PATH" >&2; exit 1
fi
if ! command -v az >/dev/null 2>&1; then
  echo "az CLI not found on PATH" >&2; exit 1
fi
if ! command -v zip >/dev/null 2>&1; then
  echo "zip not found on PATH" >&2; exit 1
fi

cd terraform
RG_NAME=$(terraform output -raw resource_group_name)
APP_NAME=$(terraform output -raw app_service_name)
APP_URL=$(terraform output -raw app_service_url)
cd "$root"

echo "Resource Group : $RG_NAME"
echo "App Service    : $APP_NAME"
echo "Public URL     : $APP_URL"
echo

# ----- build artifact ----------------------------------------------------------

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
artifact="$tmp/app.zip"

echo "==> Building zip artifact at $artifact"
# Include everything the App Service needs; Oryx will pip-install requirements.txt.
zip -qr "$artifact" \
  app \
  requirements.txt \
  -x "app/__pycache__/*" "*/__pycache__/*" "*.pyc"

echo "    artifact size: $(du -h "$artifact" | cut -f1)"

# ----- deploy ------------------------------------------------------------------

echo "==> Deploying to App Service..."
az webapp deploy \
  --resource-group "$RG_NAME" \
  --name "$APP_NAME" \
  --src-path "$artifact" \
  --type zip \
  --async false \
  --restart true

# ----- smoke test --------------------------------------------------------------

echo "==> Waiting for /healthz to return 200..."
for i in $(seq 1 18); do
  code=$(curl -sk -o /dev/null -w "%{http_code}" "$APP_URL/healthz" || echo "000")
  echo "    attempt $i -> HTTP $code"
  if [ "$code" = "200" ]; then
    echo
    echo "Deployment succeeded."
    echo "Open: $APP_URL"
    exit 0
  fi
  sleep 10
done

echo "App did not become healthy in time. Check logs with:" >&2
echo "  az webapp log tail -g $RG_NAME -n $APP_NAME" >&2
exit 1
