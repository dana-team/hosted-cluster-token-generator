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
REMOTE_CACHE_DIR="/tmp/remote_cache"

rm -rf "$REMOTE_CACHE_DIR"
mkdir -p "$REMOTE_CACHE_DIR"
echo "{}" > "$LOCAL_JSON"

if [[ -z "$REMOTES_JSON" ]]; then
  echo "ERROR: REMOTES_JSON environment variable is empty."
  exit 1
fi

if [[ -z "$CLUSTER_DOMAIN" ]]; then
  echo "ERROR: Missing required env vars (CLUSTER_DOMAIN)."
  exit 1
fi

TARGET_CONFIGMAP="application-rbac-validator-cluster-tokens"
TARGET_NAMESPACE="application-rbac-validator-system" 

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

is_token_valid() {
    local token="$1"
    local kubeconfig="$2"
    
    local api_url=$(oc config view --kubeconfig="$kubeconfig" -o jsonpath='{.clusters[0].cluster.server}')
    
    if [[ -z "$api_url" ]]; then return 1; fi

    if oc whoami --token="$token" --server="$api_url" --insecure-skip-tls-verify=true &>/dev/null; then
        return 0
    else
        return 1
    fi
}

sync_hosted_cluster() {
    local hosted_cluster_name="$1"
    local hosted_cluster_namespace="$2"
    local secret_name="${hosted_cluster_name}-admin-kubeconfig"
    local kubeconfig_path="/tmp/${hosted_cluster_name}.kubeconfig"
    
    if ! oc get secret -n "${hosted_cluster_namespace}" "${secret_name}" &> /dev/null; then
        echo "SKIP: $hosted_cluster_name (Secret not found)"
        return
    fi

    oc get secret -n "$hosted_cluster_namespace" "$secret_name" -o jsonpath='{.data.kubeconfig}' | base64 -d > "$kubeconfig_path"
    
    KEY="${hosted_cluster_name}-${CLUSTER_DOMAIN}-6443-token"

    NEED_NEW_TOKEN=false
    EXISTING_TOKEN=""
    ALL_REMOTES_HAVE_TOKEN=true

    for f in "$REMOTE_CACHE_DIR"/*.json; do
        [ -e "$f" ] || continue
        
        val=$(jq -r --arg k "$KEY" '.[$k] // empty' "$f")
        
        if [[ -z "$val" ]]; then
            echo "  -> Missing key '$KEY' in $(basename $f)"
            ALL_REMOTES_HAVE_TOKEN=false
            break
        fi
        EXISTING_TOKEN="$val"
    done

    if [[ "$ALL_REMOTES_HAVE_TOKEN" == "true" && -n "$EXISTING_TOKEN" ]]; then
        if is_token_valid "$EXISTING_TOKEN" "$kubeconfig_path"; then
            echo "OK: $hosted_cluster_name (Token valid. Skipping.)"
            rm -f "$kubeconfig_path"
            return
        else
            echo "  -> Token exists but is INVALID/EXPIRED."
            NEED_NEW_TOKEN=true
        fi
    else
        NEED_NEW_TOKEN=true
    fi

    if [[ "$NEED_NEW_TOKEN" == "true" ]]; then
        echo "REGEN: $hosted_cluster_name (Generating new token...)"
        export KUBECONFIG="$kubeconfig_path"

        if NEW_TOKEN=$(/app/scripts/generate-token.sh); then
            echo "Generated token for $hosted_cluster_name"
            
            jq --arg k "$KEY" --arg v "$NEW_TOKEN" \
               '.[$k] = $v' "$LOCAL_JSON" > "${LOCAL_JSON}.tmp" && \
               mv "${LOCAL_JSON}.tmp" "$LOCAL_JSON"
        else
            echo "ERROR: Failed to generate token for $hosted_cluster_name"
        fi
        unset KUBECONFIG
    fi

    rm -f "$kubeconfig_path"
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
# 5. PHASE 1: FETCH REMOTE STATE (NEW)
# ==========================================
echo "Fetching current tokens from remote sites..."

echo "$REMOTES_JSON" | jq -c '.[]' | while read -r site; do
    NAME=$(echo "$site" | jq -r '.name')
    URL=$(echo "$site" | jq -r '.url')
    TOKEN=$(echo "$site" | jq -r '.token')
    
    echo "  - Fetching from $NAME..."

    oc get configmap "$TARGET_CONFIGMAP" \
       -n "$TARGET_NAMESPACE" \
       --server="$URL" \
       --token="$TOKEN" \
       --insecure-skip-tls-verify=true \
       -o jsonpath='{.data}' > "$REMOTE_CACHE_DIR/$NAME.json" 2>/dev/null
    
    if [[ ! -s "$REMOTE_CACHE_DIR/$NAME.json" ]]; then
        echo "{}" > "$REMOTE_CACHE_DIR/$NAME.json"
    fi
done

# ==========================================
# 6. PHASE 2: MAIN EXECUTION (Analyze & Sync)
# ==========================================

echo "Starting Sync Analysis..."

oc get hostedclusters -A --no-headers | while read -r ns name rest; do
  sync_hosted_cluster "$name" "$ns"
done

# ==========================================
# 7. PHASE 3: REMOTE PATCH (Update ConfigMap)
# ==========================================

if [[ $(cat "$LOCAL_JSON") == "{}" ]]; then
  echo "Sync Complete. No updates required."
  exit 0
fi

jq '{data: .}' "$LOCAL_JSON" > "$TEMP_PATCH_FILE"

echo "Starting Multi-Site Patching..."

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