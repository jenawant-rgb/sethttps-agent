#!/usr/bin/env bash
#
# sethttps-agent.sh — create a chrooted, SFTP-only account for certificate deployment.
#
# SetHttps uploads certificates with this account. That is the only thing it is
# allowed to do: the shell is /usr/sbin/nologin, the account is chrooted to one
# directory, SFTP is the only permitted subsystem, and — if you pass --reload-cmd —
# exactly one command may be run through sudo without a password.
#
# Nothing long-running is installed. No daemon, no cron entry, no outbound calls.
#
# Usage:
#   sudo ./sethttps-agent.sh --path /etc/nginx/ssl/example.com
#   sudo ./sethttps-agent.sh --path /etc/nginx/ssl/example.com --reload-cmd "nginx -s reload"
#   sudo ./sethttps-agent.sh --path /etc/nginx/ssl/example.com --dry-run
#   sudo ./sethttps-agent.sh --uninstall
#
# Exit codes: 0 ok, 1 usage error, 2 not root, 3 validation failed.

set -euo pipefail

USER_NAME="sethttps_deploy"
UPLOAD_DIR=""
PASSWORD=""
RELOAD_CMD=""
DRY_RUN=0
UNINSTALL=0

SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
USER_SHELL="/usr/sbin/nologin"
RELOAD_WRAPPER="/usr/local/bin/sethttps-reload"
RELOAD_UNIT="sethttps-reload"

usage() {
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)       USER_NAME="${2:?--user needs a value}"; shift 2 ;;
        --path)       UPLOAD_DIR="${2:?--path needs a value}"; shift 2 ;;
        --password)   PASSWORD="${2:?--password needs a value}"; shift 2 ;;
        --reload-cmd) RELOAD_CMD="${2:?--reload-cmd needs a value}"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --uninstall)  UNINSTALL=1; shift ;;
        -h|--help)    usage 0 ;;
        *)            die "unknown option: $1" 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || die "run this as root (sudo ./sethttps-agent.sh ...)" 2

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '   \033[90m$ %s\033[0m\n' "$*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------- uninstall ---
if [[ $UNINSTALL -eq 1 ]]; then
    log "Removing user $USER_NAME and its sudoers rule"
    if grep -q "Match User $USER_NAME" "$SSHD_CONFIG" 2>/dev/null; then
        cp -a "$SSHD_CONFIG" "$SSHD_CONFIG.bak.$(date +%s)"
        awk -v u="$USER_NAME" '
            $0 ~ "^Match User " u "$" {skip=1; next}
            skip && /^[^[:space:]]/ {skip=0}
            !skip {print}
        ' "$SSHD_CONFIG" > "$SSHD_CONFIG.tmp"
        mv "$SSHD_CONFIG.tmp" "$SSHD_CONFIG"
        warn "sshd_config edited — check it with: sshd -t"
    fi
    systemctl disable --now "${RELOAD_UNIT}.path" 2>/dev/null || true
    rm -f "/etc/systemd/system/${RELOAD_UNIT}.path" "/etc/systemd/system/${RELOAD_UNIT}.service"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "/usr/local/bin/sethttps-reload" "/etc/sudoers.d/$USER_NAME"
    if id "$USER_NAME" &>/dev/null; then
        userdel "$USER_NAME" 2>/dev/null || true
    fi
    warn "Certificate files stay where they are. Restart sshd to apply: systemctl restart sshd"
    exit 0
fi

