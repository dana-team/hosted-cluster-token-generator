FROM ghcr.io/flant/shell-operator:latest

RUN apk --no-cache add curl tar gcompat bash jq && \
    curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz | \
    tar -xz -C /usr/bin/ oc && \
    chmod +x /usr/bin/oc

COPY token-hook.sh /hooks/token-hook.sh
RUN chmod +x /hooks/token-hook.sh

WORKDIR /app/scripts
COPY generate-token.sh /app/scripts/generate-token.sh
RUN chmod +x /app/scripts/generate-token.sh