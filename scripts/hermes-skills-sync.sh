#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# hermes-skills-sync.sh
#
# Keep the user's CUSTOM Hermes skills identical on this machine and on the k8s
# hermes instance's PVC (/opt/data/skills). Run by a systemd user timer at boot
# and every 15 min (see scripts/systemd/hermes-skills-sync.{service,timer}).
#
# The custom skills deliberately live OUTSIDE this (public) repo, on the instance
# PVC. Without this, editing a skill on one instance was invisible to the other.
#
# ---------------------------------------------------------------------------
# SYNC MODEL — three-way reconcile, one "base" hash per file
# ---------------------------------------------------------------------------
# The state file ($HERMES_HOME/.skills-sync-state.json) records the content hash
# of every managed file as of the last successful sync: the BASE. Comparing
# base/local/remote says exactly who changed what:
#
#   local == remote                 -> in sync        (advance base)
#   local == base, remote != base   -> remote changed (PULL remote -> local)
#   remote == base, local != base   -> local changed  (PUSH local -> remote)
#   local != base, remote != base   -> BOTH changed   (CONFLICT, touch nothing)
#
# A delete is just "changed to nothing", so deletions propagate too - but only
# when the other side is unchanged. That is what makes an accidental delete
# safe: delete a file locally while the PVC still matches base and the PVC copy
# goes too; but if the PVC changed as well you get a conflict, not data loss.
#
# A file with no base entry that exists on only one side is an ADDITION (push or
# pull); with no base entry and different content on BOTH sides it is ambiguous
# -> conflict. So new skills flow either way automatically, but a file that
# appeared independently on both sides is never guessed at.
#
# Safety rails:
#   - If a whole skill directory is missing on one side while the base says it
#     was synced, the script refuses to mass-delete the other side and reports a
#     conflict instead. Use push/pull to resolve.
#   - If the PVC cannot be read at all, or the pod is not Ready, nothing is
#     touched (a failed `kubectl` listing must never look like "everything was
#     deleted").
#
# ---------------------------------------------------------------------------
# CONFLICTS are never auto-merged
# ---------------------------------------------------------------------------
#   - nothing is overwritten on either side;
#   - both versions are saved under
#       $HERMES_HOME/.skills-sync-conflicts/<skill>/<path>.local
#       $HERMES_HOME/.skills-sync-conflicts/<skill>/<path>.remote
#   - the base is NOT advanced, so every later run re-reports it;
#   - exit code 2, so `systemctl --user --failed` turns red and a desktop
#     notification fires.
#
# Resolve either by making the two sides identical yourself (the next run then
# sees local == remote and clears the conflict), or by forcing a winner:
#     scripts/hermes-skills-sync.sh push --skill <name>   # local wins
#     scripts/hermes-skills-sync.sh pull --skill <name>   # PVC wins
#
# ---------------------------------------------------------------------------
# SCOPE
# ---------------------------------------------------------------------------
# Only CUSTOM skills are managed: a skill is custom when its directory name is
# absent from skills/.bundled_manifest. Bundled skills are never touched, and a
# new custom skill is picked up on either side automatically.
#
# Deliberately NOT synced: state.db / *.db (live SQLite + WAL), memories/,
# cron/, sessions/, .env, config.yaml. Those are per-instance runtime state, not
# text to merge; see AGENTS.md ("Hermes agent app").
# ============================================================================

source "$(dirname "${0}")/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: hermes-skills-sync.sh [MODE] [--skill NAME]... [--dry-run] [--quiet]

Keep the custom Hermes skills identical on this machine and on the k8s hermes
instance's PVC. With no MODE, a three-way sync is performed.

Modes:
  sync     reconcile: pull PVC edits, push local edits (default)
  status   report what would change; change nothing
  push     force local -> PVC for the selected skills (local wins)
  pull     force PVC -> local for the selected skills (PVC wins)

Options:
  --skill NAME   limit to one skill (repeatable; default: every custom skill)
  --dry-run      same as MODE=status
  --quiet        log warnings and errors only
  -h, --help     this text

