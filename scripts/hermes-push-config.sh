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
#
# Skills are handed off to scripts/hermes-skills-sync.sh, which transfers them
# with tar and hands the result back to the instance's uid 10000. (kubectl cp
# left root-owned directories behind, which the instance's own agent could then
# not edit.) That script also keeps a sync state, so the systemd timer can later
# pull instance-side skill edits back to this machine.

NAMESPACE="${HERMES_NAMESPACE:-hermes}"
POD="${HERMES_POD:-hermes}"
SRC="${HERMES_HOME:-${HOME}/.hermes}"

check_cli kubectl

[ -f "${SRC}/config.yaml" ] || log error "config.yaml not found" "src=${SRC}/config.yaml"

log info "copying config.yaml" "pod=${POD}"
kubectl -n "${NAMESPACE}" cp "${SRC}/config.yaml" "${POD}:/opt/data/config.yaml"

# Mirror every custom skill (auto-discovered: any skill whose name is not in
# .bundled_manifest) onto the PVC, local side winning.
log info "pushing custom skills"
"$(dirname "${0}")/hermes-skills-sync.sh" push

# config.yaml is read at process start, so the gateway must restart to load it.
log info "restarting pod to load the new config" "pod=${POD}"
kubectl -n "${NAMESPACE}" delete pod "${POD}"

log info "done" "verify=kubectl -n ${NAMESPACE} get pod ${POD}"
