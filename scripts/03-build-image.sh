#!/usr/bin/env bash
# 阶段 3: 创建目标镜像、自建分区表、格式化 ESP/btrfs、rsync rootfs、重装 GRUB
#   - 创建 1GB raw 镜像
#   - 自建 GPT 分区表：p1=ESP(100MiB, vfat) + p2=root(剩余, btrfs)
#     （不复用源 sfdisk dump：源 ESP 仅 ~512KiB，装不下含 btrfs 模块的 GRUB）
#   - 根分区 mkfs.btrfs，创建 @ 子卷，rsync rootfs 进去
#   - chroot grub-install 重装 EFI binary（含 btrfs 模块）+ grub-mkconfig
#   - 更新 /etc/fstab 和 grub.cfg 中的 root UUID / rootfstype / subvol

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

[ -d "$ROOTFS" ]  || die "rootfs 不存在: $ROOTFS"
[ -f "$RAW_SRC" ] || die "源 raw 镜像不存在: $RAW_SRC"

# 写死自建分区编号
ROOT_PART_NUM=2
ESP_PART_NUM=1

# ---------- 1. 创建空白镜像 ----------

DISK_SIZE="${OUTPUT_DISK_SIZE:-1G}"
log_info "创建空白镜像 $OUTPUT_IMG (大小: $DISK_SIZE)"
rm -f "$OUTPUT_IMG"
truncate -s "$DISK_SIZE" "$OUTPUT_IMG"

# ---------- 2. 自建分区表 ----------

if [ "$BOOT_TYPE" = "uefi" ]; then
  # GPT:
  #   p1 EFI System (100 MiB, 204800 sectors @ 512B), type C12A...
  #   p2 Linux filesystem (剩余), type 0FC6...
  log_info "创建 GPT 分区表（ESP=100MiB + root=剩余）"
  sfdisk "$OUTPUT_IMG" >/dev/null <<'PART_EOF'
label: gpt
unit: sectors
sector-size: 512

start=2048, size=204800, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI System"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root"
PART_EOF
else
  # BIOS 路径目前仅占位，build matrix 已禁用，此处仅做基本 DOS 分区
  log_warn "BIOS 路径未充分测试，仅创建基础 MBR 分区"
  sfdisk "$OUTPUT_IMG" >/dev/null <<'PART_EOF'
label: dos
unit: sectors

start=2048, type=83, bootable
PART_EOF
  ROOT_PART_NUM=1
fi

# ---------- 3. losetup 目标镜像 ----------

log_info "losetup 目标镜像"
LOOP_DEV=$(attach_loop "$OUTPUT_IMG")
register_cleanup "detach_loop '$LOOP_DEV'"
log_info "目标 loop 设备: $LOOP_DEV"

ROOT_PART="${LOOP_DEV}p${ROOT_PART_NUM}"
[ -b "$ROOT_PART" ] || die "目标根分区设备不存在: $ROOT_PART"

# ---------- 4. 格式化 ESP / 引导区 ----------

if [ "$BOOT_TYPE" = "uefi" ]; then
  DST_ESP="${LOOP_DEV}p${ESP_PART_NUM}"
  [ -b "$DST_ESP" ] || die "目标 ESP 分区不存在: $DST_ESP"
  log_info "mkfs.vfat (FAT32) 格式化 ESP: $DST_ESP"
  mkfs.vfat -F 32 -n "ESP" "$DST_ESP" >/dev/null
fi

if [ "$BOOT_TYPE" = "bios" ]; then
  # 仅在 BIOS 模式下需要复用源 raw 的 MBR 引导代码（466 字节中 0–445 字节）
  log_info "再次 losetup 源镜像用于复制 MBR 引导代码"
  SRC_LOOP=$(attach_loop "$RAW_SRC")
  register_cleanup "detach_loop '$SRC_LOOP'"
  log_info "dd 复制 MBR 引导代码（446 字节）"
  dd if="$SRC_LOOP" of="$LOOP_DEV" bs=446 count=1 conv=notrunc,fsync status=none
  detach_loop "$SRC_LOOP"
  SRC_LOOP=""
fi

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

# ---------- 9. GRUB 重装与配置 patch ----------
#
# 关键点：Alpine 官方 cloud UEFI 镜像的 BOOTX64.EFI 是为 ext4 根分区构建的，
# 其内置模块里没有 btrfs。直接把根换成 btrfs 后，GRUB 阶段会报
# "error: unknown filesystem" 并掉进 grub rescue。
# 因此需要在新 btrfs 上 chroot 重装 grub-efi，让生成的 BOOTX64.EFI
# 把 btrfs 模块编入，自身就能读 btrfs 上的 /boot/grub/grub.cfg。
#
# 步骤：
#   9a. UEFI 先把 ESP 挂到 $MOUNT_DIR/boot/efi
#   9b. UEFI bind mount /proc /sys /dev /run → chroot grub-install + grub-mkconfig
#   9c. 对所有 grub.cfg / extlinux.conf 兜底 sed：保证 root UUID/rootfstype/rootflags 一致