Environment overrides:
  HERMES_HOME (~/.hermes)         HERMES_NAMESPACE (hermes)
  HERMES_POD (hermes)             HERMES_REMOTE_HOME (/opt/data)
  HERMES_SYNC_STATE               HERMES_SYNC_CONFLICTS
  HERMES_SYNC_OWNER (10000:10000)

Exit codes: 0 ok / nothing to do
            1 error
            2 conflict, or no sync state yet - a decision is needed
EOF
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NAMESPACE="${HERMES_NAMESPACE:-hermes}"
POD="${HERMES_POD:-hermes}"
SRC="${HERMES_HOME:-${HOME}/.hermes}"
SKILLS_DIR="${SRC}/skills"
REMOTE_HOME="${HERMES_REMOTE_HOME:-/opt/data}"
REMOTE_SKILLS="${REMOTE_HOME}/skills"
STATE="${HERMES_SYNC_STATE:-${SRC}/.skills-sync-state.json}"
CONFLICT_DIR="${HERMES_SYNC_CONFLICTS:-${SRC}/.skills-sync-conflicts}"
OWNER="${HERMES_SYNC_OWNER:-10000:10000}"
LOG_FILE="${HERMES_SYNC_LOG:-${SRC}/logs/skills-sync.log}"

MODE="sync"
DRY_RUN=0
SELECTED=()

