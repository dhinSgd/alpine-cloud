#!/usr/bin/env bash
# 阶段 5: qemu 启动测试 + 交互断言
#   - 用 qemu-system-x86_64 启动镜像
#   - 通过 expect 监控串口，等到 login 提示
#   - 自动用 root / DEFAULT_ROOT_PASSWORD 登录
#   - 跑一系列基础断言（任一失败立即非零退出）：
#       * 网络：拿到非 127.x 的 IPv4 地址
#       * sshd 进程存在
#       * cloud-init status --wait 不报 error（degraded 可接受：qemu 无 AliYun datasource）
#       * df -h / 显示 btrfs
#       * btrfs filesystem df / 不报错
#       * mount 选项含 compress=zstd 和 subvol=@
#   - 全部通过后 poweroff

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# 自定义解析：支持 --boot 和 --timeout
BOOT_TYPE=""
TIMEOUT=300
while [ $# -gt 0 ]; do
  case "$1" in
    --boot)    BOOT_TYPE="$2"; shift 2 ;;
    --boot=*)  BOOT_TYPE="${1#--boot=}"; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#--timeout=}"; shift ;;
    -h|--help)
      printf "用法: %s --boot uefi|bios [--timeout 秒数]\n" "${0##*/}"
      exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done
case "$BOOT_TYPE" in
  uefi|bios) ;;
  *) die "缺少或非法的 --boot 参数（uefi|bios）" ;;
esac
export BOOT_TYPE

load_source_env
require_cmd qemu-system-x86_64 expect

log_info "阶段 5 (test-boot) - 启动 [boot=${BOOT_TYPE}, timeout=${TIMEOUT}s]"

IMG="$OUTPUT_DIR/slim-alpine-${ALPINE_VERSION}-${BOOT_TYPE}.qcow2"
[ -f "$IMG" ] || die "未找到镜像: $IMG（先跑 04-finalize.sh）"

# 用临时副本，避免 qemu 写入污染原镜像
TEST_IMG=$(mktemp --suffix=.qcow2)
trap 'rm -f "$TEST_IMG"' EXIT
log_info "复制到测试副本: $TEST_IMG"
cp "$IMG" "$TEST_IMG"

# 定位 OVMF 固件（UEFI 必需）
OVMF_PATH=""
if [ "$BOOT_TYPE" = "uefi" ]; then
  for p in \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/ovmf/OVMF.fd \
    /usr/share/edk2/x64/OVMF.fd \
    /usr/share/edk2-ovmf/OVMF.fd
  do
    if [ -f "$p" ]; then
      OVMF_PATH="$p"
      break
    fi
  done
  [ -n "$OVMF_PATH" ] || die "未找到 OVMF 固件（请安装 ovmf 包）"
  log_info "使用 OVMF: $OVMF_PATH"
fi

# 构造 qemu 命令行
QEMU_BIN="qemu-system-x86_64"
QEMU_ARGS=(
  -name "slim-alpine-test"
  -m 1024
  -smp 2
  -cpu max
  -drive "file=$TEST_IMG,format=qcow2,if=virtio,cache=none,aio=native"
  -netdev "user,id=net0"
  -device "virtio-net-pci,netdev=net0"
  -nographic
  -serial "mon:stdio"
  -no-reboot
)
if [ "$BOOT_TYPE" = "uefi" ]; then
  QEMU_ARGS+=(-bios "$OVMF_PATH")
fi

# 启用 KVM 加速（如果可用）
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  QEMU_ARGS+=(-enable-kvm)
  log_info "启用 KVM 加速"
else
  log_warn "无 KVM 加速，启动会较慢"
fi

log_info "qemu 命令: $QEMU_BIN ${QEMU_ARGS[*]}"

# 传给 expect 的变量
QEMU_CMD="$QEMU_BIN $(printf '%q ' "${QEMU_ARGS[@]}")"
ROOT_PASS="${DEFAULT_ROOT_PASSWORD:-slimalpine123}"
export QEMU_CMD TIMEOUT ROOT_PASS

