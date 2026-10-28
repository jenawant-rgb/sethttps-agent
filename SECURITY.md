# Security model

This repository exists so you can audit what runs on your server before you run it.
This file describes the boundary, not a promise.

## The account

`sethttps-agent.sh` creates one local account (default `sethttps_deploy`) with:

| Property | Value | Consequence |
| --- | --- | --- |
| Shell | `/usr/sbin/nologin` | Cannot start a shell, cannot log in interactively |
| Chroot | one directory (`dirname` of `--path`) | Cannot read anything outside it via SFTP |
| Subsystem | `ForceCommand internal-sftp` | Only file transfer; no `scp -O`, no exec |
| Forwarding | `AllowTcpForwarding no`, `X11Forwarding no`, `PermitTunnel no` | Cannot pivot into your network |
| Sudo | none by default; one exact command with `--reload-cmd` | Worst case is a reload of your web server |

## What an attacker with the password could do

- Upload, overwrite and delete **files inside the upload directory**.
- If `--reload-cmd` is set: run that exact command as root.
- Nothing else. No shell, no other paths, no network pivot.

## What it cannot do

- Read `/etc/shadow`, your private SSH keys, or other sites' certificates
  (they are outside the chroot).
- Install packages, add cron entries, or open ports.
- Persist: killing the account removes access immediately.

## Hardening suggestions

1. Point `--path` at a directory that contains **only** certificates.
2. Prefer a reload command with a narrow scope (`nginx -s reload`,
   `systemctl reload nginx`) over a wrapper script.
3. Rotate the SFTP password when a server changes hands; or delete the node in the
   platform and run `--uninstall`.
4. Keep `sshd_config` under configuration management — the script appends a
   `Match` block and writes a `.bak.<timestamp>` copy first.

## Reporting a vulnerability

Email `support@sethttps.com` with the script version and a description. Please do
not open a public issue for anything that could be used to attack a running
installation.