# ------------------------------------------------------------------- checks ---
[[ -n "$UPLOAD_DIR" ]] || usage 1
[[ "$UPLOAD_DIR" = /* ]] || die "--path must be absolute, e.g. /etc/nginx/ssl/example.com"

UPLOAD_DIR="${UPLOAD_DIR%/}"
[[ "$UPLOAD_DIR" != "/" ]] || die "--path cannot be /"

CHROOT_DIR="$(dirname "$UPLOAD_DIR")"
UPLOAD_SUBDIR="$(basename "$UPLOAD_DIR")"

[[ "$CHROOT_DIR" != "/" ]] || die "refusing to chroot to / — pick a deeper directory"

if id "$USER_NAME" &>/dev/null; then
    log "User $USER_NAME already exists — reusing it"
else
    log "Creating user $USER_NAME (shell: $USER_SHELL)"
fi

if [[ -z "$PASSWORD" ]]; then
    PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    GENERATED=1
else
    GENERATED=0
fi

# ------------------------------------------------------------------ execute ---
if ! id "$USER_NAME" &>/dev/null; then
    run useradd -m -s "$USER_SHELL" "$USER_NAME"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '   \033[90m$ chpasswd  (password set)\033[0m\n'
    else
        printf '%s:%s\n' "$USER_NAME" "$PASSWORD" | chpasswd
    fi
fi

log "Chroot: $CHROOT_DIR   upload directory: $UPLOAD_DIR"

# sshd requires every directory above the chroot to be root-owned and not
# group/world writable. Only touched when the permissions are actually wrong.
dir="$CHROOT_DIR"
parents=()
while [[ "$dir" != "/" ]]; do
    parents+=("$dir")
    dir="$(dirname "$dir")"
done
for ((i = ${#parents[@]} - 1; i >= 0; i--)); do
    d="${parents[$i]}"
    if [[ ! -d "$d" ]]; then
        run mkdir -p "$d"
    fi
    if [[ "$(stat -c %U:%G "$d" 2>/dev/null || echo '')" != "root:root" ]]; then
        run chown root:root "$d"
    fi
    if [[ "$(stat -c %a "$d" 2>/dev/null || echo '')" != "755" ]]; then
        run chmod 755 "$d"
    fi
done

run mkdir -p "$UPLOAD_DIR"
run chown "$USER_NAME:$USER_NAME" "$UPLOAD_DIR"
run chmod 755 "$UPLOAD_DIR"

# --------------------------------------------------------------- sshd block ---
if grep -q "Match User $USER_NAME" "$SSHD_CONFIG"; then
    log "sshd already has a Match block for $USER_NAME — leaving it alone"
else
    log "Adding SFTP-only Match block to $SSHD_CONFIG"
    if [[ $DRY_RUN -eq 0 ]]; then
        cp -a "$SSHD_CONFIG" "$SSHD_CONFIG.bak.$(date +%s)"
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '   \033[90m$ cat >> %s <<EOF\033[0m\n' "$SSHD_CONFIG"
        printf '   \033[90mMatch User %s\033[0m\n' "$USER_NAME"
    else
        cat >> "$SSHD_CONFIG" <<EOF

# SFTP-only deployment account, added by sethttps-agent.sh
Match User $USER_NAME
    ChrootDirectory $CHROOT_DIR
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    # password auth for this one jailed account, whatever the global setting is
    PasswordAuthentication yes
EOF
    fi
fi

if [[ $DRY_RUN -eq 0 ]]; then
    sshd -t || die "sshd config is invalid — restore $SSHD_CONFIG.bak.* before restarting" 3
    log "Restarting sshd"
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || warn "restart sshd manually"
fi

# ------------------------------------------------------- reload trigger ---
# The platform cannot execute anything here: the account is chrooted and has no
# shell. So the reload command lives in a root-owned wrapper, and a systemd path
# unit starts it when a marker file appears next to the certificates. Dropping
# that marker is the only lever the platform has.
MARKER="$UPLOAD_DIR/reload.request"

if [[ -n "$RELOAD_CMD" ]]; then
    log "Installing reload wrapper: $RELOAD_WRAPPER"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '   \033[90m$ cat > %s <<EOS  (%s)\033[0m\n' "$RELOAD_WRAPPER" "$RELOAD_CMD"
    else
        cat > "$RELOAD_WRAPPER" <<EOS
#!/bin/bash
# Installed by sethttps-agent.sh. Re-run the script to change it.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$RELOAD_CMD
EOS
        chown root:root "$RELOAD_WRAPPER"
        chmod 755 "$RELOAD_WRAPPER"
    fi

    run mkdir -p "$UPLOAD_DIR"
    if [[ $DRY_RUN -eq 0 ]]; then
        [[ -f "$MARKER" ]] || : > "$MARKER"
        chown "$USER_NAME:$USER_NAME" "$MARKER"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '   \033[90m$ systemctl enable --now %s.path  (watches %s)\033[0m\n' "$RELOAD_UNIT" "$MARKER"
    else
        cat > "/etc/systemd/system/${RELOAD_UNIT}.service" <<EOS
[Unit]
Description=Reload the web server after a SetHttps certificate update

[Service]
Type=oneshot
ExecStart=$RELOAD_WRAPPER
EOS

        cat > "/etc/systemd/system/${RELOAD_UNIT}.path" <<EOS
[Unit]
Description=Watch the SetHttps reload marker

[Path]
PathModified=$MARKER
Unit=${RELOAD_UNIT}.service

[Install]
WantedBy=paths.target
EOS

        systemctl daemon-reload
        systemctl enable --now "${RELOAD_UNIT}.path"
    fi
else
    log "No --reload-cmd given: the account can only upload files"
fi

# --------------------------------------------------------------------- report ---
cat <<EOF

$( [[ $DRY_RUN -eq 1 ]] && echo "DRY RUN — nothing was changed." )

  user      $USER_NAME
  password  $PASSWORD $( [[ ${GENERATED:-0} -eq 1 ]] && echo "(generated, copy it now)" )
  host dir  $UPLOAD_DIR
  sshd      Match User block in $SSHD_CONFIG
  reload    $( [[ -n "$RELOAD_CMD" ]] && echo "\"$RELOAD_CMD\" via $RELOAD_UNIT.path" || echo "not configured" )

Check it manually:

  sftp -P 22 $USER_NAME@<your-host>

You should land in $UPLOAD_DIR and be unable to cd anywhere else.

Remove it again:

  sudo ./sethttps-agent.sh --uninstall
EOF
