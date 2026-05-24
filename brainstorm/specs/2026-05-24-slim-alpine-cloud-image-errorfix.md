# Slim Alpine Cloud Image - 错误修复记录

**日期**：2026-05-24  
**项目名**：alpine-cloud  
**目标**：记录 boot test 交互式断言实现过程中遇到的所有错误及修复方案

---

## 1. 概述

在实现 boot test 交互式断言（8 项：boot/login/cloud-init/网络/sshd/df/btrfs filesystem df/mount 选项）过程中，遇到了一系列技术难题。本文档按时间顺序记录每个错误的现象、根因分析、修复方案及验证结果。

**关键 CI runs：**
- ✅ 26366440518 - 首次全绿（仅 GRUB/initramfs 修复，无交互断言）
- ❌ 26366804834 - 交互断言首版，exit 20（登录后 prompt 匹配失败）
- ❌ 26366915678 - marker 误匹配 + tcl 语法错误
- ❌ 26367062132 - 前 5 项过，sshd 失败（无 host key）
- ❌ 26367141035 - host key 已生成，sshd 仍未运行
- ❌ 26367237977 - 同上（retry 30s 后仍无进程）
- ❌ 26367321235 - rc-status 显示 started，但 pgrep -x 抓不到
- ✅ 26367414409 - 全绿，所有 8 项断言通过

---

## 2. 错误 #1：登录后 prompt 匹配失败

### 2.1 现象

**CI run**: 26366804834  
**退出码**: 20  
**日志片段**:
```
localhost:~# [6n
```

expect 脚本等待 prompt 的正则 `[#$]\s*$` 超时未匹配，但日志明确显示 `localhost:~#` 已出现。

### 2.2 根因分析

Alpine 登录后某进程（可能是 readline 或 shell）发送 ANSI 转义序列 **CSI 6n**（cursor position query），导致实际输出为：
```
localhost:~# [6n
```

`#` 后面不是换行而是 `[6n`，正则 `[#$]\s*$` 匹配行尾失败。

### 2.3 修复方案

**commit**: eb9cced  
**策略**: 不再依赖 prompt 字符匹配，改用 **marker 命令**确认 shell 就绪。

```tcl
# 登录密码后直接发 marker 命令
send "\r"
send "echo SHELL_READY=\$?\r"
expect {
  -re "SHELL_READY=0" { puts "shell 就绪" }
  timeout { exit 20 }
}
```

### 2.4 验证结果

下一 run 登录阶段通过，但暴露新问题（见错误 #2）。

---

## 3. 错误 #2：marker 字面量被 tty 回显误匹配

### 3.1 现象

**CI run**: 26366915678  
**退出码**: 1（tcl 语法错误）+ marker 误匹配  
**日志片段**:
```
cloud-init status --wait > /tmp/ci.out 2>&1; cat /tmp/ci.out; if grep -qE 'status: (done|degraded)' /tmp/ci.out; then echo CI=OK; else echo CI=FAIL; fi
```

命令文本在 tty 回显后，`echo CI=OK` 字面量立刻被 expect `-re "CI=OK"` 匹配，cloud-init 实际还没跑完就误判通过。

同时报错：
```
invalid command name "0-9"
```

### 3.2 根因分析

**问题 1：marker 自匹配**  
`send "...echo CI=OK..."` 命令文本在 tty 回显时就包含 `CI=OK`，expect 立刻匹配成功。

**问题 2：tcl 命令替换**  
`send "ip ... | grep -E 'inet [0-9]+...'"` 在 tcl 双引号字符串里，`[0-9]` 被解释为 tcl 命令替换（调用命令 `0-9`），报错。

### 3.3 修复方案

**commit**: 002da6a  
**策略**:
1. marker 用 `printf` 拼接，命令文本不含完整 marker
2. 所有命令改用 tcl 大括号 `{...}` 字符串（不做替换）

```tcl
# 新 marker 格式
proc shcmd {cmd} {
  send -- $cmd
  send -- "\r"
}

# cloud-init 断言
shcmd {cloud-init status --wait > /tmp/ci.out 2>&1; cat /tmp/ci.out; if grep -qE 'status: (done|degraded)' /tmp/ci.out; then printf '__CI__%s__\n' OK; else printf '__CI__%s__\n' FAIL; fi}

# wait_marker 匹配 __CI__OK__
proc wait_marker {tag ok_text fail_text fail_exit timeout_sec} {
  set ok_pat   "__${tag}__OK__"
  set fail_pat "__${tag}__FAIL__"
  expect {
    -re $ok_pat { puts "✅ [$tag] $ok_text" }
    -re $fail_pat { exit $fail_exit }
    timeout { exit 99 }
  }
}
```

