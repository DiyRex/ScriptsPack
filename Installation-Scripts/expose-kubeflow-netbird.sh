#!/usr/bin/env bash
#
# expose-kubeflow-netbird.sh  (v3 — charm-version-aware)
# -----------------------------------------------------------------------------
# Configures Charmed Kubeflow's dashboard to be reachable over a NetBird VPN
# overlay network from any peer.
#
# What it does:
#   1. Auto-detects the NetBird interface (default: wt0) and its IP.
#   2. Auto-detects the MetalLB-assigned ingress IP.
#   3. Probes which config keys dex-auth / oidc-gatekeeper actually accept
#      (the key names changed in CKF 1.9+: public-url -> issuer-url on
#      dex-auth, and public-url became optional on oidc-gatekeeper).
#   4. Sets dashboard credentials + (if applicable) public/issuer URLs.
#   5. Adds iptables DNAT + MASQUERADE rules to bridge NetBird traffic into
#      the cluster's MetalLB IP.
#   6. Persists IP forwarding sysctl and iptables rules across reboot.
#   7. Verifies the dashboard is reachable.
#
# Idempotent. Safe to re-run.
#
# Usage:
#   chmod +x expose-kubeflow-netbird.sh
#   ./expose-kubeflow-netbird.sh                              # auto-detect everything
#   ./expose-kubeflow-netbird.sh --hostname my-host.netbird.cloud
#   ./expose-kubeflow-netbird.sh --user admin --password mypass
#   ./expose-kubeflow-netbird.sh --remove                     # remove iptables rules
#   ./expose-kubeflow-netbird.sh --status                     # show current config
# -----------------------------------------------------------------------------

set -euo pipefail

# ---- Defaults ---------------------------------------------------------------
NETBIRD_IFACE="${NETBIRD_IFACE:-wt0}"
NETBIRD_IP=""
NETBIRD_HOSTNAME=""
KFLOW_IP=""
KUBEFLOW_MODEL="${KUBEFLOW_MODEL:-kubeflow}"
DEX_USERNAME="${DEX_USERNAME:-admin}"
DEX_PASSWORD="${DEX_PASSWORD:-admin}"
EXPOSE_PORT="${EXPOSE_PORT:-80}"
USE_HTTPS="${USE_HTTPS:-no}"
SYSCTL_FILE="/etc/sysctl.d/99-netbird-kubeflow.conf"

# Detected capabilities (filled in during probe)
DEX_HAS_ISSUER_URL="no"
DEX_HAS_PUBLIC_URL="no"
OIDC_HAS_PUBLIC_URL="no"

