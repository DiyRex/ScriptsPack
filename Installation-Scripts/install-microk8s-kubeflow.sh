#!/usr/bin/env bash
#
# install-microk8s-kubeflow.sh  (v2)
# -----------------------------------------------------------------------------
# Validated, idempotent installer for MicroK8s + Charmed Kubeflow on a single
# Ubuntu node.
#
# v2 changes (lessons learned from real installs):
#   * MUST run as a normal user with sudo (not root). Running as root breaks
#     group membership and puts Juju config under /root.
#   * Works around the MetalLB enable-hook race condition where the webhook
#     isn't ready when the IPAddressPool is created.
#   * Works around the Juju 3.6 strict-confinement issue by registering the
#     k8s cloud manually from ~/.kube/config under the name "mk8s".
#   * Suppresses the harmless `update.go:85` snap-confinement warning.
#   * Adds patient wait + auto-kick for known sticky charms (istio-pilot,
#     tensorboard-controller).
#
# Tested on: Ubuntu 22.04 / 24.04 (x86_64).
# Requires:  ~4 CPU, 16 GB RAM (32 recommended), 50 GB free disk, sudo.
#
# Usage:
#   chmod +x install-microk8s-kubeflow.sh
#   ./install-microk8s-kubeflow.sh                # full install
#   ./install-microk8s-kubeflow.sh --status       # status only
#   ./install-microk8s-kubeflow.sh --uninstall    # tear everything down
#   ./install-microk8s-kubeflow.sh --resume       # skip preflight
# -----------------------------------------------------------------------------

set -euo pipefail

# ---- Configuration (override via env) ---------------------------------------
MICROK8S_CHANNEL="${MICROK8S_CHANNEL:-1.32/stable}"
JUJU_CHANNEL="${JUJU_CHANNEL:-3.6/stable}"
KUBEFLOW_CHANNEL="${KUBEFLOW_CHANNEL:-1.10/stable}"
METALLB_RANGE="${METALLB_RANGE:-10.64.140.43-10.64.140.49}"
KUBEFLOW_MODEL="${KUBEFLOW_MODEL:-kubeflow}"
JUJU_CLOUD_NAME="${JUJU_CLOUD_NAME:-mk8s}"      # NOT "microk8s" - reserved
JUJU_CONTROLLER="${JUJU_CONTROLLER:-uk8s}"
DEX_USERNAME="${DEX_USERNAME:-admin}"
DEX_PASSWORD="${DEX_PASSWORD:-admin}"

MIN_RAM_GB=16
MIN_DISK_GB=50
MIN_CPUS=4

KUBEFLOW_WAIT_MINUTES="${KUBEFLOW_WAIT_MINUTES:-90}"
STICKY_KICK_AFTER_MINUTES="${STICKY_KICK_AFTER_MINUTES:-25}"

