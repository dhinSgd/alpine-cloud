#!/usr/bin/env bash
# 阶段 3: 创建目标镜像、格式化 btrfs、rsync rootfs、修正引导
#   - 创建 1GB raw 镜像并恢复官方分区表
#   - UEFI: 复制 ESP 分区；BIOS: 复制 MBR 引导代码（前 446 字节）
#   - 根分区 mkfs.btrfs，创建 @ 子卷，rsync rootfs 进去
#   - 更新 /etc/fstab 和 grub.cfg 中的 root UUID / rootfstype

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/disk-utils.sh
source "$SCRIPT_DIR/lib/disk-utils.sh"

parse_args "$@"
require_root
load_source_env

log_info "阶段 3 (build-image) - 启动 [boot=${BOOT_TYPE}]"

ROOTFS="$BUILD_DIR/rootfs-${BOOT_TYPE}"
SRC_DIR="$BUILD_DIR/source"
RAW_SRC="$SRC_DIR/source-${BOOT_TYPE}.raw"
OUTPUT_IMG="$BUILD_DIR/output-${BOOT_TYPE}.img"
MOUNT_DIR="$BUILD_DIR/mnt-new-${BOOT_TYPE}"

PART_DUMP="$SRC_DIR/partition-${BOOT_TYPE}.dump"
ROOT_PARTNUM_FILE="$SRC_DIR/root-partnum-${BOOT_TYPE}.txt"
ESP_PARTNUM_FILE="$SRC_DIR/esp-partnum-${BOOT_TYPE}.txt"

[ -d "$ROOTFS" ]      || die "rootfs 不存在: $ROOTFS"
[ -f "$RAW_SRC" ]     || die "源 raw 镜像不存在: $RAW_SRC"
[ -f "$PART_DUMP" ]   || die "分区表 dump 不存在: $PART_DUMP"
[ -f "$ROOT_PARTNUM_FILE" ] || die "未找到根分区编号文件"

ROOT_PART_NUM=$(cat "$ROOT_PARTNUM_FILE")
log_info "根分区编号: p${ROOT_PART_NUM}"

if [ "$BOOT_TYPE" = "uefi" ]; then
  [ -f "$ESP_PARTNUM_FILE" ] || die "UEFI 模式下未找到 ESP 分区编号文件"
  ESP_PART_NUM=$(cat "$ESP_PARTNUM_FILE")
  log_info "ESP 分区编号: p${ESP_PART_NUM}"
fi

# ---------- 1. 创建空白镜像 ----------

DISK_SIZE="${OUTPUT_DISK_SIZE:-1G}"
log_info "创建空白镜像 $OUTPUT_IMG (大小: $DISK_SIZE)"
rm -f "$OUTPUT_IMG"
truncate -s "$DISK_SIZE" "$OUTPUT_IMG"

# ---------- 2. 恢复分区表 ----------

log_info "恢复分区表 (sfdisk < partition-${BOOT_TYPE}.dump)"
sfdisk "$OUTPUT_IMG" < "$PART_DUMP" >/dev/null

# ---------- 3. losetup 目标镜像 ----------

log_info "losetup 目标镜像"
LOOP_DEV=$(attach_loop "$OUTPUT_IMG")
register_cleanup "detach_loop '$LOOP_DEV'"
log_info "目标 loop 设备: $LOOP_DEV"

ROOT_PART="${LOOP_DEV}p${ROOT_PART_NUM}"
[ -b "$ROOT_PART" ] || die "目标根分区设备不存在: $ROOT_PART"

# ---------- 4. 引导区/ESP 复制 ----------

# 同步挂载源镜像（用第二个 loop）
log_info "再次 losetup 源镜像用于复制引导区"
SRC_LOOP=$(attach_loop "$RAW_SRC")
register_cleanup "detach_loop '$SRC_LOOP'"
log_info "源 loop 设备: $SRC_LOOP"

if [ "$BOOT_TYPE" = "uefi" ]; then
  SRC_ESP="${SRC_LOOP}p${ESP_PART_NUM}"
  DST_ESP="${LOOP_DEV}p${ESP_PART_NUM}"
  [ -b "$SRC_ESP" ] || die "源 ESP 分区不存在: $SRC_ESP"
  [ -b "$DST_ESP" ] || die "目标 ESP 分区不存在: $DST_ESP"
  log_info "dd 复制 ESP 分区: $SRC_ESP -> $DST_ESP"
  dd if="$SRC_ESP" of="$DST_ESP" bs=1M conv=fsync status=progress
fi

if [ "$BOOT_TYPE" = "bios" ]; then
  # 复制 MBR 引导代码（前 446 字节），分区表已通过 sfdisk 恢复
  log_info "dd 复制 MBR 引导代码（446 字节）"
  dd if="$SRC_LOOP" of="$LOOP_DEV" bs=446 count=1 conv=notrunc,fsync status=none
fi

# 不再需要源 loop（提前释放）
detach_loop "$SRC_LOOP"
SRC_LOOP=""

# ---------- 5. mkfs.btrfs ----------

log_info "格式化根分区为 btrfs"
# shellcheck disable=SC2086
mkfs.btrfs $BTRFS_MKFS_OPTS -L "slim_alpine_root" "$ROOT_PART"

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
[ -n "$ROOT_UUID" ] || die "无法获取新根分区 UUID"
log_info "根分区 UUID: $ROOT_UUID"

# ---------- 6. 创建 @ 子卷 ----------

ensure_dir "$MOUNT_DIR"