# ---- Pretty output ----------------------------------------------------------
C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';   C_OFF=$'\033[0m'

log()  { echo "${C_BLU}[$(date +%H:%M:%S)]${C_OFF} $*"; }
ok()   { echo "${C_GRN}  ✓${C_OFF} $*"; }
warn() { echo "${C_YLW}  !${C_OFF} $*" >&2; }
err()  { echo "${C_RED}  ✗${C_OFF} $*" >&2; }
step() { echo; echo "${C_BLD}==> $*${C_OFF}"; }
die()  { err "$*"; exit 1; }

# Filter the harmless juju snap-confinement chatter on every invocation.
juju() {
  command juju "$@" 2> >(grep -v -E 'update\.go:[0-9]+: cannot change mount namespace|cannot inspect "/run/user/' >&2)
}

# ---- Helpers ----------------------------------------------------------------
require_normal_user() {
  [ "$(id -u)" -eq 0 ] && die "Do NOT run this as root. Run as the user that owns juju (e.g. 'zuselk')."
  command -v sudo >/dev/null 2>&1 || die "sudo not found."
  sudo -v || die "sudo authentication failed"
}

mk() {
  if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx microk8s; then
    microk8s "$@"
  else
    sudo microk8s "$@"
  fi
}

# Build the user-facing URL (no /dex suffix — for dashboards/browsers).
user_url() {
  local scheme="http"
  [ "$USE_HTTPS" = "yes" ] && scheme="https"
  local url="${scheme}://${NETBIRD_HOSTNAME}"
  if { [ "$EXPOSE_PORT" != "80" ] && [ "$scheme" = "http" ]; } || \
     { [ "$EXPOSE_PORT" != "443" ] && [ "$scheme" = "https" ]; }; then
    url="${url}:${EXPOSE_PORT}"
  fi
  printf '%s' "$url"
}

# Build the Dex issuer URL (with /dex suffix — per dex-auth charm docs).
issuer_url() {
  printf '%s/dex' "$(user_url)"
}

# ---- Detection --------------------------------------------------------------
detect_netbird_iface() {
  for ifname in wt0 nb0 netbird0 utun_nb0; do
    if ip -4 addr show "$ifname" >/dev/null 2>&1; then
      NETBIRD_IFACE="$ifname"
      return 0
    fi
  done
  local found
  found=$(ip -4 -o addr show 2>/dev/null \
    | awk '$4 ~ /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./ {print $2; exit}' \
    || true)
  if [ -n "$found" ]; then
    NETBIRD_IFACE="$found"
    return 0
  fi
  return 1
}

detect_netbird_ip() {
  if [ -n "${NETBIRD_IP_OVERRIDE:-}" ]; then
    NETBIRD_IP="$NETBIRD_IP_OVERRIDE"
    return 0
  fi
  detect_netbird_iface || return 1
  NETBIRD_IP=$(ip -4 addr show "$NETBIRD_IFACE" 2>/dev/null \
                | awk '/inet / {print $2; exit}' | cut -d/ -f1 || true)
  [ -n "$NETBIRD_IP" ]
}

detect_netbird_hostname() {
  if [ -n "${NETBIRD_HOSTNAME_OVERRIDE:-}" ]; then
    NETBIRD_HOSTNAME="$NETBIRD_HOSTNAME_OVERRIDE"
    return 0
  fi

  local fqdn
  fqdn=$(hostname -f 2>/dev/null || hostname || true)
  if [ -n "$fqdn" ]; then
    local resolved
    resolved=$(getent hosts "$fqdn" 2>/dev/null | awk '{print $1}' | head -1 || true)
    if [ -n "$resolved" ] && [ "$resolved" = "$NETBIRD_IP" ]; then
      NETBIRD_HOSTNAME="$fqdn"
      return 0
    fi
  fi

  if command -v netbird >/dev/null 2>&1; then
    local nb_fqdn
    nb_fqdn=$(sudo netbird status 2>/dev/null \
              | awk -F': *' '/Domain|FQDN|Hostname/ {print $2; exit}' \
              | tr -d '[:space:]' || true)
    if [ -n "$nb_fqdn" ]; then
      NETBIRD_HOSTNAME="$nb_fqdn"
      return 0
    fi
  fi

  NETBIRD_HOSTNAME="$NETBIRD_IP"
}

detect_kubeflow_ingress_ip() {
  for _ in 1 2 3 4 5 6; do
    KFLOW_IP=$(mk kubectl -n "${KUBEFLOW_MODEL}" get svc istio-ingressgateway-workload \
                -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -n "$KFLOW_IP" ] && return 0
    sleep 5
  done
  return 1
}

# Returns 0 if the given app/key is a known config option for the deployed charm.
app_has_config_key() {
  local app="$1" key="$2"
  command juju config "$app" --format json 2>/dev/null \
    | grep -q "\"$key\""
}

probe_charm_config_keys() {
  step "Probing charm config schemas"
  if app_has_config_key dex-auth issuer-url; then
    DEX_HAS_ISSUER_URL="yes"; ok "dex-auth supports 'issuer-url'"
  fi
  if app_has_config_key dex-auth public-url; then
    DEX_HAS_PUBLIC_URL="yes"; ok "dex-auth supports 'public-url'"
  fi
  if app_has_config_key oidc-gatekeeper public-url; then
    OIDC_HAS_PUBLIC_URL="yes"; ok "oidc-gatekeeper supports 'public-url'"
  fi
  if [ "$DEX_HAS_ISSUER_URL" = "no" ] && [ "$DEX_HAS_PUBLIC_URL" = "no" ]; then
    warn "dex-auth exposes neither 'issuer-url' nor 'public-url'. Continuing with credentials only."
  fi
}

print_detected() {
  step "Detected configuration"
  echo "  NetBird interface : ${NETBIRD_IFACE}"
  echo "  NetBird IP        : ${NETBIRD_IP}"
  echo "  NetBird hostname  : ${NETBIRD_HOSTNAME}"
  echo "  Kubeflow ingress  : ${KFLOW_IP}"
  echo "  Expose port       : ${EXPOSE_PORT}"
  echo "  Dashboard URL     : $(user_url)"
  echo "  Dashboard user    : ${DEX_USERNAME}"
  echo "  dex-auth keys     : issuer-url=${DEX_HAS_ISSUER_URL}  public-url=${DEX_HAS_PUBLIC_URL}"
  echo "  oidc keys         : public-url=${OIDC_HAS_PUBLIC_URL}"
}

# ---- Juju config ------------------------------------------------------------
configure_kubeflow() {
  step "Configuring Kubeflow credentials & URLs"

  juju switch "${KUBEFLOW_MODEL}" >/dev/null 2>&1 || \
    die "Could not switch to juju model '${KUBEFLOW_MODEL}'. Is Kubeflow deployed?"

  local dash_url issuer
  dash_url="$(user_url)"
  issuer="$(issuer_url)"

  # Credentials — stable keys across all CKF versions.
  log "Setting dex-auth static-username=${DEX_USERNAME}"
  juju config dex-auth static-username="${DEX_USERNAME}"
  log "Setting dex-auth static-password (hidden)"
  juju config dex-auth static-password="${DEX_PASSWORD}"

  # Set whichever URL config the current charm revision supports.
  if [ "$DEX_HAS_ISSUER_URL" = "yes" ]; then
    log "Setting dex-auth issuer-url = ${issuer}"
    juju config dex-auth issuer-url="${issuer}" || \
      warn "dex-auth issuer-url failed (non-fatal — dex falls back to cluster-internal URL)"
  elif [ "$DEX_HAS_PUBLIC_URL" = "yes" ]; then
    log "Setting dex-auth public-url = ${dash_url}  (legacy key)"
    juju config dex-auth public-url="${dash_url}" || \
      warn "dex-auth public-url failed (non-fatal)"
  else
    log "dex-auth has no URL config option — skipping (charm auto-detects on 1.9+)"
  fi

  if [ "$OIDC_HAS_PUBLIC_URL" = "yes" ]; then
    log "Setting oidc-gatekeeper public-url = ${dash_url}"
    juju config oidc-gatekeeper public-url="${dash_url}" || \
      warn "oidc-gatekeeper public-url failed (non-fatal — often optional in 1.9+)"
  fi

  ok "Juju config applied"
  log "Auth pods will restart; this can take 1-2 minutes."

  local deadline=$((SECONDS + 180))
  while [ $SECONDS -lt $deadline ]; do
    local s=""
    s=$(command juju status dex-auth --format json 2>/dev/null \
        | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); u=d['applications']['dex-auth']['units']
    print(list(u.values())[0]['workload-status']['current'])
except Exception:
    print('')" 2>/dev/null || echo "")
    if [ "$s" = "active" ]; then
      ok "dex-auth is active"
      return 0
    fi
    sleep 5
  done
  warn "dex-auth did not return to active within 3m. Check 'juju status'."
}

# ---- iptables NAT bridge ----------------------------------------------------
rule_exists() {
  local table="$1" chain="$2"; shift 2
  sudo iptables -t "$table" -C "$chain" "$@" 2>/dev/null
}

apply_nat_rules() {
  step "Applying iptables NAT rules (NetBird → Kubeflow ingress)"

  log "Enabling IPv4 forwarding…"
  sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
  echo "net.ipv4.ip_forward=1" | sudo tee "$SYSCTL_FILE" >/dev/null
  ok "IP forwarding enabled (persistent in $SYSCTL_FILE)"

  local dnat_args=(-p tcp -d "$NETBIRD_IP" --dport "$EXPOSE_PORT"
                   -j DNAT --to-destination "${KFLOW_IP}:${EXPOSE_PORT}")
  if rule_exists nat PREROUTING "${dnat_args[@]}"; then
    ok "DNAT rule already present"
  else
    log "Adding DNAT: ${NETBIRD_IP}:${EXPOSE_PORT} → ${KFLOW_IP}:${EXPOSE_PORT}"
    sudo iptables -t nat -A PREROUTING "${dnat_args[@]}"
    ok "DNAT rule added"
  fi

  local masq_args=(-p tcp -d "$KFLOW_IP" --dport "$EXPOSE_PORT" -j MASQUERADE)
  if rule_exists nat POSTROUTING "${masq_args[@]}"; then
    ok "MASQUERADE rule already present"
  else
    log "Adding MASQUERADE for ${KFLOW_IP}:${EXPOSE_PORT}"
    sudo iptables -t nat -A POSTROUTING "${masq_args[@]}"
    ok "MASQUERADE rule added"
  fi
}

persist_iptables() {
  step "Persisting iptables rules across reboot"
  if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    log "Installing iptables-persistent (non-interactive)…"
    DEBIAN_FRONTEND=noninteractive sudo -E apt-get update -qq
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
    DEBIAN_FRONTEND=noninteractive sudo -E apt-get install -y iptables-persistent
  fi
  sudo netfilter-persistent save >/dev/null
  ok "Rules saved (will reload on boot)"
}

remove_nat_rules() {
  step "Removing iptables NAT rules"

  if [ -n "$NETBIRD_IP" ] && [ -n "$KFLOW_IP" ]; then
    if sudo iptables -t nat -D PREROUTING -p tcp -d "$NETBIRD_IP" --dport "$EXPOSE_PORT" \
         -j DNAT --to-destination "${KFLOW_IP}:${EXPOSE_PORT}" 2>/dev/null; then
      ok "DNAT rule removed"
    else
      warn "DNAT rule not present (or already removed)"
    fi
    if sudo iptables -t nat -D POSTROUTING -p tcp -d "$KFLOW_IP" --dport "$EXPOSE_PORT" \
         -j MASQUERADE 2>/dev/null; then
      ok "MASQUERADE rule removed"
    else
      warn "MASQUERADE rule not present"
    fi
  else
    warn "Could not auto-detect IPs; no rules to remove"
  fi

  if dpkg -s iptables-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save >/dev/null
    ok "Saved updated rules"
  fi
  sudo rm -f "$SYSCTL_FILE"
  ok "Removed $SYSCTL_FILE"
}

# ---- Verification -----------------------------------------------------------
verify() {
  step "Verifying dashboard reachability"
  local url; url="$(user_url)"
  log "Trying: curl -I ${url}"
  local http_code
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 15 "$url" || echo "000")
  case "$http_code" in
    200|301|302|307|308)
      ok "Dashboard responded (HTTP $http_code) — likely redirecting to dex login. You're good."
      return 0 ;;
    000)
      warn "Could not connect (HTTP 000). Possible causes:"
      warn "  - dex-auth/oidc-gatekeeper still restarting (give it another minute)"
      warn "  - iptables rules wrong: check 'sudo iptables -t nat -L -n -v'"
      warn "  - Kubeflow ingress IP changed: re-run this script"
      return 1 ;;
    *)
      warn "Dashboard returned HTTP $http_code. Investigate with: curl -v $url"
      return 1 ;;
  esac
}

