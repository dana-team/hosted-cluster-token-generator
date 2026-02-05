#!/bin/bash

# ==========================================
# 1. CONFIGURATION PHASE
# ==========================================
SCHEDULE="${CRON_SCHEDULE:-0 0 * * *}"

if [[ $1 == "--config" ]] ; then
  cat <<EOF
configVersion: v1
kubernetes:
- name: OnHostedCluster
  apiVersion: hypershift.openshift.io/v1beta1
  kind: HostedCluster
  executeHookOnEvent: ["Added"]
schedule:
- name: DailyRefresh
  crontab: "$SCHEDULE"
EOF
  exit 0
fi

# ==========================================
# 2. SETUP & VALIDATION
# ==========================================

LOCAL_JSON="/tmp/local_tokens.json"
TEMP_PATCH_FILE="/tmp/patch.json"

echo "{}" > "$LOCAL_JSON"

if [[ -z "$REMOTES_JSON" ]]; then
  echo "ERROR: REMOTES_JSON environment variable is empty."
  exit 1
fi

TARGET_CONFIGMAP="application-rbac-validator-cluster-tokens"
TARGET_NAMESPACE="application-rbac-validator-system" 

if [[ -z "$CLUSTER_DOMAIN" || -z "$REMOTE_API_URL" || -z "$REMOTE_TOKEN" ]]; then
  echo "ERROR: Missing required env vars (CLUSTER_DOMAIN, REMOTE_API_URL, or REMOTE_TOKEN)."
  exit 1
fi

# ==========================================
# 3. HELPER FUNCTIONS
# ==========================================

wait_for_secret() {
    local cluster_name="$1"
    local namespace="$2"
    local secret_name="${cluster_name}-admin-kubeconfig"
    local timeout=300
    local interval=5
    local elapsed=0

    echo "New Cluster detected: $cluster_name. Waiting for secret '$secret_name'..."

    while [[ $elapsed -lt $timeout ]]; do
        if oc get secret -n "$namespace" "$secret_name" &> /dev/null; then
            echo "Secret found after ${elapsed}s."
            return 0
        fi
        sleep $interval
        ((elapsed+=interval))
    done

    echo "TIMEOUT: Secret '$secret_name' did not appear within ${timeout}s."
    return 1
}

sync_hosted_cluster() {
    local hosted_cluster_name="$1"
    local hosted_cluster_namespace="$2"
    local secret_name="${hosted_cluster_name}-admin-kubeconfig"
    
    if ! oc get secret -n "${hosted_cluster_namespace}" "${secret_name}" &> /dev/null; then
        return
    fi

    echo "Syncing HostedCluster: $hosted_cluster_name"

    oc get secret -n "$hosted_cluster_namespace" "$secret_name" -o jsonpath='{.data.kubeconfig}' | base64 -d > "/tmp/${hosted_cluster_name}.kubeconfig"
    export KUBECONFIG="/tmp/${hosted_cluster_name}.kubeconfig"

    if NEW_TOKEN=$(/app/scripts/generate-token.sh); then
        KEY="${hosted_cluster_name}-${CLUSTER_DOMAIN}-6443-token"
        
        echo "Generated token for $hosted_cluster_name -> Key: $KEY"

        jq --arg k "$KEY" --arg v "$NEW_TOKEN" \
           '.[$k] = $v' "$LOCAL_JSON" > "${LOCAL_JSON}.tmp" && \
           mv "${LOCAL_JSON}.tmp" "$LOCAL_JSON"
    else
        echo "ERROR: Failed to generate token for $hosted_cluster_name"
    fi

    unset KUBECONFIG
    rm -f "/tmp/${hosted_cluster_name}.kubeconfig"
}

# ==========================================
# 4. PRE-FLIGHT (The Gatekeeper)
# ==========================================

TRIGGER_TYPE=$(jq -r ".[0].type" $BINDING_CONTEXT_PATH)

if [[ "$TRIGGER_TYPE" == "Event" ]]; then
  NEW_CLUSTER_NAME=$(jq -r ".[0].object.metadata.name" $BINDING_CONTEXT_PATH)
  NEW_CLUSTER_NS=$(jq -r ".[0].object.metadata.namespace" $BINDING_CONTEXT_PATH)
  
  wait_for_secret "$NEW_CLUSTER_NAME" "$NEW_CLUSTER_NS"
fi

# ==========================================
# 5. MAIN EXECUTION (Generate All)
# ==========================================

echo "Starting Full Sync Loop..."

oc get hostedclusters -A --no-headers | while read -r ns name rest; do
  sync_hosted_cluster "$name" "$ns"
done

# ==========================================
# 6. REMOTE PATCH (Update ConfigMap)
# ==========================================

if [[ $(cat "$LOCAL_JSON") == "{}" ]]; then
  echo "No tokens found to sync. Exiting."
  exit 0
fi

jq '{data: .}' "$LOCAL_JSON" > "$TEMP_PATCH_FILE"

echo "Starting Multi-Site Patching..."

# We echo the Env Var and pipe it into jq
echo "$REMOTES_JSON" | jq -c '.[]' | while read -r site; do
    
    SITE_NAME=$(echo "$site" | jq -r '.name')
    SITE_URL=$(echo "$site" | jq -r '.url')
    SITE_TOKEN=$(echo "$site" | jq -r '.token')

    echo "------------------------------------------------"
    echo "Target: $SITE_NAME ($SITE_URL)"

    oc patch configmap "$TARGET_CONFIGMAP" \
      -n "$TARGET_NAMESPACE" \
      --type=merge \
      --patch-file "$TEMP_PATCH_FILE" \
      --server="$SITE_URL" \
      --token="$SITE_TOKEN" \
      --insecure-skip-tls-verify=true
    
    if [[ $? -eq 0 ]]; then
      echo "SUCCESS: Updated $SITE_NAME"
    else
      echo "ERROR: Failed to update $SITE_NAME"
    fi

done

echo "Multi-site sync complete."