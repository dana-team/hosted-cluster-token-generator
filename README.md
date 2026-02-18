# Hosted Cluster Token Generator

## Overview
This project provides an automated solution for generating and distributing service account tokens for hosted OpenShift clusters. It watches for the creation of new hosted clusters on a hub cluster and executes a sync loop to ensure remote OpenShift/Kubernetes locations have valid, up-to-date authentication tokens for them. 

**How shell-operator works:**
The system relies on **shell-operator**, an open-source tool by Flant that simplifies the creation of Kubernetes operators by treating standard shell scripts as event-driven hooks. 
* **Two-Phase Execution:** * **Configuration Phase:** When starting, shell-operator runs the executable hook script with a `--config` flag to get bindings to events. The script must output a JSON or YAML configuration telling the operator which Kubernetes events or cron schedules it wants to subscribe to.
    * **Execution Phase:** When a matching event occurs, the operator runs the script again without the flag. It passes the event details via a JSON file path stored in the `$BINDING_CONTEXT_PATH` environment variable.
* Shell-operator acts as an integration layer, allowing sysadmins to automate cluster operations using familiar command-line tools (like Bash, Python, or kubectl) without needing to write complex controllers.

---

## Architecture & Workflow
The system utilizes two primary scripts working in tandem:

### 1. Trigger & Sync (`token-hook.sh`)
* Subscribes to the `Added` event of `HostedCluster` resources (`hypershift.openshift.io/v1beta1`) and a daily cron schedule (`0 0 * * *`).
* When triggered by a new cluster, it waits for the `admin-kubeconfig` secret to be generated.
* Fetches a ConfigMap (`application-rbac-validator-cluster-tokens`) from remote sites defined in the `REMOTES_JSON` environment variable to check the current state of tokens.
* Iterates over all hosted clusters, checking if a valid token exists across all remote sites.
* If a token is missing, expired, or invalid, it triggers the generation script.
* Patches the remote ConfigMaps with the newly generated tokens using a JSON merge patch.

### 2. Token Generation (`generate-token.sh`)
* Targets a specific hosted cluster using the provided `KUBECONFIG`.
* Checks if a valid token already exists in the `dana` namespace for the `dana-token-sa` service account.
* If not, it provisions the namespace, service account, and a `cluster-admin` ClusterRoleBinding.
* Generates a static Kubernetes service account token secret, waits for it to populate, and returns the base64-decoded token to the main hook.

---

## Environment Variables & Configuration
The main hook relies on the following environment variables to function properly:
* `CRON_SCHEDULE`: The schedule for the daily refresh (defaults to `0 0 * * *`).
* `REMOTES_JSON`: A required JSON array containing the configuration for remote sites. It must include the `name`, `url`, and `token` for each target remote cluster.
* `CLUSTER_DOMAIN`: A required base domain used to construct the JSON key for the token (e.g., `<cluster-name>-<cluster-domain>-6443-token`).

---

## Container Packaging
The project is containerized using a custom Dockerfile designed to run the shell-operator hook:
* **Base Image:** Uses `ghcr.io/flant/shell-operator:latest`.
* **Dependencies:** Installs necessary alpine packages including `curl`, `tar`, `gcompat`, `bash`, and `jq`.
* **OpenShift Client:** Downloads and extracts the `oc` CLI binary directly from the OpenShift mirror.
* **Scripts:** Copies `token-hook.sh` into the `/hooks` directory and `generate-token.sh` into `/app/scripts/`, ensuring both are fully executable.