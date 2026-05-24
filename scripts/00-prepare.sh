#!/usr/bin/env bash
# 阶段 0: 准备构建环境
#   - 安装系统依赖
#   - 下载 Alpine 官方 cloud 镜像（UEFI）
#   - 校验 SHA512（从官方 .sha512 文件获取期望值）

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

parse_args "$@"
require_root
load_source_env

log_info "阶段 0 (prepare) - 启动 [boot=${BOOT_TYPE}]"

# ---------- 1. 安装构建依赖 ----------

# GitHub Actions runner 是 Ubuntu，apt-get 总是可用。
# 若已安装则 apt-get install 是幂等的，不增加耗时。
if command -v apt-get >/dev/null 2>&1; then
  log_info "安装构建依赖（apt-get）"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    qemu-utils \
    qemu-system-x86 \
    libguestfs-tools \
    btrfs-progs \
    rsync \
    parted \
    kpartx \
    dosfstools \
    ovmf \
    expect \
    fdisk \
    util-linux \
    ca-certificates \
    wget \
    coreutils
else
  log_warn "未检测到 apt-get（非 Debian/Ubuntu 环境），跳过依赖安装步骤；请自行确保下列命令存在"
  require_cmd qemu-img wget sha512sum sfdisk losetup blkid mkfs.btrfs rsync chroot
fi

# ---------- 2. 选择 UEFI 镜像 URL ----------

IMAGE_FILE="$UEFI_IMAGE_FILE"
IMAGE_URL="$UEFI_IMAGE_URL"
IMAGE_SHA512_URL="$UEFI_IMAGE_SHA512_URL"

# ---------- 3. 下载 + 校验 ----------

SRC_DIR="$BUILD_DIR/source"
ensure_dir "$SRC_DIR"

IMAGE_PATH="$SRC_DIR/$IMAGE_FILE"
SHA512_PATH="$SRC_DIR/${IMAGE_FILE}.sha512"

log_info "下载镜像: $IMAGE_URL"
log_info " -> $IMAGE_PATH"
wget -q --show-progress --tries=3 --timeout=60 \
  -O "$IMAGE_PATH" "$IMAGE_URL"

log_info "下载 SHA512 校验文件: $IMAGE_SHA512_URL"
wget -q --show-progress --tries=3 --timeout=30 \
  -O "$SHA512_PATH" "$IMAGE_SHA512_URL"

log_info "校验 SHA512"
# Alpine 官方 .sha512 内容仅是 hex 字符串（无文件名），不能直接 sha512sum -c
EXPECTED=$(tr -d '[:space:]' < "$SHA512_PATH")
[ ${#EXPECTED} -ge 128 ] || die "SHA512 文件内容异常: $SHA512_PATH"
ACTUAL=$(sha512sum "$IMAGE_PATH" | awk '{print $1}')
if [ "$EXPECTED" != "$ACTUAL" ]; then
  log_error "SHA512 不匹配"
  log_error "  期望: $EXPECTED"
  log_error "  实际: $ACTUAL"
  exit 1
fi
log_ok "SHA512 校验通过"

log_ok "镜像就绪: $(stat -c '%s %n' "$IMAGE_PATH")"
log_ok "阶段 0 (prepare) 完成"
