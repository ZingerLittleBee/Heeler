<!-- Translated from docs/guides/selinux.md at ed1e9e66 -->
# Fedora 或 RHEL 主机上的 SELinux

在 Fedora、RHEL、CentOS Stream、AlmaLinux 和 Rocky Linux 上，SELinux 可能会阻止 SSH 打开 herdr 的 socket。此时即使 herdr 正在运行，Heeler 也会报告无法打开 socket。本指南说明如何确认这一拒绝并放行。

## 现象

连接检查会在 **herdr server running** 处失败，并显示：

> Could not open the herdr socket at /home/&lt;user&gt;/.config/herdr/herdr.sock.
> Start herdr on the Host, or enable SSH stream-local forwarding and run the
> checks again.

该提示列出了两个原因，但它们都不是这里的问题：herdr 正在运行，而且 OpenSSH 默认就允许 stream-local forwarding。

## 确认是 SELinux

确认 SELinux 处于 enforcing 模式，并且 socket 正在监听：

```bash
getenforce
herdr status
ss -xl | grep herdr.sock
```

`getenforce` 会输出 `Enforcing`，socket 会显示为 `LISTEN`。然后查找最近的拒绝记录：

```bash
journalctl --since "10 min ago" | grep -i 'avc.*herdr.sock'
```

在 Fedora 44 上，匹配的记录类似下面这样：

```text
avc: denied { write } for comm="sshd-session" name="herdr.sock"
  scontext=system_u:system_r:sshd_session_t:s0
  tcontext=unconfined_u:object_r:config_home_t:s0 tclass=sock_file
sshd-session: error: connect to /home/<user>/.config/herdr/herdr.sock port -2 failed: Permission denied
```

在所有发行版上，目标类型都是 `config_home_t`，类别都是 `sock_file`；但 `scontext` 中的源域并不相同：Fedora 和 RHEL 10 报告 `sshd_session_t`，而 RHEL 9 及其衍生版本使用的是更早的策略，并未定义该类型。请不要照搬本指南里的域，而应以你日志中实际出现的拒绝为准，参见[放行](#放行)。

## 原因

Heeler 不会通过执行 shell 命令来访问 herdr，而是请求 SSH 建立 **direct-streamlocal** 通道，因此由 `sshd` 自身对 herdr 的 socket 调用 `connect()`：默认会话使用 `~/.config/herdr/herdr.sock`，命名会话使用 `~/.config/herdr/sessions/<name>/herdr.sock`。

该 sshd 工作进程只能连接其 SELinux 域被允许写入的 socket。`~/.config` 下的文件标记为 `config_home_t`，而 targeted 策略没有授予 SSH 会话对这类 socket 的写入权限。连接 Unix socket 需要对 socket 文件具有 `write` 权限，因此内核拒绝了该操作。

这不是文件权限问题。socket 的所有者与 SSH 会话登录的账户相同，因此登录和其他所有 SSH 请求都能成功，只有打开 socket 这一步失败。

## 放行

最可靠的做法是让 `audit2allow` 根据你自己审计日志中的拒绝记录生成策略模块。它会从 AVC 中读取源域，因此同一组命令在 Fedora、RHEL 9、RHEL 10 及其衍生版本上都能使用。

```bash
sudo dnf install policycoreutils-python-utils
sudo ausearch -m AVC -ts recent | sudo audit2allow -M herdr_sshd_streamlocal
sudo semodule -i herdr_sshd_streamlocal.pp
```

执行完成后，在 Heeler 中重新运行连接检查。

### 仅适用于 Fedora 和 RHEL 10：手动编写模块

如果你不想安装 `policycoreutils-python-utils`，也可以显式编写模块。下面这个版本使用了 `sshd_session_t`，该类型存在于 Fedora 和 RHEL 10，但在 RHEL 9 及其衍生版本中不存在，安装时会报错 `type sshd_session_t is not defined`。在这些系统上请改用上面的 `audit2allow` 方式。

```bash
sudo dnf install checkpolicy policycoreutils

cat > herdr-sshd-selinux.te <<'EOF'
module herdr_sshd_streamlocal 1.0;

require {
    type sshd_session_t;
    type config_home_t;
    class sock_file write;
}

# Let an SSH session connect to herdr's Unix socket under ~/.config/herdr.
allow sshd_session_t config_home_t:sock_file write;
EOF

checkmodule -M -m -o herdr-sshd-selinux.mod herdr-sshd-selinux.te
semodule_package -o herdr-sshd-selinux.pp -m herdr-sshd-selinux.mod
sudo semodule -i herdr-sshd-selinux.pp
```

这两种模块都不会禁用 SELinux，也不会授予 shell 访问权限：SSH 会话仍然需要相同的账户和文件权限。

## 验证

```bash
sudo semodule -l | grep herdr_sshd_streamlocal
journalctl --since "2 min ago" | grep herdr.sock
```

第一条命令会输出该模块。重新运行检查后，第二条命令不应输出任何内容；安装之前的拒绝记录仍会保留在更早的日志中。

## 撤销

```bash
sudo semodule -r herdr_sshd_streamlocal
```

移除模块后，新的连接会再次被拒绝。已打开的 pane 不受影响。

## 适用范围

- 该规则覆盖 `config_home_t`，即 SELinux 赋予 `~/.config` 的标签。如果把 herdr 的 socket 移到其他位置，则需要为其单独设置标签和规则。
- macOS Host，以及未启用 SELinux 的 Linux Host（Debian、使用 AppArmor 的 Ubuntu，或禁用了 SELinux 的 Fedora）无需任何更改。如果 `getenforce` 输出 `Disabled` 或 `Permissive`，则本指南不适用。
- 该模块在重启和 herdr 更新后仍然有效。只有在系统大版本升级后再次出现该拒绝时，才需要重新安装。