# ---- Colors / logging -------------------------------------------------------
C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';   C_OFF=$'\033[0m'

log()  { echo "${C_BLU}[$(date +%H:%M:%S)]${C_OFF} $*"; }
ok()   { echo "${C_GRN}  ✓${C_OFF} $*"; }
warn() { echo "${C_YLW}  !${C_OFF} $*" >&2; }
err()  { echo "${C_RED}  ✗${C_OFF} $*" >&2; }
step() { echo; echo "${C_BLD}==> $*${C_OFF}"; }
die()  { err "$*"; exit 1; }

# Run a juju command and strip the noisy update.go:85 mount-namespace warning.
juju_q() {
  juju "$@" 2> >(grep -v 'update\.go:85' >&2)
}

# ---- Sanity / preflight -----------------------------------------------------
check_not_root() {
  if [ "$(id -u)" -eq 0 ]; then
    cat >&2 <<EOF
${C_RED}This script must NOT be run as root.${C_OFF}

Running as root will:
  - add 'root' (not your user) to the microk8s group
  - put Juju config under /root/.local/share/juju/
  - cause "controller not found" later when you switch to your normal user

Run as a regular user with sudo privileges:
  exit                          # leave the root shell
  ssh youruser@thishost
  ./install-microk8s-kubeflow.sh
EOF
    exit 1
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    die "sudo is required but not installed."
  fi
  sudo -v || die "sudo authentication failed"
}

preflight() {
  step "Preflight checks"

  [ -f /etc/os-release ] || die "Cannot detect OS."
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ]; then
    warn "OS is '$ID', not 'ubuntu'. Tuned for Ubuntu but proceeding."
  else
    ok "OS: Ubuntu ${VERSION_ID:-?}"
  fi

  local arch; arch=$(uname -m)
  case "$arch" in
    x86_64|aarch64) ok "Arch: $arch" ;;
    *) warn "Arch '$arch' is unusual; proceeding anyway." ;;
  esac

  local cpus; cpus=$(nproc)
  if [ "$cpus" -lt "$MIN_CPUS" ]; then
    warn "Only $cpus CPUs (recommended ≥$MIN_CPUS). Will be slow."
  else
    ok "CPUs: $cpus"
  fi

  local ram_gb
  ram_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
  if [ "$ram_gb" -lt "$MIN_RAM_GB" ]; then
    die "Only ${ram_gb} GiB RAM. Need ≥${MIN_RAM_GB} GiB (32 recommended)."
  else
    ok "RAM: ${ram_gb} GiB"
  fi

  local disk_gb
  disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  if [ "$disk_gb" -lt "$MIN_DISK_GB" ]; then
    die "Only ${disk_gb} GiB free on /. Need ≥${MIN_DISK_GB} GiB."
  else
    ok "Free disk on /: ${disk_gb} GiB"
  fi

  if ! command -v snap >/dev/null 2>&1; then
    log "Installing snapd…"
    sudo apt-get update -qq
    sudo apt-get install -y snapd
  fi
  ok "snap: $(snap --version | head -1)"

  if ! command -v python3 >/dev/null 2>&1; then
    log "Installing python3…"
    sudo apt-get update -qq
    sudo apt-get install -y python3
  fi

  log "Raising inotify limits (Kubeflow is greedy)…"
  sudo sysctl -w fs.inotify.max_user_instances=1280 >/dev/null
  sudo sysctl -w fs.inotify.max_user_watches=655360 >/dev/null
}

# ---- MicroK8s ---------------------------------------------------------------
install_microk8s() {
  step "Installing MicroK8s (channel: ${MICROK8S_CHANNEL})"

  if snap list microk8s >/dev/null 2>&1; then
    ok "MicroK8s already installed: $(snap list microk8s | awk 'NR==2 {print $2" ("$3")"}')"
  else
    sudo snap install microk8s --classic --channel="${MICROK8S_CHANNEL}"
    ok "MicroK8s installed"
  fi

  if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx microk8s; then
    log "Adding $USER to the 'microk8s' group…"
    sudo usermod -a -G microk8s "$USER"
    warn "Group 'microk8s' added. New shells will pick it up automatically."
    warn "This script will use 'sudo microk8s' for now to bypass that."
    USE_SUDO_MK=1
  else
    ok "$USER already in 'microk8s' group"
    USE_SUDO_MK=0
  fi

  mkdir -p "$HOME/.kube"
  sudo chown -f -R "$USER":"$USER" "$HOME/.kube" || true

  log "Waiting for MicroK8s to be ready…"
  sudo microk8s status --wait-ready >/dev/null
  ok "MicroK8s is ready"
}

mk() {
  if [ "${USE_SUDO_MK:-0}" -eq 1 ]; then
    sudo microk8s "$@"
  else
    microk8s "$@"
  fi
}

# ---- Addons -----------------------------------------------------------------
addon_enabled() {
  sudo microk8s status --format short 2>/dev/null \
    | grep -E "^(core/)?$1: enabled" -q
}

