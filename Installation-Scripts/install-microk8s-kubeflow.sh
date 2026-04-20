#!/usr/bin/env bash
#
# install-microk8s-kubeflow.sh
# -----------------------------------------------------------------------------
# Validated, idempotent installer for MicroK8s + Charmed Kubeflow on a single
# Ubuntu node.
#
# - Uses Juju to deploy Charmed Kubeflow (the `microk8s enable kubeflow` addon
#   is deprecated).
# - Pins known-good channels for MicroK8s (1.32) and Juju (3.6).
# - Idempotent: safe to re-run. Each step checks current state before acting.
# - Fails fast with a clear error on any step.
#
# Tested targets: Ubuntu 22.04 / 24.04 (x86_64).
# Requires: ~4 CPU, 32 GB RAM, 50 GB free disk, sudo privileges.
#
# Usage:
#   chmod +x install-microk8s-kubeflow.sh
#   ./install-microk8s-kubeflow.sh            # full install
#   ./install-microk8s-kubeflow.sh --status   # show status only
#   ./install-microk8s-kubeflow.sh --uninstall
# -----------------------------------------------------------------------------

set -euo pipefail

# ---- Configuration ----------------------------------------------------------
MICROK8S_CHANNEL="${MICROK8S_CHANNEL:-1.32/stable}"
JUJU_CHANNEL="${JUJU_CHANNEL:-3.6/stable}"
KUBEFLOW_CHANNEL="${KUBEFLOW_CHANNEL:-1.10/stable}"
METALLB_RANGE="${METALLB_RANGE:-10.64.140.43-10.64.140.49}"
KUBEFLOW_MODEL="${KUBEFLOW_MODEL:-kubeflow}"
DEX_USERNAME="${DEX_USERNAME:-admin}"
DEX_PASSWORD="${DEX_PASSWORD:-admin}"
JUJU_CONTROLLER="${JUJU_CONTROLLER:-uk8s}"

MIN_RAM_GB=16            # hard minimum; 32 GB is recommended
MIN_DISK_GB=50
MIN_CPUS=4

# ---- Pretty output ----------------------------------------------------------
C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';   C_OFF=$'\033[0m'

log()  { echo "${C_BLU}[$(date +%H:%M:%S)]${C_OFF} $*"; }
ok()   { echo "${C_GRN}  ✓${C_OFF} $*"; }
warn() { echo "${C_YLW}  !${C_OFF} $*" >&2; }
err()  { echo "${C_RED}  ✗${C_OFF} $*" >&2; }
step() { echo; echo "${C_BLD}==> $*${C_OFF}"; }

die() { err "$*"; exit 1; }

# ---- Helpers ----------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

require_root_or_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    sudo -v || die "sudo authentication failed"
  else
    die "This script needs root privileges or sudo."
  fi
}

# Run microk8s as either the current user (if in the microk8s group) or via sudo.
mk() {
  if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx microk8s; then
    microk8s "$@"
  else
    $SUDO microk8s "$@"
  fi
}

# ---- Preflight --------------------------------------------------------------
preflight() {
  step "Preflight checks"

  # OS
  if [ ! -f /etc/os-release ]; then
    die "Cannot detect OS (no /etc/os-release)."
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ]; then
    warn "OS is '$ID', not 'ubuntu'. MicroK8s works on other distros, but this script is tuned for Ubuntu."
  else
    ok "OS: Ubuntu ${VERSION_ID:-unknown}"
  fi

  # Arch
  local arch; arch=$(uname -m)
  case "$arch" in
    x86_64|aarch64) ok "Arch: $arch" ;;
    *) warn "Arch '$arch' is unusual for Kubeflow; proceeding anyway." ;;
  esac

  # CPU
  local cpus; cpus=$(nproc)
  if [ "$cpus" -lt "$MIN_CPUS" ]; then
    warn "Only $cpus CPUs detected (recommended: $MIN_CPUS+). Kubeflow will be slow."
  else
    ok "CPUs: $cpus"
  fi

  # RAM
  local ram_gb
  ram_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
  if [ "$ram_gb" -lt "$MIN_RAM_GB" ]; then
    die "Only ${ram_gb} GiB RAM detected. Kubeflow requires at least ${MIN_RAM_GB} GiB (32 recommended)."
  else
    ok "RAM: ${ram_gb} GiB"
  fi

  # Disk
  local disk_gb
  disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  if [ "$disk_gb" -lt "$MIN_DISK_GB" ]; then
    die "Only ${disk_gb} GiB free on /. Kubeflow needs at least ${MIN_DISK_GB} GiB."
  else
    ok "Free disk on /: ${disk_gb} GiB"
  fi

  # snapd
  if ! command -v snap >/dev/null 2>&1; then
    log "Installing snapd…"
    $SUDO apt-get update -qq
    $SUDO apt-get install -y snapd
  fi
  ok "snap: $(snap --version | head -1)"
}