# ---------- expect 脚本 ----------
# 设计原则：
#   每条断言命令都在 shell 里执行后 `echo TAG_<n>=<状态>` 作为唯一 marker，
#   expect 只匹配该 marker，避免被命令输出干扰；同时设独立 timeout。
#   退出码：
#     0  全部通过
#     1  kernel panic
#     2  boot 超时（未见 login）
#     3  根设备/initrd 报错
#     10 网络
#     11 sshd
#     12 cloud-init
#     13 df / 不是 btrfs
#     14 btrfs filesystem df 失败
#     15 mount 选项缺 zstd / subvol=@
#     20 自动登录失败
#     99 未预期的 timeout
expect <<'EXPECT_EOF'
set boot_timeout $env(TIMEOUT)
set qemu $env(QEMU_CMD)
set rootpass $env(ROOT_PASS)

# 重要：所有发给 shell 的命令都用 tcl 大括号 {...} 包裹，
# 避免 tcl 把 bash 命令里的 [ ] 当作命令替换（典型例子：grep -E '[0-9]+'）。
# 用 send_user 显示命令本身（方便日志调试）；用 send 把命令送进 qemu。
# 命令以 \r 结尾，由 send -- "\r" 单独发送。

# 重要：marker 必须是命令"输出"才出现的字符串，不是命令"文本"里出现的字符串。
# 上一版用 `echo TAG=OK` 失败：tty 把发送的命令本身回显回来后，
# expect 立刻匹配到 TAG=OK，误判通过（cloud-init 实际还没跑完）。
# 现改用 printf 拼接：命令文本 `printf '__NET__%s__\n' OK`，
# 输出 `__NET__OK__`。命令字符串不含完整 marker，不会自匹配。

# 通用：发送一行命令到 shell（用 tcl 大括号字符串避免转义陷阱）
proc shcmd {cmd} {
  send -- $cmd
  send -- "\r"
}

# 通用：断言 marker，timeout 单独控制
proc wait_marker {tag ok_text fail_text fail_exit timeout_sec} {
  set timeout $timeout_sec
  set ok_pat   "__${tag}__OK__"
  set fail_pat "__${tag}__FAIL__"
  expect {
    -re $ok_pat {
      puts "\n✅ \[$tag\] $ok_text"
    }
    -re $fail_pat {
      puts "\n❌ \[$tag\] $fail_text"
      exit $fail_exit
    }
    timeout {
      puts "\n❌ \[$tag\] 断言超时 (${timeout_sec}s)"
      exit 99
    }
  }
}

spawn -noecho sh -c "$qemu"

# ---------- Stage 1: 等 login 提示 ----------
set timeout $boot_timeout
expect {
  -re {(localhost|alpine)?\s*login:} {
    puts "\n✅ \[boot\] 检测到 login 提示"
  }
  "Kernel panic" {
    puts "\n❌ \[boot\] Kernel panic"
    exit 1
  }
  "Cannot find root device" {
    puts "\n❌ \[boot\] 找不到根设备（grub UUID/rootfstype 配置可能错误）"
    exit 3
  }
  -re {ALERT! .* does not exist} {
    puts "\n❌ \[boot\] initrd ALERT：根设备不存在"
    exit 3
  }
  "Mounting root: failed" {
    puts "\n❌ \[boot\] initrd 挂根失败"
    exit 3
  }
  timeout {
    puts "\n❌ \[boot\] 超时未出现 login (${boot_timeout}s)"
    exit 2
  }
}

