#!/bin/bash

NAMESPACE="dana"
SA_NAME="dana-token-sa"
SECRET_NAME="dana-token-sa-secret"

log() {
    echo "$@" >&2
}

is_token_valid() {
    local token="$1"
    if oc whoami --token="$token" --server="https://kubernetes.default.svc" --insecure-skip-tls-verify=true &>/dev/null; then
        return 0
    else
        return 1
    fi
}

if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Secret '$SECRET_NAME' found. Checking validity..."
    
    EXISTING_TOKEN_B64=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath="{.data.token}" 2>/dev/null)
    
    if [[ -n "$EXISTING_TOKEN_B64" ]]; then
        EXISTING_TOKEN=$(echo "$EXISTING_TOKEN_B64" | base64 -d)
        
        if is_token_valid "$EXISTING_TOKEN"; then
            log "Existing token is valid. Reusing it."
            echo "$EXISTING_TOKEN"
            exit 0
        else
            log "Existing token is expired or invalid. Recreating..."
        fi
    fi
else
    log "Secret not found. creating new..."
fi

log "Generating new token..."

oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f - >&2

oc delete serviceaccount "$SA_NAME" -n "$NAMESPACE" --ignore-not-found=true >&2
oc create serviceaccount "$SA_NAME" -n "$NAMESPACE" >&2
oc adm policy add-cluster-role-to-user cluster-admin -z "$SA_NAME" -n "$NAMESPACE" >&2

cat <<EOF | oc apply -f - >&2
apiVersion: v1
kind: Secret
metadata:
    name: $SECRET_NAME
    namespace: $NAMESPACE
    annotations:
        kubernetes.io/service-account.name: $SA_NAME
type: kubernetes.io/service-account-token
EOF

log "Waiting for token secret to be populated..."

for i in {1..30}; do
    token=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath="{.data.token}" 2>/dev/null || true)
    
    if [[ -n "$token" ]]; then
        log "Token generated successfully"
        echo "$token" | base64 -d
        exit 0
    fi
    sleep 1
done

log "Failed to generate token within the expected time."
exit 1