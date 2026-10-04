#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

# Push the local Hermes config + custom skills onto the deployed k8s hermes
# instance's PVC (/opt/data). The config is deliberately NOT stored in this
# (public) repo — it can carry personal paths/domains — so this script is how
# you update the running instance.
#
# Usage: scripts/hermes-push-config.sh
#
# Source of truth: $HERMES_HOME (default ~/.hermes) on the machine you run this
# from. Needs kubectl on PATH (mise-managed here). In the agent sandbox, run it
# under a pty because /dev/stderr is broken: script -qec "<cmd>" /dev/null

NAMESPACE="${HERMES_NAMESPACE:-hermes}"
POD="${HERMES_POD:-hermes}"
SRC="${HERMES_HOME:-${HOME}/.hermes}"
SKILLS=(
    homek8s-app-deployment
    homek8s-bitwarden-debugging
    homek8s-cluster-ops
    obsidian-vault-mynotes
)

check_cli kubectl

[ -f "${SRC}/config.yaml" ] || log error "config.yaml not found" "src=${SRC}/config.yaml"

log info "copying config.yaml" "pod=${POD}"
kubectl -n "${NAMESPACE}" cp "${SRC}/config.yaml" "${POD}:/opt/data/config.yaml"

log info "copying skills" "count=${#SKILLS[@]}"
for skill in "${SKILLS[@]}"; do
    [ -d "${SRC}/skills/${skill}" ] || log error "skill not found" "skill=${skill}"
    kubectl -n "${NAMESPACE}" cp "${SRC}/skills/${skill}" "${POD}:/opt/data/skills/"
    log debug "copied skill" "skill=${skill}"
done

# config.yaml is read at process start, so the gateway must restart to load it.
log info "restarting pod to load the new config" "pod=${POD}"
kubectl -n "${NAMESPACE}" delete pod "${POD}"

log info "done" "verify=kubectl -n ${NAMESPACE} get pod ${POD}"
