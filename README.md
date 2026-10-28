# sethttps-agent

A 120-line shell script that creates a **chrooted, SFTP-only** account so a certificate
platform can drop TLS files on your server — and do nothing else.

This is the script [SetHttps](https://sethttps.com) generates for every deploy node.
It is published here so you can read it before you run it.

```
sudo ./sethttps-agent.sh --path /etc/nginx/ssl/example.com
```

---

## What it actually does

| Step | Effect |
| --- | --- |
| `useradd -m -s /usr/sbin/nologin` | Creates a user that cannot log in to a shell |
| `chpasswd` | Sets the SFTP password (generated if you don't pass one) |
| `ChrootDirectory <dir>` | The account is jailed to one directory |
| `ForceCommand internal-sftp` | Only the SFTP subsystem is allowed |
| `AllowTcpForwarding no` etc. | No tunnels, no X11, no port forwarding |
| `mkdir` + `chown` | Creates the upload directory and hands it to that user |
| `PasswordAuthentication yes` | Only for this one jailed account, whatever the global setting is |
| optional `sethttps-reload.path` | A systemd path unit that runs your reload command when a marker file changes |

Nothing keeps a process alive. There is no daemon, no cron job, no outbound
connection, no telemetry. The reload is a **one-shot** systemd service that fires
only when the platform drops `reload.request` next to the certificates.

What remains on the box: one user, six lines in `sshd_config`, one directory, one
root-owned wrapper script, and two small systemd units — all removable with
`--uninstall`.

## How the reload happens

The account cannot execute anything — it is chrooted and has no shell. So the
reload is event-driven, not command-driven:

1. `--reload-cmd "nginx -s reload"` is written into `/usr/local/bin/sethttps-reload`
   (root-owned, 755).
2. A systemd path unit watches `<cert dir>/reload.request`.
3. The platform uploads the certificate, then drops that marker file.
4. systemd starts the one-shot service, which runs the wrapper as root.

The platform can therefore only ever *ask* for a reload. It cannot choose what
runs, cannot open a shell, and cannot read the command's output.

## What it does **not** do

- It does not install an agent, a package, or a long-running service.
- It does not touch your web server configuration.
- It does not open a port or change your firewall.
- It does not give the account a shell — `nologin`, always.

## Requirements

- Linux with OpenSSH (systemd assumed for the restart; everything else is portable)
- root
- An absolute target directory that already makes sense for your web server,
  e.g. `/etc/nginx/ssl/example.com`

## Usage

```bash
# 1. preview every change first — this is the important one
sudo ./sethttps-agent.sh --path /etc/nginx/ssl/example.com --dry-run

# 2. apply it
sudo ./sethttps-agent.sh --path /etc/nginx/ssl/example.com

# 3. allow one reload command (optional but recommended)
sudo ./sethttps-agent.sh --path /etc/nginx/ssl/example.com --reload-cmd "nginx -s reload"

# other options
--user NAME        account name, default sethttps_deploy
--password PASS    use a known password instead of a generated one
--uninstall        remove the user, the sshd block, the units and the wrapper
```

Typical output:

```
==> Creating user sethttps_deploy (shell: /usr/sbin/nologin)
==> Chroot: /etc/nginx/ssl   upload directory: /etc/nginx/ssl/example.com
==> Adding SFTP-only Match block to /etc/ssh/sshd_config
==> Allowing exactly one passwordless command: nginx -s reload

  user      sethttps_deploy
  password  8Xk2mQ...   (generated, copy it now)
  host dir  /etc/nginx/ssl/example.com
```

## Verify it yourself

```bash
# you should land inside the upload dir and be unable to cd out of it
sftp sethttps_deploy@your-host

# the account must not have a shell
getent passwd sethttps_deploy | cut -d: -f7      # /usr/sbin/nologin

# what was added to sshd
grep -A6 "Match User sethttps_deploy" /etc/ssh/sshd_config

# what the reload will run
cat /usr/local/bin/sethttps-reload
```

## Uninstall

```bash
sudo ./sethttps-agent.sh --uninstall
```

Removes the account, the `Match` block, both systemd units and the wrapper. Your
certificate files stay where they are. Backups of `sshd_config` are written next to it with a
`.bak.<timestamp>` suffix before any edit.

## Files it touches

```
/etc/passwd, /etc/shadow      via useradd/chpasswd
/etc/ssh/sshd_config          one appended Match block (backed up first)
/usr/local/bin/sethttps-reload  only with --reload-cmd
/etc/systemd/system/sethttps-reload.{path,service}  only with --reload-cmd
<path>/reload.request         the marker the platform writes
<path>                        the upload directory
```

## FAQ

**Why a password and not an SSH key?**
The hosted service currently authenticates over SFTP with a password. The blast
radius is still small because the account cannot get a shell and cannot leave one
directory. Key-based deployment is on the roadmap; the script and the platform
would both need to change together.

**Can this account read my private keys?**
It can write into the upload directory; that is how certificates arrive. If you
store other secrets in the same directory, move them out — the chroot is not a
permission boundary for files inside it.

**Can I run this on multiple servers?**
Yes, one account per server. The same script is idempotent: running it twice with
the same `--path` changes nothing.

**Why is it not a Go binary / daemon?**
Because then you would have to trust a binary, and a daemon is a permanent
attack surface. A script you can read in two minutes plus a one-shot systemd unit
is the smallest thing that actually works.

## License

MIT. See [LICENSE](LICENSE).

## Hosted service

This script exists because [SetHttps](https://sethttps.com) issues Let's Encrypt
wildcard certificates over DNS-01 and uploads them to your servers. The platform is
closed source; the part that touches your machine is not.

---

# 中文说明

这是一个约 120 行的 shell 脚本，用来在服务器上创建一个**只允许 SFTP、被 chroot 限制**的账号，
让证书平台把证书文件放进来——除此之外什么都做不了。

线上服务 [SetHttps](https://sethttps.com) 为每个部署节点生成的就是这个脚本。
放在这里，是为了让你在 `sudo` 之前能先读完它。

## 它做了什么

- 建一个 shell 为 `/usr/sbin/nologin` 的用户（无法登录终端）
- 用 `chroot` 把该用户限制在一个目录里
- 只保留 SFTP，关闭端口转发、X11、隧道
- 创建上传目录并交给这个用户
- 可选：装一个 systemd path 单元，监听 `reload.request`，文件变动时以 root 执行你的 reload 命令

没有任何常驻进程。reload 是一次性的 systemd 服务，只在平台丢下 marker 文件时触发，
平台无法自己决定执行什么、也拿不到命令输出。

跑完之后机器上多了：一个用户、`sshd_config` 里几行、一个目录、一个 root 所有的包装脚本，
以及两个 systemd 单元——`--uninstall` 可以全部撤掉。

## 用法

```bash
# 先预览，确认它要改什么
sudo ./sethttps-agent.sh --path /etc/nginx/ssl/example.com --dry-run

# 确认后执行
sudo ./sethttps-agent.sh --path /etc/nginx/ssl/example.com --reload-cmd "nginx -s reload"

# 卸载
sudo ./sethttps-agent.sh --uninstall
```

## 自己验证

```bash
sftp sethttps_deploy@your-host                      # 应该落在上传目录里，且出不去
getent passwd sethttps_deploy | cut -d: -f7         # 应该是 /usr/sbin/nologin
grep -A6 "Match User sethttps_deploy" /etc/ssh/sshd_config
cat /usr/local/bin/sethttps-reload              # 重载时会执行的命令
systemctl status sethttps-reload.path           # 触发器是否在监听
```

## 常见问题

**为什么是密码不是密钥？** 线上服务目前用密码走 SFTP。账号拿不到 shell、也出不了那个目录，
所以影响面有限。改用密钥需要脚本和平台一起改。

**为什么不做成二进制 / 常驻服务？** 因为那样你就得信任一个你看不懂的文件，而常驻进程是永久攻击面。
一个两分钟能读完的脚本 + 一个一次性 systemd 单元，是能跑通的最小方案。
