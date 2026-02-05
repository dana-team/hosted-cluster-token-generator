#!/bin/bash

log() {
    echo "$@" >&2
}

log "Generating new token..."

oc create namespace dana --dry-run=client -o yaml | oc apply -f - >&2
oc delete serviceaccount dana-token-sa -n dana --ignore-not-found=true >&2
oc create serviceaccount dana-token-sa -n dana >&2
oc adm policy add-cluster-role-to-user cluster-admin -z dana-token-sa -n dana >&2

cat <<EOF | oc apply -f - >&2
apiVersion: v1
kind: Secret
metadata:
    name: dana-token-sa-secret
    namespace: dana
    annotations:
        kubernetes.io/service-account.name: dana-token-sa
type: kubernetes.io/service-account-token
EOF

log "Waiting for token secret to be populated..."

for i in {1..30}; do
    token=$(oc get secret dana-token-sa-secret -n dana -o jsonpath="{.data.token}" 2>/dev/null || true)
    
    if [[ -n "$token" ]]; then
        log "Token generated successfully"
        echo "$token" | base64 -d
        exit 0
    fi
    sleep 1
done

log "Failed to generate token within the expected time."
exit 1