# ---------- Stage 2: 自动登录 ----------
set timeout 30
send -- "root\r"
expect {
  -re "Password:" { send -- "$rootpass\r" }
  -re {[#\$]} {
    # 极端情况下 root 无密码直接进 shell
    puts "\n✅ \[login\] 无密码直接进入"
  }
  timeout {
    puts "\n❌ \[login\] 未出现 Password 提示"
    exit 20
  }
}

# 不依赖 prompt 匹配（CSI 6n 干扰行尾）。
# 用 printf 拼接 marker 确认 shell 就绪。
set timeout 30
sleep 2
send -- "\r"
shcmd {printf '__LOGIN__%s__\n' READY}
expect {
  -re {__LOGIN__READY__} { puts "\n✅ \[login\] shell 就绪" }
  -re {incorrect|Login incorrect|authentication failure} {
    puts "\n❌ \[login\] 登录被拒绝（密码错误？）"
    exit 20
  }
  timeout {
    puts "\n❌ \[login\] 未拿到 shell marker"
    exit 20
  }
}

# 关掉历史扩展和回显抑制（ash 不支持 histexpand 但 2>/dev/null 兜底）
shcmd {set +o histexpand 2>/dev/null; export PS1=''; export PROMPT_COMMAND=''}
sleep 1

# ---------- Stage 3: 等 cloud-init 跑完 ----------
# cloud-init status --wait 阻塞直到 done/error/degraded；
# qemu 无 AliYun datasource 时通常落到 None，degraded 可接受。
# marker 在 if/else 分支由 printf 输出，命令文本本身不含 __CI__OK__
shcmd {cloud-init status --wait > /tmp/ci.out 2>&1; cat /tmp/ci.out; if grep -qE 'status: (done|degraded)' /tmp/ci.out; then printf '__CI__%s__\n' OK; else printf '__CI__%s__\n' FAIL; fi}
wait_marker "CI" "cloud-init 完成 (done 或 degraded)" \
                 "cloud-init 状态异常" 12 180

# ---------- Stage 4: 网络（IPv4） ----------
# 注意：bash 命令里的 [0-9] 用 tcl 大括号包裹后不会被 tcl 解释
shcmd {ip -4 addr show 2>/dev/null | grep -E 'inet [0-9]+\.' | grep -v '127\.0\.0\.1' > /tmp/ip.out; cat /tmp/ip.out; if [ -s /tmp/ip.out ]; then printf '__NET__%s__\n' OK; else printf '__NET__%s__\n' FAIL; fi}
wait_marker "NET" "已获取非环回 IPv4" \
                  "未获取非环回 IPv4 地址（virtio-net 或 DHCP 异常）" 10 30

# ---------- Stage 5: sshd 进程 ----------
shcmd {if pgrep -x sshd > /dev/null; then printf '__SSHD__%s__\n' OK; else printf '__SSHD__%s__\n' FAIL; fi}
wait_marker "SSHD" "sshd 进程存在" \
                   "sshd 进程未运行" 11 15

# ---------- Stage 6: df -h / 是 btrfs ----------
shcmd {df -hT / | tail -n+2 > /tmp/df.out; cat /tmp/df.out; if awk '{print $2}' /tmp/df.out | grep -qx btrfs; then printf '__DF__%s__\n' OK; else printf '__DF__%s__\n' FAIL; fi}
wait_marker "DF" "/ 是 btrfs" \
                 "/ 不是 btrfs（fstab 或挂载错误）" 13 15

# ---------- Stage 7: btrfs filesystem df ----------
shcmd {if btrfs filesystem df / > /tmp/bfs.out 2>&1; then printf '__BFS__%s__\n' OK; else printf '__BFS__%s__\n' FAIL; fi; cat /tmp/bfs.out}
wait_marker "BFS" "btrfs filesystem df 正常" \
                   "btrfs filesystem df 失败" 14 15

# ---------- Stage 8: mount option（zstd + subvol=@） ----------
shcmd {mount | grep ' on / type btrfs' > /tmp/mnt.out; cat /tmp/mnt.out; if grep -qE 'compress(-force)?=zstd' /tmp/mnt.out && grep -q 'subvol=/@' /tmp/mnt.out; then printf '__MNT__%s__\n' OK; else printf '__MNT__%s__\n' FAIL; fi}
wait_marker "MNT" "btrfs 挂载选项含 zstd 压缩 + subvol=@" \
                   "btrfs 挂载选项缺 zstd 或 subvol=@" 15 15

# ---------- 全部通过 ----------
puts "\n========================================"
puts "✅ 所有 boot 断言全部通过"
puts "========================================"

# 优雅关机（避免 qemu 残留）
set timeout 30
send -- "poweroff\r"
expect {
  eof { puts "\n✅ qemu 已关闭" }
  -re "Power down" { puts "\n✅ 系统已请求关机" }
  timeout { puts "\n⚠️ poweroff 后 30s 未结束，强制退出" }
}
exit 0
EXPECT_EOF
EXPECT_RC=$?

if [ $EXPECT_RC -ne 0 ]; then
  die "启动测试失败（expect rc=$EXPECT_RC）"
fi

log_ok "阶段 5 (test-boot) 完成 - 所有断言通过"