### 3.4 验证结果

tcl 语法错误消失，前 5 项断言（boot/login/CI/NET）通过，sshd 失败（见错误 #3）。

---

## 4. 错误 #3：sshd 进程未运行（无 host key）

### 4.1 现象

**CI run**: 26367062132  
**退出码**: 11（sshd 断言失败）  
**诊断输出**:
```
--- sshd 诊断 ---
-rw-r--r--    1 root     root          3489 May 24 16:52 sshd_config
drwxr-xr-x    1 root     root             0 Apr 17 16:59 sshd_config.d
__SSHD__FAIL__
```

`/etc/ssh/` 完全没有 host key（`ssh_host_*`）。

### 4.2 根因分析

02-customize.sh 原设计：
```bash
# SSH host key（首启重建）
rm -f "$ROOTFS"/etc/ssh/ssh_host_*
```

期望 cloud-init 首启时由 `ssh` 模块（默认 `ssh_deletekeys: true`）重新生成，但 qemu 环境下 cloud-init 跑完后 host key 仍未出现，sshd init 脚本因缺 key 启动失败。

### 4.3 修复方案

**commit**: ca96e92  
**策略**: build 阶段预生成 host key，云端部署时由 cloud-init 重新生成保证唯一性。

```bash
# SSH host key
# 设计：build 阶段预生成一份，保证 qemu 启动测试时 sshd 能立刻起；
# 部署到云上时由 cloud-init 的 ssh 模块（默认 ssh_deletekeys: true）
# 在首启时删除并重生成，保证每台实例 host key 唯一。
rm -f "$ROOTFS"/etc/ssh/ssh_host_*
log_info "预生成 SSH host key（chroot ssh-keygen -A）"
chroot "$ROOTFS" /usr/bin/ssh-keygen -A
```

### 4.4 验证结果

下一 run host key 全部生成（ecdsa/ed25519/rsa），但 sshd 仍未运行（见错误 #4）。

---

## 5. 错误 #4：sshd 已启动但 pgrep -x 匹配不到

### 5.1 现象

**CI run**: 26367237977, 26367321235  
**退出码**: 11  
**诊断输出**:
```
--- rc-status (default) ---
Runlevel: default
 sshd                                                  [  started  ]

--- /var/log/messages tail ---
May 24 17:01:52 localhost auth.info sshd[2323]: Server listening on 0.0.0.0 port 22.
```

rc-status 显示 `sshd [started]`，日志也有 `sshd[2323]: Server listening`，但 `pgrep -x sshd` 返回空。

### 5.2 根因分析

`pgrep -x` 要求进程名**精确匹配**。Alpine sshd 进程名可能是全路径 `/usr/sbin/sshd`，不是单纯的 `sshd`。

验证：
```bash
# pgrep -x sshd  → 空
# pgrep sshd     → 2323
# pidof sshd     → 2323
```

### 5.3 修复方案

**commit**: a9508b2  
**策略**: 改用 `pidof sshd`（更宽松，匹配 `/usr/sbin/sshd`）。

```tcl
shcmd {i=0; while [ $i -lt 30 ]; do pidof sshd > /dev/null && break; sleep 1; i=$((i+1)); done; if pidof sshd > /dev/null; then printf '__SSHD__%s__\n' OK; else echo "=== sshd 诊断 ==="; pidof sshd 2>&1 || echo "无进程"; pgrep sshd 2>&1 || echo "无进程"; ps aux | grep '[s]shd' 2>&1 || true; printf '__SSHD__%s__\n' FAIL; fi}
```

### 5.4 验证结果

✅ CI run 26367414409 全绿，所有 8 项断言通过。

---

## 6. 最终方案总结

### 6.1 核心修复

| 问题 | 根因 | 修复 | commit |
|------|------|------|--------|
| 登录 prompt 匹配失败 | CSI 6n 干扰行尾 | 用 marker 命令替代 prompt 匹配 | eb9cced |
| marker 误匹配 | tty 回显命令文本含 marker | `printf '__TAG__%s__\n' OK` 拼接 | 002da6a |
| tcl 语法错误 | `[0-9]` 被当命令替换 | 所有命令用 `{...}` 大括号字符串 | 002da6a |
| sshd 无 host key | 期望 cloud-init 生成但未生效 | build 阶段预生成 `ssh-keygen -A` | ca96e92 |
| pgrep -x 匹配失败 | 进程名是全路径 `/usr/sbin/sshd` | 改用 `pidof sshd` | a9508b2 |

