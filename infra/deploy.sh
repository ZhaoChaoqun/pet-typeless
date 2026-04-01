#!/bin/bash
# PetTypeless Azure Deployment Script
#
# Deploys all infrastructure, builds the Docker image, and starts the server.
#
# Prerequisites:
#   - Azure CLI (`az`) logged in with appropriate subscription
#   - Bicep CLI (bundled with Azure CLI >=2.20)
#
# Usage:
#   cd <repo-root>
#   ./infra/deploy.sh
#
# Environment variables (required):
#   DOUBAO_APP_KEY     — 豆包 ASR app key
#   DOUBAO_ACCESS_KEY  — 豆包 ASR access key
#   API_TOKEN          — Client authentication token

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Validate prerequisites ───────────────────────────────────────

if ! command -v az &>/dev/null; then
    echo "❌ Azure CLI (az) not found. Install: https://aka.ms/install-azure-cli" >&2
    exit 1
fi

if [[ -z "${DOUBAO_APP_KEY:-}" ]]; then
    echo "❌ DOUBAO_APP_KEY is not set" >&2
    exit 1
fi

if [[ -z "${DOUBAO_ACCESS_KEY:-}" ]]; then
    echo "❌ DOUBAO_ACCESS_KEY is not set" >&2
    exit 1
fi

if [[ -z "${API_TOKEN:-}" ]]; then
    echo "❌ API_TOKEN is not set" >&2
    exit 1
fi

SUBSCRIPTION="715d3c9c-6d19-4031-bce2-f604d10d920a"

echo "🐱 PetTypeless Deployment"
echo "   Subscription: $SUBSCRIPTION"
echo ""

# Set subscription
az account set --subscription "$SUBSCRIPTION"

# ── Step 1: Deploy infrastructure ────────────────────────────────

echo "📦 Step 1/3: Deploying infrastructure (Bicep)..."

az deployment sub create \
    --location eastasia \
    --template-file "$SCRIPT_DIR/main.bicep" \
    --parameters "$SCRIPT_DIR/main.bicepparam" \
    --parameters doubaoAppKey="$DOUBAO_APP_KEY" doubaoAccessKey="$DOUBAO_ACCESS_KEY" apiToken="$API_TOKEN" \
    --name "pet-typeless-$(date +%Y%m%d-%H%M%S)" \
    --output table

echo "✅ Infrastructure deployed"
echo ""

# ── Step 2: Build and push Docker image ──────────────────────────

echo "🐳 Step 2/3: Building and pushing Docker image to ACR..."

az acr build \
    --registry pettypelessacr \
    --image pet-typeless-server:latest \
    --file server/Dockerfile \
    "$REPO_ROOT/server/"

echo "✅ Docker image pushed"
echo ""

# ── Step 3: Update Container App ─────────────────────────────────

echo "🚀 Step 3/3: Updating Container App..."

az containerapp update \
    --name pet-typeless-server \
    --resource-group pet-typeless \
    --image pettypelessacr.azurecr.io/pet-typeless-server:latest

# Get the FQDN
FQDN=$(az containerapp show \
    --name pet-typeless-server \
    --resource-group pet-typeless \
    --query "properties.configuration.ingress.fqdn" \
    --output tsv)

echo "✅ Container App updated"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🐱 PetTypeless is live!"
echo "   WebSocket: wss://$FQDN/ws?token=<API_TOKEN>"
echo "   Health:    https://$FQDN/health"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