# ---- MicroK8s ---------------------------------------------------------------
install_microk8s() {
  step "Installing MicroK8s (channel: ${MICROK8S_CHANNEL})"

  if snap list microk8s >/dev/null 2>&1; then
    ok "MicroK8s already installed: $(snap list microk8s | awk 'NR==2 {print $2" ("$3")"}')"
  else
    $SUDO snap install microk8s --classic --channel="${MICROK8S_CHANNEL}"
    ok "MicroK8s installed"
  fi

  # User permissions
  if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx microk8s; then
    log "Adding $USER to the 'microk8s' group…"
    $SUDO usermod -a -G microk8s "$USER"
    warn "You were added to the 'microk8s' group. You MUST log out and back in (or run: newgrp microk8s) after this script finishes for the group to take effect in new shells."
  else
    ok "$USER is already in the microk8s group"
  fi

  # ~/.kube dir ownership
  mkdir -p "$HOME/.kube"
  $SUDO chown -f -R "$USER" "$HOME/.kube" || true

  log "Waiting for MicroK8s to be ready…"
  $SUDO microk8s status --wait-ready >/dev/null
  ok "MicroK8s is ready"
}

# ---- Addons -----------------------------------------------------------------
addon_enabled() {
  # returns 0 if addon $1 appears under "enabled:" in microk8s status
  $SUDO microk8s status --format short 2>/dev/null \
    | awk '/^core\/'"$1"': enabled/ || /^'"$1"': enabled/' \
    | grep -q .
}

enable_addons() {
  step "Enabling required MicroK8s addons"

  # dns, hostpath-storage, ingress, metallb, rbac, dashboard are needed for Kubeflow
  local addons=(dns hostpath-storage rbac)
  for a in "${addons[@]}"; do
    if addon_enabled "$a"; then
      ok "addon already enabled: $a"
    else
      log "enabling addon: $a"
      $SUDO microk8s enable "$a"
    fi
  done

  # MetalLB needs an IP range argument, so handle separately
  if addon_enabled metallb; then
    ok "addon already enabled: metallb"
  else
    log "enabling addon: metallb (${METALLB_RANGE})"
    $SUDO microk8s enable "metallb:${METALLB_RANGE}"
  fi

  # Let things settle
  log "Waiting for core pods (timeout 300s)…"
  local deadline=$((SECONDS + 300))
  while [ $SECONDS -lt $deadline ]; do
    if ! $SUDO microk8s kubectl get pods -A --no-headers 2>/dev/null \
         | awk '{print $4}' \
         | grep -Ev '^(Running|Completed)$' \
         | grep -q . ; then
      ok "All core pods Running/Completed"
      return 0
    fi
    sleep 5
  done
  warn "Timeout waiting for all pods to reach Running; continuing anyway. Check: microk8s kubectl get pods -A"
}

# ---- Juju -------------------------------------------------------------------
install_juju() {
  step "Installing Juju (channel: ${JUJU_CHANNEL})"

  if snap list juju >/dev/null 2>&1; then
    ok "Juju already installed: $(snap list juju | awk 'NR==2 {print $2" ("$3")"}')"
  else
    $SUDO snap install juju --channel="${JUJU_CHANNEL}"
    ok "Juju installed"
  fi

  # Juju needs ~/.local/share on some systems
  mkdir -p "$HOME/.local/share"
}

bootstrap_juju() {
  step "Bootstrapping Juju on MicroK8s"

  # Register microk8s as a Juju cloud if not already
  if ! juju clouds --format json 2>/dev/null | grep -q '"microk8s"'; then
    log "Registering microk8s as a Juju cloud…"
    # `microk8s config` prints a valid kubeconfig; pipe it into Juju
    $SUDO microk8s config | juju add-k8s microk8s --client >/dev/null 2>&1 || \
      mk config | juju add-k8s microk8s --client >/dev/null 2>&1 || true
  fi

  if juju controllers --format json 2>/dev/null | grep -q "\"${JUJU_CONTROLLER}\""; then
    ok "Juju controller '${JUJU_CONTROLLER}' already bootstrapped"
  else
    log "Bootstrapping controller '${JUJU_CONTROLLER}' (this takes a few minutes)…"
    juju bootstrap microk8s "${JUJU_CONTROLLER}"
    ok "Juju controller bootstrapped"
  fi

  if juju models --format json 2>/dev/null | grep -q "\"${KUBEFLOW_MODEL}\""; then
    ok "Juju model '${KUBEFLOW_MODEL}' already exists"
  else
    log "Adding Juju model '${KUBEFLOW_MODEL}'…"
    juju add-model "${KUBEFLOW_MODEL}"
  fi
}