### 6.2 expect 脚本设计原则

1. **marker 模式**：命令输出唯一 marker，命令文本不含完整 marker
2. **tcl 大括号**：所有 bash 命令用 `{...}` 包裹，避免 tcl 解释
3. **独立 timeout**：每个断言单独设 timeout，失败时精确定位
4. **retry 机制**：sshd 等异步服务用 while 循环 retry 30s
5. **诊断输出**：失败时打印完整诊断（rc-status / pidof / ps / 日志）

### 6.3 最终 8 项断言

| # | 断言项 | 验证内容 | timeout |
|---|--------|----------|---------|
| 1 | boot | 检测到 `login:` 提示 | 300s |
| 2 | login | shell marker `__LOGIN__READY__` | 30s |
| 3 | CI | `cloud-init status` 含 done/degraded | 180s |
| 4 | NET | 非环回 IPv4 地址（`ip -4 addr`） | 30s |
| 5 | SSHD | `pidof sshd` 有进程（retry 30s） | 45s |
| 6 | DF | `df -hT /` 显示 btrfs | 15s |
| 7 | BFS | `btrfs filesystem df /` 不报错 | 15s |
| 8 | MNT | mount 含 `compress=zstd` + `subvol=/@` | 15s |

---

## 7. 验证结果

### 7.1 CI run 26367414409（全绿）

**时间**: 2026-05-24 17:03-17:06  
**结果**: ✅ 所有 8 项断言通过  
**Release**: v3.23.4-slim-20260524-170609

**日志摘要**:
```
✅ [boot] 检测到 login 提示
✅ [login] shell 就绪
✅ [CI] cloud-init 完成 (done 或 degraded)
✅ [NET] 已获取非环回 IPv4
✅ [SSHD] sshd 进程存在
✅ [DF] / 是 btrfs
✅ [BFS] btrfs filesystem df 正常
✅ [MNT] btrfs 挂载选项含 zstd 压缩 + subvol=@
✅ 所有 boot 断言全部通过
✅ 系统已请求关机
```

### 7.2 关键指标

- **Build 时间**: 1m4s
- **Boot Test 时间**: 1m10s
- **总耗时**: 约 3 分钟（含 Release 发布）
- **镜像大小**: slim-alpine-3.23.4-uefi.qcow2

---

## 8. 经验教训

### 8.1 expect 脚本陷阱

1. **tty 回显污染**：任何 send 的命令都会被回显，marker 必须是输出而非命令文本
2. **tcl 字符串替换**：双引号字符串会做 `$var` / `[cmd]` / `\` 替换，bash 命令必须用 `{...}`
3. **prompt 匹配脆弱**：ANSI 转义序列（CSI 6n / 颜色码）会干扰行尾匹配，marker 更可靠
4. **进程名匹配**：`pgrep -x` 要求精确匹配，`pidof` / `pgrep`（无 -x）更宽松

### 8.2 cloud-init 行为

- qemu 环境下 `ssh_deletekeys` 可能不生效（无 datasource 时行为不确定）
- 保险做法：build 阶段预生成 host key，云端由 cloud-init 重新生成

### 8.3 调试策略

1. **分阶段验证**：先过 boot/login，再逐项加断言
2. **完整诊断**：失败时打印 rc-status / pidof / ps / 日志，避免盲猜
3. **本地语法检查**：用 `expect -c 'source script.exp'` 预检 tcl 语法
4. **CI 日志精读**：tty 回显 + ANSI 转义会让日志难读，需耐心定位

---

## 9. 附录：相关 commits

| commit | 描述 | 文件 |
|--------|------|------|
| eb9cced | 登录后用 marker 命令替代 prompt 匹配 | 05-test-boot.sh |
| 002da6a | marker 改用 printf 拼接 + tcl 大括号字符串 | 05-test-boot.sh |
| 5c65ac9 | sshd 断言加 30s retry + 失败时打印诊断 | 05-test-boot.sh |
| ca96e92 | build 阶段预生成 SSH host key | 02-customize.sh |
| 65984d0 | sshd 诊断扩展（rc-status / 手动 start / 系统日志） | 05-test-boot.sh |
| a9508b2 | sshd 检测改用 pidof（pgrep -x 匹配不到） | 05-test-boot.sh |

---

**文档版本**: 1.0  
**最后更新**: 2026-05-24 17:10