save_access_info() {
  local url; url="$(user_url)"
  {
    echo "KUBEFLOW_URL=${url}"
    echo "KUBEFLOW_USER=${DEX_USERNAME}"
    echo "KUBEFLOW_PASSWORD=${DEX_PASSWORD}"
    echo "NETBIRD_IFACE=${NETBIRD_IFACE}"
    echo "NETBIRD_IP=${NETBIRD_IP}"
    echo "KUBEFLOW_INGRESS_IP=${KFLOW_IP}"
  } > "$HOME/.kubeflow-access"
  chmod 600 "$HOME/.kubeflow-access"
  ok "Saved access info to ~/.kubeflow-access"
}

show_status() {
  step "Current state"
  detect_netbird_ip || warn "NetBird interface/IP not detected"
  detect_netbird_hostname
  detect_kubeflow_ingress_ip || warn "Kubeflow ingress IP not detected"
  probe_charm_config_keys || true
  print_detected

  echo
  echo "${C_BLD}iptables NAT rules:${C_OFF}"
  sudo iptables -t nat -L PREROUTING -n -v 2>/dev/null | grep -E "DNAT|Chain" || true
  sudo iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep -E "MASQ|Chain" || true

  echo
  echo "${C_BLD}IP forwarding:${C_OFF}"
  echo "  net.ipv4.ip_forward = $(cat /proc/sys/net/ipv4/ip_forward)"

  if [ -r "$HOME/.kubeflow-access" ]; then
    echo
    echo "${C_BLD}Saved access info (~/.kubeflow-access):${C_OFF}"
    cat "$HOME/.kubeflow-access"
  fi
}