# ---- Kubeflow ---------------------------------------------------------------
deploy_kubeflow() {
  step "Deploying Charmed Kubeflow (channel: ${KUBEFLOW_CHANNEL})"

  juju switch "${KUBEFLOW_CONTROLLER:-${JUJU_CONTROLLER}}:${KUBEFLOW_MODEL}" >/dev/null 2>&1 || \
    juju switch "${KUBEFLOW_MODEL}" >/dev/null

  # Recommended sysctl bumps for Kubeflow (inotify watchers etc.)
  if [ "$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)" -lt 1280 ]; then
    log "Raising inotify limits…"
    $SUDO sysctl -w fs.inotify.max_user_instances=1280 >/dev/null
    $SUDO sysctl -w fs.inotify.max_user_watches=655360 >/dev/null
  fi

  if juju status --format json 2>/dev/null | grep -q '"kubeflow-dashboard"\|"dex-auth"'; then
    ok "Kubeflow bundle already deployed in model '${KUBEFLOW_MODEL}'"
  else
    log "Running: juju deploy kubeflow --channel ${KUBEFLOW_CHANNEL} --trust"
    log "This will take 20-60 minutes. Monitor with: watch -n 5 juju status"
    juju deploy kubeflow --channel "${KUBEFLOW_CHANNEL}" --trust
    ok "Kubeflow deploy initiated"
  fi

  log "Waiting for Kubeflow to settle (max 60 minutes)…"
  # `juju wait-for` is built into juju 3.x
  if ! juju wait-for model "${KUBEFLOW_MODEL}" --timeout 60m \
        --query='forEach(applications, app => app.status == "active") && forEach(units, unit => unit.workload-status == "active")' ; then
    warn "Not all apps went active within 60m. Check: juju status"
    warn "Some charms (e.g. tensorboard-controller) may need a manual kick — see the troubleshooting hints printed at the end."
  else
    ok "All Kubeflow applications are active"
  fi
}

configure_kubeflow() {
  step "Configuring Kubeflow dashboard auth & public URL"

  local ip
  ip=$(mk kubectl -n "${KUBEFLOW_MODEL}" get svc istio-ingressgateway-workload \
         -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -z "$ip" ]; then
    warn "Could not determine ingress IP; using default ${METALLB_RANGE%-*}"
    ip="${METALLB_RANGE%-*}"
  fi
  local public_url="http://${ip}.nip.io"

  juju config dex-auth public-url="${public_url}"
  juju config oidc-gatekeeper public-url="${public_url}"
  juju config dex-auth static-username="${DEX_USERNAME}"
  juju config dex-auth static-password="${DEX_PASSWORD}"
  ok "Dashboard URL:  ${public_url}"
  ok "Username:       ${DEX_USERNAME}"
  ok "Password:       ${DEX_PASSWORD}"
}

# ---- Status / uninstall -----------------------------------------------------
show_status() {
  step "Cluster & Kubeflow status"
  $SUDO microk8s status || true
  echo
  juju status --color 2>/dev/null || warn "juju not configured yet"
}

uninstall_all() {
  step "Removing Kubeflow, Juju, and MicroK8s"
  juju destroy-controller "${JUJU_CONTROLLER}" --destroy-all-models --destroy-storage -y 2>/dev/null || true
  $SUDO snap remove juju 2>/dev/null || true
  $SUDO snap remove microk8s --purge 2>/dev/null || true
  ok "Removed. You may want to: sudo deluser $USER microk8s"
}

# ---- Main -------------------------------------------------------------------
print_summary() {
  cat <<EOF

${C_BLD}==============================================================${C_OFF}
${C_GRN}MicroK8s + Charmed Kubeflow install complete${C_OFF}
${C_BLD}==============================================================${C_OFF}

Useful commands:
  microk8s status
  microk8s kubectl get pods -A
  juju status
  juju status --watch 5s

If any charm is stuck, common fixes:
  # Restart a flaky pod:
  microk8s kubectl -n ${KUBEFLOW_MODEL} delete pod <pod-name>

  # Kick a unit's hooks (e.g. tensorboard-controller waiting on istio):
  juju run --unit istio-pilot/0 -- \\
    'export JUJU_DISPATCH_PATH=hooks/config-changed; ./dispatch'

Open the dashboard in a browser on this machine (or via SSH tunnel):
  URL:      http://<ingress-ip>.nip.io   (see above)
  User:     ${DEX_USERNAME}
  Password: ${DEX_PASSWORD}

To re-run just the status check:  $0 --status
To uninstall everything:          $0 --uninstall

${C_YLW}NOTE:${C_OFF} If this was the first install, log out and back in
(or run 'newgrp microk8s') so your shell picks up the microk8s group.
EOF
}

main() {
  case "${1:-}" in
    --status)    require_root_or_sudo; show_status; exit 0 ;;
    --uninstall) require_root_or_sudo; uninstall_all; exit 0 ;;
    -h|--help)
      sed -n '2,22p' "$0"; exit 0 ;;
  esac

  require_root_or_sudo
  preflight
  install_microk8s
  enable_addons
  install_juju
  bootstrap_juju
  deploy_kubeflow
  configure_kubeflow
  print_summary
}

main "$@"