enable_simple_addons() {
  step "Enabling MicroK8s core addons"
  for a in dns hostpath-storage rbac; do
    if addon_enabled "$a"; then
      ok "addon already enabled: $a"
    else
      log "enabling addon: $a"
      sudo microk8s enable "$a"
    fi
  done
}

# Robust MetalLB enable that handles the webhook race condition.
enable_metallb_robust() {
  step "Enabling MetalLB (with webhook race-condition workaround)"

  if addon_enabled metallb; then
    ok "metallb addon already enabled"
  else
    log "Enabling metallb addon (the hook will likely fail to create the pool — that's OK, we fix it next)…"
    # Don't fail if the hook errors on the IPAddressPool creation.
    # We will create the pool ourselves once the webhook is actually ready.
    sudo microk8s enable "metallb:${METALLB_RANGE}" || \
      warn "metallb hook reported errors (expected); continuing"
  fi

  log "Waiting for MetalLB controller deployment…"
  if ! sudo microk8s kubectl wait --for=condition=Available deployment/controller \
        -n metallb-system --timeout=300s; then
    die "MetalLB controller never became Available. Check: microk8s kubectl get pods -n metallb-system"
  fi

  log "Waiting for MetalLB webhook endpoint to have at least one ready pod…"
  local deadline=$((SECONDS + 180))
  local eps=""
  while [ $SECONDS -lt $deadline ]; do
    eps=$(sudo microk8s kubectl get endpoints -n metallb-system webhook-service \
           -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
    if [ -n "$eps" ]; then
      ok "Webhook ready (endpoints: $eps)"
      break
    fi
    sleep 5
  done
  if [ -z "$eps" ]; then
    die "MetalLB webhook never got endpoints. Check: microk8s kubectl describe svc -n metallb-system webhook-service"
  fi

  log "Applying IPAddressPool (${METALLB_RANGE}) and L2Advertisement…"
  cat <<EOF | sudo microk8s kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-addresspool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-addresspool
EOF
  ok "MetalLB configured"
}

wait_for_core_pods() {
  step "Waiting for core pods to settle"
  local deadline=$((SECONDS + 300))
  while [ $SECONDS -lt $deadline ]; do
    if ! sudo microk8s kubectl get pods -A --no-headers 2>/dev/null \
         | awk '{print $4}' | grep -Ev '^(Running|Completed)$' | grep -q . ; then
      ok "All core pods Running/Completed"
      return 0
    fi
    sleep 5
  done
  warn "Timeout waiting for pods. Check: microk8s kubectl get pods -A"
}

# ---- Juju -------------------------------------------------------------------
install_juju() {
  step "Installing Juju (channel: ${JUJU_CHANNEL})"
  if snap list juju >/dev/null 2>&1; then
    ok "Juju already installed: $(snap list juju | awk 'NR==2 {print $2" ("$3")"}')"
  else
    sudo snap install juju --channel="${JUJU_CHANNEL}"
    ok "Juju installed"
  fi
  mkdir -p "$HOME/.local/share"
}

# Bootstrap Juju on MicroK8s, working around Juju 3.6's strict-confinement bug.
bootstrap_juju() {
  step "Bootstrapping Juju on MicroK8s"

  # Export microk8s kubeconfig to a path Juju can read.
  # Use `tee` because sudo doesn't apply to the > redirect.
  log "Exporting microk8s kubeconfig to ~/.kube/config…"
  sudo microk8s config | tee "$HOME/.kube/config" >/dev/null
  chmod 600 "$HOME/.kube/config"

  # Register the cloud manually under JUJU_CLOUD_NAME (NOT "microk8s" - that
  # name is reserved for the auto-detected cloud, which is broken on the Juju
  # 3.6 strict-confined snap).
  if juju_q clouds --client --format json 2>/dev/null \
       | grep -q "\"${JUJU_CLOUD_NAME}\""; then
    ok "Juju cloud '${JUJU_CLOUD_NAME}' already registered"
  else
    log "Registering microk8s as Juju cloud '${JUJU_CLOUD_NAME}'…"
    KUBECONFIG="$HOME/.kube/config" juju_q add-k8s "${JUJU_CLOUD_NAME}" --client
  fi

  if juju_q controllers --format json 2>/dev/null \
       | grep -q "\"${JUJU_CONTROLLER}\""; then
    ok "Juju controller '${JUJU_CONTROLLER}' already bootstrapped"
  else
    log "Bootstrapping controller '${JUJU_CONTROLLER}' on '${JUJU_CLOUD_NAME}' (a few minutes)…"
    juju_q bootstrap "${JUJU_CLOUD_NAME}" "${JUJU_CONTROLLER}"
  fi

  if juju_q models --format json 2>/dev/null \
       | grep -q "\"${KUBEFLOW_MODEL}\""; then
    ok "Juju model '${KUBEFLOW_MODEL}' already exists"
  else
    log "Adding model '${KUBEFLOW_MODEL}'…"
    juju_q add-model "${KUBEFLOW_MODEL}"
  fi
}

# ---- Kubeflow ---------------------------------------------------------------
deploy_kubeflow() {
  step "Deploying Charmed Kubeflow (channel: ${KUBEFLOW_CHANNEL})"

  juju_q switch "${KUBEFLOW_MODEL}" >/dev/null

  if juju_q status --format json 2>/dev/null \
       | grep -q '"kubeflow-dashboard"\|"dex-auth"'; then
    ok "Kubeflow bundle already deployed in '${KUBEFLOW_MODEL}'"
  else
    log "juju deploy kubeflow --channel ${KUBEFLOW_CHANNEL} --trust"
    log "Bundle definition is fast (~30s). Actual provisioning is the slow part."
    juju_q deploy kubeflow --channel "${KUBEFLOW_CHANNEL}" --trust
    ok "Kubeflow deploy initiated"
  fi
}

kick_unit() {
  local unit="$1"
  log "Kicking $unit (re-running config-changed hook)…"
  juju_q run "$unit" -- 'export JUJU_DISPATCH_PATH=hooks/config-changed; ./dispatch' \
    >/dev/null 2>&1 || true
}

wait_for_kubeflow() {
  step "Waiting for Kubeflow to settle (max ${KUBEFLOW_WAIT_MINUTES} min)"

  local start=$SECONDS
  local deadline=$((SECONDS + KUBEFLOW_WAIT_MINUTES * 60))
  local kicked_istio=0
  local kicked_tb=0
  local last_summary=0

  while [ $SECONDS -lt $deadline ]; do
    local elapsed_min=$(( (SECONDS - start) / 60 ))

    local statuses
    statuses=$(juju_q status --format json 2>/dev/null \
               | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); sys.exit(0)
units = []
for app, info in d.get("applications", {}).items():
    for u, ui in info.get("units", {}).items():
        units.append(ui.get("workload-status", {}).get("current", "?"))
from collections import Counter
print(",".join(f"{k}={v}" for k,v in sorted(Counter(units).items())))
' 2>/dev/null || echo "?")

    if [ $((SECONDS - last_summary)) -ge 60 ]; then
      log "[$elapsed_min min] $statuses"
      last_summary=$SECONDS
    fi

    if echo "$statuses" | grep -qE '^active=[0-9]+$'; then
      ok "All Kubeflow applications are active!"
      return 0
    fi

    if [ "$elapsed_min" -ge "$STICKY_KICK_AFTER_MINUTES" ]; then
      if [ "$kicked_istio" -eq 0 ] && \
         juju_q status istio-pilot --format json 2>/dev/null \
           | grep -q '"current": "error"\|handled .* errors'; then
        kick_unit "istio-pilot/0"
        kicked_istio=1
      fi
      if [ "$kicked_tb" -eq 0 ] && \
         juju_q status tensorboard-controller --format json 2>/dev/null \
           | grep -q '"message": "Waiting for gateway relation"'; then
        kick_unit "tensorboard-controller/0"
        kicked_tb=1
      fi
    fi

    sleep 30
  done

  warn "Timeout. Some apps may still be settling."
  warn "Run 'juju status' to see; common stuck charms can be kicked with:"
  warn "  juju run <unit>/0 -- 'export JUJU_DISPATCH_PATH=hooks/config-changed; ./dispatch'"
  return 1
}

configure_kubeflow() {
  step "Configuring dashboard URL & credentials"

  local ip=""
  for _ in 1 2 3 4 5 6; do
    ip=$(mk kubectl -n "${KUBEFLOW_MODEL}" get svc istio-ingressgateway-workload \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -n "$ip" ] && break
    sleep 10
  done
  if [ -z "$ip" ]; then
    warn "Could not detect ingress IP. Falling back to ${METALLB_RANGE%-*}."
    ip="${METALLB_RANGE%-*}"
  fi

  local public_url="http://${ip}.nip.io"
  juju_q config dex-auth public-url="${public_url}"
  juju_q config oidc-gatekeeper public-url="${public_url}"
  juju_q config dex-auth static-username="${DEX_USERNAME}"
  juju_q config dex-auth static-password="${DEX_PASSWORD}"

  ok "Dashboard URL:  ${public_url}"
  ok "Username:       ${DEX_USERNAME}"
  ok "Password:       ${DEX_PASSWORD}"
}

# ---- Status / uninstall -----------------------------------------------------
show_status() {
  step "Cluster & Kubeflow status"
  sudo microk8s status || true
  echo
  juju_q status --color 2>/dev/null || warn "juju not configured"
}

uninstall_all() {
  step "Removing Kubeflow, Juju, MicroK8s"
  juju_q destroy-controller "${JUJU_CONTROLLER}" \
    --destroy-all-models --destroy-storage --no-prompt 2>/dev/null || true
  sudo snap remove juju 2>/dev/null || true
  sudo snap remove microk8s --purge 2>/dev/null || true
  ok "Removed."
}

print_summary() {
  cat <<EOF

${C_BLD}===============================================================${C_OFF}
${C_GRN}MicroK8s + Charmed Kubeflow installation complete${C_OFF}
${C_BLD}===============================================================${C_OFF}

Useful commands:
  microk8s status
  microk8s kubectl get pods -A
  juju status
  juju status --watch 5s

If a charm is stuck in 'error' or 'waiting', try:
  juju run <unit>/0 -- 'export JUJU_DISPATCH_PATH=hooks/config-changed; ./dispatch'

Open the dashboard:
  URL:      Use the URL printed above (http://<IP>.nip.io)
  User:     ${DEX_USERNAME}
  Password: ${DEX_PASSWORD}

  From a remote machine, set up an SSH tunnel + SOCKS proxy:
    ssh -D 9999 -N ${USER}@$(hostname)
  then point your browser's SOCKS5 proxy at 127.0.0.1:9999.

Re-run status:    $0 --status
Uninstall:        $0 --uninstall
EOF
}

# ---- Main -------------------------------------------------------------------
main() {
  local mode="install"
  case "${1:-}" in
    --status)    mode="status" ;;
    --uninstall) mode="uninstall" ;;
    --resume)    mode="resume" ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
  esac

  case "$mode" in
    status)
      show_status
      ;;
    uninstall)
      check_not_root
      uninstall_all
      ;;
    install|resume)
      check_not_root
      [ "$mode" = "install" ] && preflight
      install_microk8s
      enable_simple_addons
      enable_metallb_robust
      wait_for_core_pods
      install_juju
      bootstrap_juju
      deploy_kubeflow
      wait_for_kubeflow || true
      configure_kubeflow
      print_summary
      ;;
  esac
}

main "$@"