print_summary() {
  local url; url="$(user_url)"
  cat <<EOF

${C_BLD}==============================================================${C_OFF}
${C_GRN}Kubeflow is exposed via NetBird${C_OFF}
${C_BLD}==============================================================${C_OFF}

  Dashboard URL : ${url}
  Username      : ${DEX_USERNAME}
  Password      : ${DEX_PASSWORD}

From any peer on the same NetBird network, open the URL above.
On first login you'll be asked to pick a namespace name (e.g. 'admin').

Files written:
  ~/.kubeflow-access            (URL + credentials, mode 600)
  ${SYSCTL_FILE}   (persistent IP forwarding)
  /etc/iptables/rules.v4        (persistent NAT rules)

To inspect or undo:
  $0 --status
  $0 --remove

EOF
}

usage() { sed -n '2,30p' "$0"; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --hostname)  NETBIRD_HOSTNAME_OVERRIDE="$2"; shift 2 ;;
      --ip)        NETBIRD_IP_OVERRIDE="$2"; shift 2 ;;
      --iface)     NETBIRD_IFACE="$2"; shift 2 ;;
      --user)      DEX_USERNAME="$2"; shift 2 ;;
      --password)  DEX_PASSWORD="$2"; shift 2 ;;
      --port)      EXPOSE_PORT="$2"; shift 2 ;;
      --https)     USE_HTTPS=yes; shift ;;
      --status)    ACTION=status; shift ;;
      --remove)    ACTION=remove; shift ;;
      -h|--help)   usage; exit 0 ;;
      *) die "Unknown argument: $1 (try --help)" ;;
    esac
  done
}

