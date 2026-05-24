#!/usr/bin/env bash
# 阶段 1: 从官方 qcow2 提取 rootfs
#   - 转 raw 后通过 losetup 挂载
#   - 动态识别根分区（不依赖固定分区号）
#   - rsync 拷贝 rootfs 到 build/rootfs-{boot}/
#   - 记录分区表与根分区/ESP 编号供阶段 3 复用

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/disk-utils.sh
source "$SCRIPT_DIR/lib/disk-utils.sh"

parse_args "$@"
require_root
load_source_env

log_info "阶段 1 (extract) - 启动 [boot=${BOOT_TYPE}]"

IMAGE_FILE="$UEFI_IMAGE_FILE"

SRC_DIR="$BUILD_DIR/source"
QCOW2_SRC="$SRC_DIR/$IMAGE_FILE"
RAW_SRC="$SRC_DIR/source-${BOOT_TYPE}.raw"
ROOTFS="$BUILD_DIR/rootfs-${BOOT_TYPE}"
MOUNT_DIR="$BUILD_DIR/mnt-${BOOT_TYPE}"

[ -f "$QCOW2_SRC" ] || die "源镜像不存在: $QCOW2_SRC（先跑 00-prepare.sh）"

# 清理可能残留的 rootfs（重跑时）
if [ -d "$ROOTFS" ]; then
  log_warn "清理已存在的 rootfs 目录: $ROOTFS"
  rm -rf "$ROOTFS"
fi
ensure_dir "$ROOTFS" "$MOUNT_DIR"

# ---------- 1. qcow2 -> raw ----------

log_info "转换 qcow2 -> raw (便于 losetup)"
qemu-img convert -p -O raw "$QCOW2_SRC" "$RAW_SRC"

# ---------- 2. losetup ----------

log_info "losetup 挂载 raw 镜像"
LOOP_DEV=$(attach_loop "$RAW_SRC")
register_cleanup "detach_loop '$LOOP_DEV'"
log_info "loop 设备: $LOOP_DEV"

# 列出所有分区方便调试
log_info "分区列表:"
lsblk -no NAME,SIZE,FSTYPE "$LOOP_DEV" || true

# ---------- 3. 识别根分区 ----------

ROOT_PART=$(find_root_partition "$LOOP_DEV") \
  || die "未识别到根分区（ext4/btrfs/xfs）"
ROOT_FSTYPE=$(blkid -s TYPE -o value "$ROOT_PART")
ROOT_PART_NUM=$(partition_number "$ROOT_PART")
log_info "根分区: $ROOT_PART (fstype=$ROOT_FSTYPE, num=$ROOT_PART_NUM)"

# ---------- 4. 挂载并 rsync 出 rootfs ----------

log_info "挂载根分区到 $MOUNT_DIR"
mount "$ROOT_PART" "$MOUNT_DIR"
register_cleanup "safe_umount '$MOUNT_DIR'"

log_info "rsync 提取 rootfs 到 $ROOTFS"
rsync -aHAX --numeric-ids \
  "$MOUNT_DIR/" "$ROOTFS/"

# ---------- 5. 保存分区表与编号 ----------

log_info "导出分区表到 partition-${BOOT_TYPE}.dump"
sfdisk -d "$LOOP_DEV" > "$SRC_DIR/partition-${BOOT_TYPE}.dump"

echo "$ROOT_PART_NUM" > "$SRC_DIR/root-partnum-${BOOT_TYPE}.txt"

if [ "$BOOT_TYPE" = "uefi" ]; then
  ESP_PART=$(find_esp_partition "$LOOP_DEV") \
    || die "UEFI 镜像中未找到 ESP 分区（vfat）"
  ESP_PART_NUM=$(partition_number "$ESP_PART")
  log_info "ESP 分区: $ESP_PART (num=$ESP_PART_NUM)"
  echo "$ESP_PART_NUM" > "$SRC_DIR/esp-partnum-${BOOT_TYPE}.txt"
fi

# ---------- 6. 校验 rootfs 完整性 ----------

if [ ! -x "$ROOTFS/sbin/init" ] && [ ! -L "$ROOTFS/sbin/init" ]; then
  die "rootfs 提取异常：未找到 /sbin/init"
fi

log_ok "rootfs 大小: $(du -sh "$ROOTFS" | cut -f1)"
log_ok "阶段 1 (extract) 完成"