while [ $# -gt 0 ]; do
    case "${1}" in
        sync | status | push | pull)
            MODE="${1}"
            shift
            ;;
        --dry-run)
            MODE="status"
            shift
            ;;
        --quiet)
            LOG_LEVEL="warn"
            shift
            ;;
        --skill)
            [ $# -ge 2 ] || log error "--skill requires a name"
            SELECTED+=("${2}")
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            log error "unknown argument" "arg=${1}"
            ;;
    esac
done

[ "${MODE}" = "status" ] && DRY_RUN=1

check_cli kubectl tar jq find

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
audit() {
    [ "${DRY_RUN}" = 1 ] && return 0
    mkdir -p -- "$(dirname "${LOG_FILE}")"
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"${LOG_FILE}"
}

rotate_log() {
    [ "${DRY_RUN}" = 1 ] && return 0
    [ -f "${LOG_FILE}" ] || return 0
    local lines
    lines="$(wc -l <"${LOG_FILE}")"
    if [ "${lines}" -gt 2000 ]; then
        tail -n 1000 "${LOG_FILE}" >"${TMP}/log.rotated"
        mv -f "${TMP}/log.rotated" "${LOG_FILE}"
    fi
}

pod_ready() {
    local ready
    ready="$(kubectl -n "${NAMESPACE}" get pod "${POD}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [ "${ready}" = "True" ]
}

# hash<TAB>relpath for every file under a skill directory.
manifest_local() {
    ( cd "${SKILLS_DIR}/${1}" && find . -type f -exec sha256sum {} + ) \
        | awk '{ h=$1; $1=""; sub(/^ +/,"",$0); sub(/^\.\//,"",$0); print h "\t" $0 }'
}

manifest_remote() {
    kubectl -n "${NAMESPACE}" exec "${POD}" -- sh -c '
        cd "$1" 2>/dev/null || exit 0
        find . -type f -exec sha256sum {} +
    ' _ "${REMOTE_SKILLS}/${1}" 2>/dev/null \
        | awk '{ h=$1; $1=""; sub(/^ +/,"",$0); sub(/^\.\//,"",$0); print h "\t" $0 }'
}

# Custom skill = a SKILL.md whose directory name is not in .bundled_manifest.
discover_local() {
    local manifest="${SKILLS_DIR}/.bundled_manifest"
    [ -f "${manifest}" ] || return 1
    cut -d: -f1 "${manifest}" | sort -u >"${TMP}/bundled.local"
    find "${SKILLS_DIR}" -name SKILL.md -printf '%h\n' 2>/dev/null \
        | sed -e "s|^${SKILLS_DIR}/||" \
        | while IFS= read -r rel; do
              grep -qx -- "$(basename "${rel}")" "${TMP}/bundled.local" || printf '%s\n' "${rel}"
          done \
        | sort -u
}

discover_remote() {
    kubectl -n "${NAMESPACE}" exec "${POD}" -- sh -c '
        cd "$1" || exit 1
        [ -f .bundled_manifest ] || exit 1
        cut -d: -f1 .bundled_manifest | sort -u > /tmp/.bundled.sync
        find . -name SKILL.md -printf "%h\n" | sed -e "s|^\./||" | while IFS= read -r rel; do
            grep -qx -- "$(basename "$rel")" /tmp/.bundled.sync || printf "%s\n" "$rel"
        done | sort -u
        rm -f /tmp/.bundled.sync
    ' _ "${REMOTE_SKILLS}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Actions (all honour DRY_RUN)
# ---------------------------------------------------------------------------
act_push_file() {
    local skill="${1}" rel="${2}"
    PUSHED=$((PUSHED + 1))
    if [ "${DRY_RUN}" = 1 ]; then
        log info "would push" "path=${skill}/${rel}"
        return 0
    fi
    log info "push" "path=${skill}/${rel}"
    kubectl -n "${NAMESPACE}" exec "${POD}" -- mkdir -p -- "${REMOTE_SKILLS}/${skill}"
    tar -cf - -C "${SKILLS_DIR}/${skill}" -- "${rel}" \
        | kubectl -n "${NAMESPACE}" exec -i "${POD}" -- tar -xf - -C "${REMOTE_SKILLS}/${skill}"
    audit "push ${skill}/${rel}"
}

act_pull_file() {
    local skill="${1}" rel="${2}"
    PULLED=$((PULLED + 1))
    if [ "${DRY_RUN}" = 1 ]; then
        log info "would pull" "path=${skill}/${rel}"
        return 0
    fi
    log info "pull" "path=${skill}/${rel}"
    mkdir -p -- "$(dirname "${SKILLS_DIR}/${skill}/${rel}")"
    kubectl -n "${NAMESPACE}" exec "${POD}" -- tar -cf - -C "${REMOTE_SKILLS}/${skill}" -- "${rel}" \
        | tar -xf - -C "${SKILLS_DIR}/${skill}"
    audit "pull ${skill}/${rel}"
}

act_delete_remote() {
    local skill="${1}" rel="${2}"
    DEL_REMOTE=$((DEL_REMOTE + 1))
    if [ "${DRY_RUN}" = 1 ]; then
        log info "would delete on PVC" "path=${skill}/${rel}"
        return 0
    fi
    log info "delete on PVC" "path=${skill}/${rel}"
    kubectl -n "${NAMESPACE}" exec "${POD}" -- rm -f -- "${REMOTE_SKILLS}/${skill}/${rel}"
    kubectl -n "${NAMESPACE}" exec "${POD}" -- sh -c \
        'find "$1" -mindepth 1 -type d -empty -delete' _ "${REMOTE_SKILLS}/${skill}" || true
    audit "delete-on-pvc ${skill}/${rel}"
}

act_delete_local() {
    local skill="${1}" rel="${2}"
    DEL_LOCAL=$((DEL_LOCAL + 1))
    if [ "${DRY_RUN}" = 1 ]; then
        log info "would delete locally" "path=${skill}/${rel}"
        return 0
    fi
    log info "delete locally" "path=${skill}/${rel}"
    rm -f -- "${SKILLS_DIR}/${skill}/${rel}"
    find "${SKILLS_DIR}/${skill}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    audit "delete-local ${skill}/${rel}"
}

record_conflict() {
    local skill="${1}" rel="${2}" lhash="${3}" rhash="${4}"
    CONFLICTS=$((CONFLICTS + 1))
    log warn "CONFLICT: both sides changed" \
        "path=${skill}/${rel}" "local=${lhash:0:12}" "remote=${rhash:0:12}"
    [ "${DRY_RUN}" = 1 ] && return 0
    local target="${CONFLICT_DIR}/${skill}/${rel}"
    mkdir -p -- "$(dirname "${target}")"
    if [ -n "${lhash}" ] && [ -f "${SKILLS_DIR}/${skill}/${rel}" ]; then
        cp -f -- "${SKILLS_DIR}/${skill}/${rel}" "${target}.local"
    fi
    if [ -n "${rhash}" ]; then
        local td="${TMP}/conflict.$$"
        rm -rf -- "${td}"
        mkdir -p -- "${td}"
        kubectl -n "${NAMESPACE}" exec "${POD}" -- tar -cf - -C "${REMOTE_SKILLS}/${skill}" -- "${rel}" \
            | tar -xf - -C "${td}" 2>/dev/null || true
        [ -f "${td}/${rel}" ] && mv -f -- "${td}/${rel}" "${target}.remote"
        rm -rf -- "${td}"
    fi
    audit "conflict ${skill}/${rel} local=${lhash:0:12} remote=${rhash:0:12}"
}

ensure_remote_dir() {
    local skill="${1}"
    [ "${DRY_RUN}" = 1 ] && return 0
    kubectl -n "${NAMESPACE}" exec "${POD}" -- mkdir -p -- "${REMOTE_SKILLS}/${skill}"
}

chown_remote_skill() {
    local skill="${1}"
    [ "${DRY_RUN}" = 1 ] && return 0
    kubectl -n "${NAMESPACE}" exec "${POD}" -- chown -R "${OWNER}" "${REMOTE_SKILLS}/${skill}"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
rotate_log

[ -d "${SKILLS_DIR}" ] || log error "skills directory not found" "dir=${SKILLS_DIR}"
[ -f "${SKILLS_DIR}/.bundled_manifest" ] \
    || log error "no .bundled_manifest; cannot tell custom skills from bundled" "dir=${SKILLS_DIR}"

if ! pod_ready; then
    log warn "hermes pod not Ready; nothing to do" "ns=${NAMESPACE}" "pod=${POD}"
    exit 0
fi

if [ -f "${STATE}" ] && ! jq -e . "${STATE}" >/dev/null 2>&1; then
    log error "state file is not valid JSON" "file=${STATE}"
fi

# ---------------------------------------------------------------------------
# Which skills are in scope
# ---------------------------------------------------------------------------
declare -A MANAGED=()
if [ ${#SELECTED[@]} -gt 0 ]; then
    for s in "${SELECTED[@]}"; do MANAGED["${s}"]=1; done
else
    LOCAL_LIST="$(discover_local)" || log error "cannot enumerate local custom skills"
    REMOTE_LIST="$(discover_remote)" || log error "cannot read the PVC skills dir"
    while IFS= read -r s; do if [ -n "${s}" ]; then MANAGED["${s}"]=1; fi; done <<<"${LOCAL_LIST}"
    while IFS= read -r s; do if [ -n "${s}" ]; then MANAGED["${s}"]=1; fi; done <<<"${REMOTE_LIST}"
fi

[ ${#MANAGED[@]} -gt 0 ] || log error "no custom skills found on either side"

# ---------------------------------------------------------------------------
# Base (last synced) hashes
# ---------------------------------------------------------------------------
declare -A B=()
STATE_PRESENT=0
if [ -f "${STATE}" ]; then
    STATE_PRESENT=1
    while IFS=$'\t' read -r skill path hash; do
        [ -n "${skill}" ] || continue
        B["${skill}/${path}"]="${hash}"
    done < <(jq -r '.skills | to_entries[] | .key as $s | .value | to_entries[] | "\($s)\t\(.key)\t\(.value)"' "${STATE}")
fi

# On a full run, forget skills that no longer exist on either side, so the state
# does not accumulate orphans for skills that were deleted (or renamed). A
# --skill run only touches what it was asked for and never prunes.
if [ ${#SELECTED[@]} -eq 0 ] && [ ${#B[@]} -gt 0 ]; then
    for k in "${!B[@]}"; do
        s="${k%%/*}"
        if [ -z "${MANAGED[$s]:-}" ]; then unset "B[${k}]"; fi
    done
fi

if [ "${MODE}" = "sync" ] && [ "${STATE_PRESENT}" = 0 ]; then
    log warn "no sync state yet - nothing has ever been synced from this machine"
    log warn "seed it once with a decision: 'push' (this machine wins) or 'pull' (PVC wins)"
    exit 2
fi

# New base, pre-seeded with the entries of skills this run does not touch.
declare -A NEWB=()
if [ ${#B[@]} -gt 0 ]; then
    for k in "${!B[@]}"; do NEWB["${k}"]="${B[$k]}"; done
fi

declare -A L=() R=()
PUSHED=0
PULLED=0
DEL_LOCAL=0
DEL_REMOTE=0
CONFLICTS=0

drop_newbase_skill() {
    local prefix="${1}/" k
    if [ ${#NEWB[@]} -gt 0 ]; then
        for k in "${!NEWB[@]}"; do
            if [[ "${k}" == "${prefix}"* ]]; then unset "NEWB[${k}]"; fi
        done
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Force modes
# ---------------------------------------------------------------------------
force_push_skill() {
    local skill="${1}" k rel
    if [ ! -d "${SKILLS_DIR}/${skill}" ]; then
        log warn "skill does not exist locally; skipped" "skill=${skill}"
        return 0
    fi
    log info "push (local wins)" "skill=${skill}"
    drop_newbase_skill "${skill}"
    if [ ${#L[@]} -gt 0 ]; then
        for k in "${!L[@]}"; do
            if [[ "${k}" == "${skill}/"* ]]; then NEWB["${k}"]="${L[$k]}"; fi
        done
    fi
    if [ "${DRY_RUN}" = 1 ]; then
        log info "would mirror local -> PVC" "skill=${skill}" "files=$(count_skill L "${skill}")"
        return 0
    fi
    ensure_remote_dir "${skill}"
    tar -cf - -C "${SKILLS_DIR}" -- "${skill}" \
        | kubectl -n "${NAMESPACE}" exec -i "${POD}" -- tar -xf - -C "${REMOTE_SKILLS}"
    PUSHED=$((PUSHED + $(count_skill L "${skill}")))
    if [ ${#R[@]} -gt 0 ]; then
        for k in "${!R[@]}"; do
            if [[ "${k}" == "${skill}/"* ]]; then
                rel="${k#${skill}/}"
                if [ -z "${L[$k]:-}" ]; then act_delete_remote "${skill}" "${rel}"; fi
            fi
        done
    fi
    chown_remote_skill "${skill}"
    audit "push-skill ${skill} files=$(count_skill L "${skill}")"
}

force_pull_skill() {
    local skill="${1}" k rel
    if [ "$(count_skill R "${skill}")" -eq 0 ]; then
        log warn "skill does not exist on the PVC; skipped" "skill=${skill}"
        return 0
    fi
    log info "pull (PVC wins)" "skill=${skill}"
    drop_newbase_skill "${skill}"
    if [ ${#R[@]} -gt 0 ]; then
        for k in "${!R[@]}"; do
            if [[ "${k}" == "${skill}/"* ]]; then NEWB["${k}"]="${R[$k]}"; fi
        done
    fi
    if [ "${DRY_RUN}" = 1 ]; then
        log info "would mirror PVC -> local" "skill=${skill}" "files=$(count_skill R "${skill}")"
        return 0
    fi
    mkdir -p -- "${SKILLS_DIR}/${skill}"
    kubectl -n "${NAMESPACE}" exec "${POD}" -- tar -cf - -C "${REMOTE_SKILLS}" -- "${skill}" \
        | tar -xf - -C "${SKILLS_DIR}"
    PULLED=$((PULLED + $(count_skill R "${skill}")))
    if [ ${#L[@]} -gt 0 ]; then
        for k in "${!L[@]}"; do
            if [[ "${k}" == "${skill}/"* ]]; then
                rel="${k#${skill}/}"
                if [ -z "${R[$k]:-}" ]; then act_delete_local "${skill}" "${rel}"; fi
            fi
        done
    fi
    audit "pull-skill ${skill} files=$(count_skill R "${skill}")"
}

count_skill() {
    local which="${1}" skill="${2}" k n=0
    if [ "${which}" = "L" ]; then
        if [ ${#L[@]} -gt 0 ]; then
            for k in "${!L[@]}"; do if [[ "${k}" == "${skill}/"* ]]; then n=$((n + 1)); fi; done
        fi
    else
        if [ ${#R[@]} -gt 0 ]; then
            for k in "${!R[@]}"; do if [[ "${k}" == "${skill}/"* ]]; then n=$((n + 1)); fi; done
        fi
    fi
    printf '%s' "${n}"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
for skill in "${!MANAGED[@]}"; do
    # -- load both manifests (keys are namespaced by skill) -------------------
    if [ -d "${SKILLS_DIR}/${skill}" ]; then
        while IFS=$'\t' read -r h p; do
            if [ -n "${p}" ]; then L["${skill}/${p}"]="${h}"; fi
        done < <(manifest_local "${skill}")
    fi
    while IFS=$'\t' read -r h p; do
        if [ -n "${p}" ]; then R["${skill}/${p}"]="${h}"; fi
    done < <(manifest_remote "${skill}")

    lcount="$(count_skill L "${skill}")"
    rcount="$(count_skill R "${skill}")"
    bcount=0
    if [ ${#B[@]} -gt 0 ]; then
        for k in "${!B[@]}"; do if [[ "${k}" == "${skill}/"* ]]; then bcount=$((bcount + 1)); fi; done
    fi

    # -- whole-skill-vanished safety rail ------------------------------------
    if [ "${bcount}" -gt 0 ] && [ "${lcount}" -eq 0 ] && [ "${rcount}" -gt 0 ]; then
        log warn "local copy of the skill is gone but it was synced; refusing to delete the PVC copy" \
            "skill=${skill}"
        CONFLICTS=$((CONFLICTS + 1))
        audit "blocked ${skill} local-dir-missing"
        continue
    fi
    if [ "${bcount}" -gt 0 ] && [ "${rcount}" -eq 0 ] && [ "${lcount}" -gt 0 ]; then
        log warn "PVC copy of the skill is gone but it was synced; refusing to delete local files" \
            "skill=${skill}"
        CONFLICTS=$((CONFLICTS + 1))
        audit "blocked ${skill} pvc-dir-missing"
        continue
    fi

    pushed_before="${PUSHED}"
    del_remote_before="${DEL_REMOTE}"

    if [ "${MODE}" = "push" ]; then
        force_push_skill "${skill}"
        continue
    fi
    if [ "${MODE}" = "pull" ]; then
        force_pull_skill "${skill}"
        continue
    fi

    # -- three-way reconcile -------------------------------------------------
    keys="${TMP}/keys.$$"
    : >"${keys}"
    if [ ${#L[@]} -gt 0 ]; then
        for k in "${!L[@]}"; do if [[ "${k}" == "${skill}/"* ]]; then printf '%s\n' "${k#${skill}/}"; fi; done >>"${keys}"
    fi
    if [ ${#R[@]} -gt 0 ]; then
        for k in "${!R[@]}"; do if [[ "${k}" == "${skill}/"* ]]; then printf '%s\n' "${k#${skill}/}"; fi; done >>"${keys}"
    fi
    if [ ${#B[@]} -gt 0 ]; then
        for k in "${!B[@]}"; do if [[ "${k}" == "${skill}/"* ]]; then printf '%s\n' "${k#${skill}/}"; fi; done >>"${keys}"
    fi
    sort -u -o "${keys}" "${keys}"

    while IFS= read -r rel; do
        [ -n "${rel}" ] || continue
        key="${skill}/${rel}"
        l="${L[$key]:-}"
        r="${R[$key]:-}"
        b="${B[$key]:-}"

        if [ "${l}" = "${r}" ]; then
            if [ -n "${l}" ]; then NEWB["${key}"]="${l}"; else unset "NEWB[${key}]"; fi
            continue
        fi

        if [ -z "${b}" ]; then
            # never synced: a one-sided file is an addition, both-sided is ambiguous
            if [ -z "${l}" ]; then
                act_pull_file "${skill}" "${rel}"
                NEWB["${key}"]="${r}"
            elif [ -z "${r}" ]; then
                act_push_file "${skill}" "${rel}"
                NEWB["${key}"]="${l}"
            else
                record_conflict "${skill}" "${rel}" "${l}" "${r}"
            fi
        elif [ "${l}" = "${b}" ]; then
            # local untouched -> remote moved
            if [ -z "${r}" ]; then
                act_delete_local "${skill}" "${rel}"
                unset "NEWB[${key}]"
            else
                act_pull_file "${skill}" "${rel}"
                NEWB["${key}"]="${r}"
            fi
        elif [ "${r}" = "${b}" ]; then
            # remote untouched -> local moved
            if [ -z "${l}" ]; then
                act_delete_remote "${skill}" "${rel}"
                unset "NEWB[${key}]"
            else
                act_push_file "${skill}" "${rel}"
                NEWB["${key}"]="${l}"
            fi
        else
            record_conflict "${skill}" "${rel}" "${l}" "${r}"
        fi
    done <"${keys}"

    # if this skill's PVC copy was written to, fix its ownership so the instance
    # (uid ${OWNER%%:*}) can edit those skills itself
    if [ "${PUSHED}" -gt "${pushed_before}" ] || [ "${DEL_REMOTE}" -gt "${del_remote_before}" ]; then
        chown_remote_skill "${skill}"
    fi
done

# ---------------------------------------------------------------------------
# Persist the new base
# ---------------------------------------------------------------------------
if [ "${DRY_RUN}" = 1 ]; then
    log info "dry run: state file left untouched" "file=${STATE}"
else
    : >"${TMP}/newbase.tsv"
    if [ ${#NEWB[@]} -gt 0 ]; then
        for k in "${!NEWB[@]}"; do
            printf '%s\t%s\t%s\n' "${k%%/*}" "${k#*/}" "${NEWB[$k]}" >>"${TMP}/newbase.tsv"
        done
    fi
    jq -Rn --arg ts "$(date -u +%FT%TZ)" --arg pod "${POD}" '
        [ inputs | select(length > 0) | split("\t")
          | { skill: .[0], path: .[1], hash: .[2] } ]
        | { version: 1, updated: $ts, pod: $pod,
            skills: ( reduce .[] as $e ({};
                        .[$e.skill] = ((.[$e.skill] // {}) + { ($e.path): $e.hash }))) }
    ' <"${TMP}/newbase.tsv" >"${TMP}/state.json"
    mv -f -- "${TMP}/state.json" "${STATE}"
    audit "state written files=${#NEWB[@]}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log info "skills sync complete" \
    "mode=${MODE}" "pulled=${PULLED}" "pushed=${PUSHED}" \
    "deleted_local=${DEL_LOCAL}" "deleted_remote=${DEL_REMOTE}" "conflicts=${CONFLICTS}"

if [ "${CONFLICTS}" -gt 0 ]; then
    if [ "${DRY_RUN}" = 0 ]; then
        mkdir -p -- "${CONFLICT_DIR}"
        cat >"${CONFLICT_DIR}/README.txt" <<EOF
Conflicting skill files are copied here as <skill>/<path>.local and
<skill>/<path>.remote. Neither side was modified.

Resolve by making the two versions identical (the next sync then clears it),
or by forcing a winner:

    scripts/hermes-skills-sync.sh push --skill <skill>   # this machine wins
    scripts/hermes-skills-sync.sh pull --skill <skill>   # the PVC wins
EOF
        if command -v notify-send >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
            notify-send -u critical "Hermes skills sync: conflict" \
                "${CONFLICTS} file(s) changed on both sides. See ${CONFLICT_DIR}" || true
        fi
    fi
    log warn "conflicts need a decision" "count=${CONFLICTS}" "dir=${CONFLICT_DIR}"
    exit 2
fi

exit 0