main() {
  ACTION="apply"
  parse_args "$@"
  require_normal_user

  case "$ACTION" in
    status) show_status; exit 0 ;;
    remove)
      detect_netbird_ip || true
      detect_kubeflow_ingress_ip || true
      remove_nat_rules
      exit 0 ;;
  esac

  step "Detecting environment"
  detect_netbird_ip || die "Could not detect a NetBird IP. Pass --iface <n> or --ip <addr>."
  ok "NetBird IP: ${NETBIRD_IP} on ${NETBIRD_IFACE}"

  detect_netbird_hostname
  ok "NetBird hostname: ${NETBIRD_HOSTNAME}"

  detect_kubeflow_ingress_ip || die "Kubeflow ingress IP not assigned. Is MetalLB running and the bundle deployed?"
  ok "Kubeflow ingress: ${KFLOW_IP}"

  local resolved
  resolved=$(getent hosts "$NETBIRD_HOSTNAME" 2>/dev/null | awk '{print $1}' | head -1 || true)
  if [ -n "$resolved" ] && [ "$resolved" != "$NETBIRD_IP" ]; then
    warn "Hostname '${NETBIRD_HOSTNAME}' resolves to ${resolved}, not ${NETBIRD_IP}."
    warn "Browser access may fail unless DNS is fixed."
  elif [ -z "$resolved" ]; then
    log "Hostname '${NETBIRD_HOSTNAME}' not in local resolver — assuming NetBird DNS handles it on peers."
  fi

  probe_charm_config_keys
  print_detected
  configure_kubeflow
  apply_nat_rules
  persist_iptables
  save_access_info
  verify || warn "Verification failed. Try the curl command again in ~60s; auth pods may still be restarting."
  print_summary
}

main "$@"
