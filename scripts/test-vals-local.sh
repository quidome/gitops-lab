#!/bin/bash
set -e

echo "🔐 Testing Vault + Vals Integration"
echo ""

# Check if VALS_TOKEN is set
if [ -z "$VALS_TOKEN" ]; then
  echo "❌ VALS_TOKEN not set"
  echo "   Please run: export VALS_TOKEN=<your-vals-reader-token>"
  exit 1
fi

# Start port-forward if not already running
if ! lsof -Pi :8200 -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "📡 Starting port-forward to Vault..."
  kubectl port-forward -n security svc/vault 8200:8200 >/dev/null 2>&1 &
  PF_PID=$!
  echo "   Port-forward PID: $PF_PID"
  sleep 2
else
  echo "✅ Port 8200 already listening"
fi

# Set environment
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="$VALS_TOKEN"

echo "✅ VAULT_ADDR=$VAULT_ADDR"
echo "✅ VAULT_TOKEN set"
echo ""

# Test Vault connectivity
echo "🔍 Testing Vault connectivity..."
if ! curl -s -H "X-Vault-Token: $VAULT_TOKEN" $VAULT_ADDR/v1/sys/health >/dev/null 2>&1; then
  echo "❌ Cannot connect to Vault"
  exit 1
fi
echo "✅ Vault is accessible"
echo ""

# Test helmfile template
echo "🎯 Testing helmfile template..."
echo ""
cd /home/quidome/dev/github.com/quidome/gitops-lab

helmfile -f infrastructure/security/vault/examples/test-vals.yaml.gotmpl template

echo ""
echo "🎉 Test complete!"
echo ""
echo "👀 Check the output above:"
echo "   - Should show 'foo: \"bar\"'"
echo "   - Should show 'message: \"Hello from Vault\"'"
echo "   - Should show 'number: \"42\"'"
echo "   - Should NOT show 'ref+vault://...' strings"