log_info "挂载根分区（默认选项）以创建 @ 子卷"
mount "$ROOT_PART" "$MOUNT_DIR"
btrfs subvolume create "$MOUNT_DIR/@" >/dev/null
umount "$MOUNT_DIR"

log_info "以 subvol=@ 重新挂载（启用 zstd:9 压缩）"
mount -o "$BTRFS_MOUNT_OPTS" "$ROOT_PART" "$MOUNT_DIR"
register_cleanup "safe_umount '$MOUNT_DIR/boot/efi' 2>/dev/null || true"
register_cleanup "safe_umount '$MOUNT_DIR'"

# ---------- 7. rsync rootfs ----------

log_info "rsync rootfs -> 目标镜像 (压缩在写入时生效)"
rsync -aHAX --numeric-ids --sparse \
  "$ROOTFS/" "$MOUNT_DIR/"

# ---------- 8. /etc/fstab ----------

log_info "写入 /etc/fstab"
{
  printf "# slim-alpine generated fstab\n"
  printf "UUID=%s\t/\tbtrfs\t%s\t0\t0\n" "$ROOT_UUID" "$BTRFS_MOUNT_OPTS"
} > "$MOUNT_DIR/etc/fstab"

if [ "$BOOT_TYPE" = "uefi" ]; then
  ESP_UUID=$(blkid -s UUID -o value "${LOOP_DEV}p${ESP_PART_NUM}")
  [ -n "$ESP_UUID" ] || log_warn "无法获取 ESP UUID（跳过 fstab 写入）"
  if [ -n "$ESP_UUID" ]; then
    log_info "ESP UUID: $ESP_UUID -> 写入 /etc/fstab"
    printf "UUID=%s\t/boot/efi\tvfat\tdefaults,umask=0077\t0\t1\n" \
      "$ESP_UUID" >> "$MOUNT_DIR/etc/fstab"
  fi
  ensure_dir "$MOUNT_DIR/boot/efi"
fi

# ---------- 9. GRUB 配置 UUID 与 rootfstype 替换 ----------

# 收集所有 grub.cfg / extlinux.conf 候选路径
CANDIDATES=()
for p in \
  "$MOUNT_DIR/boot/grub/grub.cfg" \
  "$MOUNT_DIR/etc/default/grub" \
  "$MOUNT_DIR/boot/extlinux.conf" \
  "$MOUNT_DIR/extlinux.conf"
do
  [ -f "$p" ] && CANDIDATES+=("$p")
done

# UEFI: 同步处理 ESP 中的 grub 配置
if [ "$BOOT_TYPE" = "uefi" ]; then
  log_info "挂载 ESP 以更新其中的 grub.cfg"
  mount "${LOOP_DEV}p${ESP_PART_NUM}" "$MOUNT_DIR/boot/efi"
  while IFS= read -r f; do
    CANDIDATES+=("$f")
  done < <(find "$MOUNT_DIR/boot/efi" -type f \( -name 'grub.cfg' -o -name '*.cfg' \) 2>/dev/null || true)
fi

# 从源 rootfs 的 grub.cfg 中提取旧 root UUID（任选一个候选）
OLD_ROOT_UUID=""
for cfg in "$ROOTFS/boot/grub/grub.cfg" "$ROOTFS/etc/default/grub"; do
  if [ -f "$cfg" ]; then
    OLD_ROOT_UUID=$(grep -hoE 'root=UUID=[A-Fa-f0-9-]+' "$cfg" 2>/dev/null \
      | head -1 | cut -d= -f3)
    [ -n "$OLD_ROOT_UUID" ] && break
  fi
done

if [ -n "$OLD_ROOT_UUID" ]; then
  log_info "旧 root UUID: $OLD_ROOT_UUID -> 新: $ROOT_UUID"
else
  log_warn "未在源 rootfs grub.cfg 中找到 root=UUID=...（可能用 LABEL 或 PARTUUID）"
fi

for cfg in "${CANDIDATES[@]}"; do
  log_info "  patch: ${cfg#"$MOUNT_DIR"}"
  # 1) 替换具体 UUID
  if [ -n "$OLD_ROOT_UUID" ]; then
    sed -i "s/$OLD_ROOT_UUID/$ROOT_UUID/g" "$cfg"
  fi
  # 2) 兜底：任何 root=UUID=... -> 新 UUID（防止其它地方写死了不同 UUID）
  sed -i -E "s|root=UUID=[A-Fa-f0-9-]+|root=UUID=$ROOT_UUID|g" "$cfg"
  # 3) rootfstype=ext4 -> btrfs
  sed -i -E 's|rootfstype=ext4|rootfstype=btrfs|g' "$cfg"
  # 4) ro 选项保留；追加 rootflags 以确保挂载时启用子卷
  #    仅在还没有 rootflags=subvol=@ 时追加
  if ! grep -q 'rootflags=subvol=@' "$cfg"; then
    sed -i -E "s|(root=UUID=[A-Fa-f0-9-]+)|\1 rootflags=subvol=@|g" "$cfg"
  fi
done

# ---------- 10. 同步与清理 ----------

log_info "sync 文件系统"
sync

# 显式卸载 ESP（如果挂着）
if [ "$BOOT_TYPE" = "uefi" ]; then
  safe_umount "$MOUNT_DIR/boot/efi"
fi
safe_umount "$MOUNT_DIR"

# 显示 btrfs 实际占用
log_info "目标镜像信息:"
ls -lh "$OUTPUT_IMG"
qemu-img info "$OUTPUT_IMG" 2>/dev/null || true

log_ok "阶段 3 (build-image) 完成"
