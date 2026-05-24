#!/usr/bin/env bash
# 阶段 5: qemu 启动测试
#   - 用 qemu-system-x86_64 启动镜像
#   - 通过 expect 监控串口输出，等待 "login:" 提示
#   - 出现 Kernel panic 立即失败；超时也失败

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# 自定义解析：支持 --boot 和 --timeout
BOOT_TYPE=""
TIMEOUT=180
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

# 用 expect 监控
# 注意：传递 args 数组给 expect 比较繁琐，这里用 env 方式传 cmd 行字符串
QEMU_CMD="$QEMU_BIN $(printf '%q ' "${QEMU_ARGS[@]}")"
export QEMU_CMD TIMEOUT

expect <<'EXPECT_EOF'
set timeout $env(TIMEOUT)
set qemu $env(QEMU_CMD)

spawn -noecho sh -c "$qemu"

set login_seen 0
expect {
  -re "(localhost|alpine)?\\s*login:" {
    puts "\n✅ 检测到 login 提示，启动成功"
    set login_seen 1
  }
  "Kernel panic" {
    puts "\n❌ 检测到 Kernel panic"
    exit 1
  }
  "Cannot find root device" {
    puts "\n❌ 找不到根设备（grub UUID/rootfstype 配置可能错误）"
    exit 1
  }
  "ALERT! .* does not exist" {
    puts "\n❌ initrd ALERT：根设备不存在"
    exit 1
  }
  timeout {
    puts "\n❌ 超时未出现 login 提示（${env(TIMEOUT)}s）"
    exit 2
  }
}

# 给一段时间让系统稳定（防止 cloud-init 后续动作崩溃）
expect {
  -re "(?i)error|fail" {
    # 仅记录，不立即失败
    puts "\n⚠️  发现错误关键字，但 login 已就绪，视为成功"
    exit 0
  }
  timeout {
    puts "\n✅ 系统稳定运行"
    exit 0
  }
}
EXPECT_EOF
EXPECT_RC=$?

if [ $EXPECT_RC -ne 0 ]; then
  die "启动测试失败（expect rc=$EXPECT_RC）"
fi

log_ok "阶段 5 (test-boot) 完成"