# 9a. UEFI: 挂 ESP
if [ "$BOOT_TYPE" = "uefi" ]; then
  log_info "挂载 ESP 到 $MOUNT_DIR/boot/efi"
  mount "${LOOP_DEV}p${ESP_PART_NUM}" "$MOUNT_DIR/boot/efi"
fi

# 9b. UEFI: chroot 内重装 GRUB（含 btrfs 模块）+ grub-mkconfig
if [ "$BOOT_TYPE" = "uefi" ]; then
  log_info "[UEFI] bind mount 虚拟文件系统进 chroot"
  for fs in proc sys dev run; do
    ensure_dir "$MOUNT_DIR/$fs"
    mount --bind "/$fs" "$MOUNT_DIR/$fs"
    register_cleanup "umount -lf '$MOUNT_DIR/$fs' 2>/dev/null || true"
  done

  # --removable：装到 /boot/efi/EFI/BOOT/BOOTX64.EFI（云环境无 NVRAM，必须走 fallback 路径）
  # --no-nvram：build 主机不写 efivars
  # --modules：显式列出 EFI binary 内置模块，btrfs 是核心
  GRUB_MODULES="part_gpt part_msdos btrfs ext2 fat normal linux configfile search search_fs_uuid search_label all_video font gfxterm efi_gop efi_uga"
  log_info "[UEFI] chroot grub-install --target=x86_64-efi --removable"
  chroot "$MOUNT_DIR" /usr/sbin/grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --boot-directory=/boot \
    --removable \
    --no-nvram \
    --modules="$GRUB_MODULES"

  log_info "[UEFI] chroot grub-mkconfig -o /boot/grub/grub.cfg"
  chroot "$MOUNT_DIR" /usr/sbin/grub-mkconfig -o /boot/grub/grub.cfg
fi

# 9c. 收集所有候选并做兜底 sed
CANDIDATES=()
for p in \
  "$MOUNT_DIR/boot/grub/grub.cfg" \
  "$MOUNT_DIR/etc/default/grub" \
  "$MOUNT_DIR/boot/extlinux.conf" \
  "$MOUNT_DIR/extlinux.conf"
do
  [ -f "$p" ] && CANDIDATES+=("$p")
done

if [ "$BOOT_TYPE" = "uefi" ]; then
  while IFS= read -r f; do
    CANDIDATES+=("$f")
  done < <(find "$MOUNT_DIR/boot/efi" -type f \( -name 'grub.cfg' -o -name '*.cfg' \) 2>/dev/null || true)
fi

# 从源 rootfs 的 grub.cfg 中提取旧 root UUID（任选一个候选），用于兜底替换
OLD_ROOT_UUID=""
for cfg in "$ROOTFS/boot/grub/grub.cfg" "$ROOTFS/etc/default/grub"; do
  if [ -f "$cfg" ]; then
    OLD_ROOT_UUID=$(awk '
      match($0, /root=UUID=[A-Fa-f0-9-]+/) {
        print substr($0, RSTART+10, RLENGTH-10); exit
      }' "$cfg" 2>/dev/null || true)
    [ -n "$OLD_ROOT_UUID" ] && break
  fi
done

if [ -n "$OLD_ROOT_UUID" ]; then
  log_info "旧 root UUID: $OLD_ROOT_UUID -> 新: $ROOT_UUID"
else
  log_info "源 rootfs grub.cfg 未提取到旧 UUID（可能 grub-mkconfig 已正确生成，仅做 sed 兜底）"
fi

for cfg in "${CANDIDATES[@]}"; do
  log_info "  patch: ${cfg#"$MOUNT_DIR"}"
  if [ -n "$OLD_ROOT_UUID" ]; then
    sed -i "s/$OLD_ROOT_UUID/$ROOT_UUID/g" "$cfg"
  fi
  # 兜底：任何 root=UUID=... -> 新 UUID
  sed -i -E "s|root=UUID=[A-Fa-f0-9-]+|root=UUID=$ROOT_UUID|g" "$cfg"
  # rootfstype=ext4 -> btrfs（如果 grub-mkconfig 没改对）
  sed -i -E 's|rootfstype=ext4|rootfstype=btrfs|g' "$cfg"
  # 兜底追加 rootflags=subvol=@（仅在还没有时）
  if ! grep -q 'rootflags=subvol=@' "$cfg"; then
    sed -i -E "s|(root=UUID=[A-Fa-f0-9-]+)|\1 rootflags=subvol=@|g" "$cfg"
  fi
done

# ---------- 10. 同步与清理 ----------

log_info "sync 文件系统"
sync

# 显式卸载 chroot bind mounts（/proc /sys /dev /run），否则 MOUNT_DIR 无法卸载
if [ "$BOOT_TYPE" = "uefi" ]; then
  for fs in run dev sys proc; do
    safe_umount "$MOUNT_DIR/$fs"
  done
fi

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
