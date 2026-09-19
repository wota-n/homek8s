#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

# Pre-commit dry-run for a Flux app dir. Never touches the cluster.
#   1. kustomize build        -> catches bad YAML, broken resource refs, missing files
#   2. helm pull/clone + template -> renders the actual chart with the HelmRelease's .spec.values
#   3. kubeconform            -> validates every rendered object against the Kubernetes API schemas
#
# Note: schema-checking of the Flux objects themselves (HelmRelease/HelmRepository, etc.) is
# handled by your editor via the "# yaml-language-server: $schema=..." comments in those files.
#
# Usage: scripts/dry-run.sh <app-dir>
#   e.g. scripts/dry-run.sh kubernetes/apps/rustdesk/rustdesk/app

APP_DIR="${1:?usage: scripts/dry-run.sh <app-dir> (e.g. scripts/dry-run.sh kubernetes/apps/rustdesk/rustdesk/app)}"

# Resolve to an absolute path right away: it may be relative to the caller's
# cwd (e.g. "../kubernetes/apps/..." when run from scripts/).
APP_DIR="$(realpath -m "${APP_DIR}")"

[ -f "${APP_DIR}/kustomization.yaml" ] || log error "kustomization.yaml not found" "dir=${APP_DIR}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
export HELM_CACHE_HOME="${WORK_DIR}/helm-cache"
export HELM_CONFIG_HOME="${WORK_DIR}/helm-config"

check_cli kustomize helm yq kubeconform

# --- 1. kustomize build --------------------------------------------------------
log info "kustomize build" "dir=${APP_DIR}"
kustomize build "${APP_DIR}" > "${WORK_DIR}/built.yaml"
log info "kustomize build passed" "objects=$(grep -c '^kind:' "${WORK_DIR}/built.yaml")"

# Helper: query a single value from the built multi-doc yaml.
val() { yq -N "select(.kind == \"${1}\") | ${2}" "${WORK_DIR}/built.yaml"; }

# --- 2. helm pull/clone + template ---------------------------------------------
HR_NAME="$(val HelmRelease '.metadata.name')"
if [ -z "${HR_NAME}" ]; then
    log warn "no HelmRelease in ${APP_DIR}, nothing to render"
    exit 0
fi

yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' -o=y "${WORK_DIR}/built.yaml" > "${WORK_DIR}/values.yaml"

CHART_DIR=""
if OCI_URL="$(val OCIRepository '.spec.url')" && [ -n "${OCI_URL}" ] && [ "${OCI_URL}" != "null" ]; then
    log info "chart source: OCIRepository" "url=${OCI_URL}"
    helm pull "${OCI_URL}" -d "${WORK_DIR}"
elif REPO_URL="$(val HelmRepository '.spec.url')" && [ -n "${REPO_URL}" ] && [ "${REPO_URL}" != "null" ]; then
    log info "chart source: HelmRepository" "url=${REPO_URL}"
    CHART_NAME="$(val HelmRelease '.spec.chart.spec.chart')"
    CHART_VERSION="$(val HelmRelease '.spec.chart.spec.version')"
    helm repo add dryrun "${REPO_URL}" --force-update
    if [ -n "${CHART_VERSION}" ] && [ "${CHART_VERSION}" != "null" ]; then
        helm pull "dryrun/${CHART_NAME}" --version "${CHART_VERSION}" -d "${WORK_DIR}"
    else
        helm pull "dryrun/${CHART_NAME}" -d "${WORK_DIR}"
    fi
elif GIT_URL="$(val GitRepository '.spec.url')" && [ -n "${GIT_URL}" ] && [ "${GIT_URL}" != "null" ]; then
    log info "chart source: GitRepository" "url=${GIT_URL}"
    REF_TAG="$(val GitRepository '.spec.ref.tag')"
    REF_BRANCH="$(val GitRepository '.spec.ref.branch')"
    CLONE_DIR="${WORK_DIR}/gitrepo"
    if [ -n "${REF_TAG}" ] && [ "${REF_TAG}" != "null" ]; then
        git clone --depth 1 --branch "${REF_TAG}" "${GIT_URL}" "${CLONE_DIR}"
    elif [ -n "${REF_BRANCH}" ] && [ "${REF_BRANCH}" != "null" ]; then
        git clone --depth 1 --branch "${REF_BRANCH}" "${GIT_URL}" "${CLONE_DIR}"
    else
        git clone --depth 1 "${GIT_URL}" "${CLONE_DIR}"
    fi
    # For a git source, spec.chart.spec.chart is the chart's path inside the repo.
    CHART_PATH="$(val HelmRelease '.spec.chart.spec.chart')"
    if [ -z "${CHART_PATH}" ] || [ "${CHART_PATH}" = "null" ]; then
        CHART_PATH="."
    fi
    CHART_DIR="${CLONE_DIR}/${CHART_PATH}"
else
    log warn "could not determine chart source (no OCIRepository/HelmRepository/GitRepository), skipping helm steps"
    exit 0
fi

# --- resolve chart location (dir or tgz) ----------------------------------------
if [ -n "${CHART_DIR}" ]; then
    [ -d "${CHART_DIR}" ] || log error "chart dir not found in git repo" "path=${CHART_DIR}"
    CHART_REF="${CHART_DIR}"
else
    CHART_REF="$(find "${WORK_DIR}" -name '*.tgz' -print -quit)"
    [ -n "${CHART_REF}" ] || log error "chart tarball not found" "dir=${WORK_DIR}"
fi

log info "helm lint" "chart=${CHART_REF}"
helm lint "${CHART_REF}" -f "${WORK_DIR}/values.yaml"

log info "helm template" "release=${HR_NAME}"
helm template "${HR_NAME}" "${CHART_REF}" -f "${WORK_DIR}/values.yaml" > "${WORK_DIR}/rendered.yaml"

# --- 3. kubeconform ------------------------------------------------------------
log info "kubeconform -strict"
kubeconform -strict -kubernetes-version 1.34.0 -ignore-missing-schemas -summary "${WORK_DIR}/rendered.yaml"

log info "dry-run passed - safe to commit"
