#!/usr/bin/env bash
# 阶段 2: 在 chroot 中精简与定制 rootfs（核心阶段）
#   - 安装必要工具
#   - 卸载黑名单包
#   - 删除黑名单内核模块文件 + 写入 modprobe.d 软兜底
#   - 设置 root 密码、开启 SSH 密码登录
#   - 部署 cloud-init Aliyun 优先配置
#   - 启用关键服务（OpenRC）
#   - 清理缓存、文档、日志、machine-id、SSH host key

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/disk-utils.sh
source "$SCRIPT_DIR/lib/disk-utils.sh"

parse_args "$@"
require_root
load_source_env

log_info "阶段 2 (customize) - 启动 [boot=${BOOT_TYPE}]"

ROOTFS="$BUILD_DIR/rootfs-${BOOT_TYPE}"
[ -d "$ROOTFS" ] || die "rootfs 不存在: $ROOTFS（先跑 01-extract.sh）"
[ -x "$ROOTFS/sbin/apk" ] || [ -L "$ROOTFS/sbin/apk" ] \
  || die "rootfs 中找不到 apk，可能不是 Alpine"

# ---------- 1. 准备 chroot ----------

log_info "绑定虚拟文件系统进 chroot"
bind_chroot_fs "$ROOTFS"

log_info "复制 host 的 resolv.conf 进 chroot（用于 apk）"
# 备份原 resolv.conf，退出时恢复（防止在原 rootfs 残留）
if [ -e "$ROOTFS/etc/resolv.conf" ] && [ ! -e "$ROOTFS/etc/resolv.conf.bak-slim" ]; then
  cp -a "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/resolv.conf.bak-slim"
fi
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
register_cleanup "rm -f '$ROOTFS/etc/resolv.conf'"
register_cleanup "[ -e '$ROOTFS/etc/resolv.conf.bak-slim' ] && mv '$ROOTFS/etc/resolv.conf.bak-slim' '$ROOTFS/etc/resolv.conf' || true"

# ---------- 2. 更新 apk 索引、安装工具 ----------

log_info "apk update"
chroot "$ROOTFS" /sbin/apk update

INSTALL_LIST="$CONFIG_DIR/packages-install.list"
[ -f "$INSTALL_LIST" ] || die "缺少 $INSTALL_LIST"
INSTALL_PKGS=$(awk '!/^[[:space:]]*(#|$)/{print $1}' "$INSTALL_LIST" | xargs)
if [ -n "$INSTALL_PKGS" ]; then
  log_info "安装工具: $INSTALL_PKGS"
  # shellcheck disable=SC2086
  chroot "$ROOTFS" /sbin/apk add --no-cache $INSTALL_PKGS
else
  log_info "无需安装额外工具"
fi

# ---------- 3. 卸载黑名单包 ----------

REMOVE_LIST="$CONFIG_DIR/packages-remove.list"
if [ -f "$REMOVE_LIST" ]; then
  REMOVE_PKGS=$(awk '!/^[[:space:]]*(#|$)/{print $1}' "$REMOVE_LIST" | xargs)
  if [ -n "$REMOVE_PKGS" ]; then
    log_info "卸载包: $REMOVE_PKGS"
    # shellcheck disable=SC2086
    chroot "$ROOTFS" /sbin/apk del $REMOVE_PKGS || log_warn "部分包卸载失败（可能未安装），继续"
  else
    log_info "包卸载列表为空，跳过"
  fi
fi

# ---------- 4. 内核模块精简 ----------

log_info "处理内核模块精简"
KERNEL_VERSION=$(find "$ROOTFS/lib/modules/" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -1 || true)
[ -n "$KERNEL_VERSION" ] || die "未找到 /lib/modules/<version> 目录"
MODULES_DIR="$ROOTFS/lib/modules/$KERNEL_VERSION/kernel"
[ -d "$MODULES_DIR" ] || die "未找到内核模块目录: $MODULES_DIR"
log_info "内核版本: $KERNEL_VERSION"

# 4a. modprobe.d 黑名单（软兜底）
BLACKLIST_CONF="$CONFIG_DIR/kernel-modules-blacklist.conf"
if [ -f "$BLACKLIST_CONF" ]; then
  log_info "写入 modprobe blacklist 到 /etc/modprobe.d/blacklist-slim.conf"
  install -D -m 0644 "$BLACKLIST_CONF" \
    "$ROOTFS/etc/modprobe.d/blacklist-slim.conf"
fi

# 4b. 实际删除模块文件
REMOVE_MOD_LIST="$CONFIG_DIR/kernel-modules-remove.list"
if [ -f "$REMOVE_MOD_LIST" ]; then
  SIZE_BEFORE=$(du -sm "$MODULES_DIR" | cut -f1)
  while IFS= read -r entry; do
    entry="${entry%%#*}"        # 去掉行内注释
    entry="$(echo "$entry" | xargs)"  # 去首尾空白
    [ -z "$entry" ] && continue
    target="$MODULES_DIR/$entry"
    if [ -e "$target" ] || [ -L "$target" ]; then
      log_info "删除模块: $entry"
      rm -rf "$target"
    else
      log_warn "模块路径不存在（跳过）: $entry"
    fi
  done < "$REMOVE_MOD_LIST"
  SIZE_AFTER=$(du -sm "$MODULES_DIR" | cut -f1)
  log_ok "模块目录: ${SIZE_BEFORE}MB -> ${SIZE_AFTER}MB"
fi

# 4c. 重建 modules.dep
log_info "重新生成 modules.dep (depmod -a)"
chroot "$ROOTFS" /sbin/depmod -a "$KERNEL_VERSION"

# 4d. mkinitfs features 加 btrfs + 重建 initramfs
#    根分区将切到 btrfs，initramfs 必须包含 btrfs 内核模块和 userspace 工具，
#    否则 init 阶段无法挂载根文件系统。
MKINITFS_CONF="$ROOTFS/etc/mkinitfs/mkinitfs.conf"
if [ -f "$MKINITFS_CONF" ]; then
  CURRENT_FEATURES=$(awk -F'=' '/^features=/{gsub(/"/,"",$2); print $2}' "$MKINITFS_CONF")
  if echo "$CURRENT_FEATURES" | grep -qw btrfs; then
    log_info "mkinitfs features 已含 btrfs，跳过"
  else
    NEW_FEATURES=$(echo "${CURRENT_FEATURES} btrfs" | xargs)
    log_info "mkinitfs features: '$CURRENT_FEATURES' -> '$NEW_FEATURES'"
    sed -i -E "s|^features=.*|features=\"$NEW_FEATURES\"|" "$MKINITFS_CONF"
  fi
else
  log_warn "未找到 $MKINITFS_CONF（不是 Alpine 标准 initramfs?），跳过 features 配置"
fi

log_info "重新生成 initramfs (mkinitfs $KERNEL_VERSION)"
chroot "$ROOTFS" /sbin/mkinitfs "$KERNEL_VERSION"

# ---------- 5. 配置 root 密码 + SSH ----------

ROOT_PASS="${DEFAULT_ROOT_PASSWORD:-slimalpine123}"
log_info "设置 root 密码（默认: $ROOT_PASS，部署后请立即修改）"
chroot "$ROOTFS" /bin/sh -c "echo 'root:${ROOT_PASS}' | chpasswd"

log_info "允许 root 通过密码 SSH 登录"
SSHD_CFG="$ROOTFS/etc/ssh/sshd_config"
if [ -f "$SSHD_CFG" ]; then
  sed -i -E 's@^[[:space:]]*#?[[:space:]]*PermitRootLogin.*@PermitRootLogin yes@' "$SSHD_CFG"
  sed -i -E 's@^[[:space:]]*#?[[:space:]]*PasswordAuthentication.*@PasswordAuthentication yes@' "$SSHD_CFG"
  # 若行不存在则追加
  grep -qE '^PermitRootLogin[[:space:]]+yes' "$SSHD_CFG" || echo "PermitRootLogin yes" >> "$SSHD_CFG"
  grep -qE '^PasswordAuthentication[[:space:]]+yes' "$SSHD_CFG" || echo "PasswordAuthentication yes" >> "$SSHD_CFG"
else
  log_warn "未找到 sshd_config，跳过 SSH 配置"
fi

# ---------- 6. cloud-init Aliyun 优先配置 ----------

CI_CFG="$CONFIG_DIR/cloud-init-aliyun.cfg"
if [ -f "$CI_CFG" ]; then
  log_info "部署 cloud-init 阿里云优先配置"
  install -D -m 0644 "$CI_CFG" \
    "$ROOTFS/etc/cloud/cloud.cfg.d/90-aliyun.cfg"
else
  log_warn "未找到 cloud-init Aliyun 配置文件，跳过"
fi

# ---------- 7. 启用服务（OpenRC） ----------

log_info "启用关键服务"
RC_UPDATE() {
  local svc="$1" runlevel="${2:-default}"
  if [ -x "$ROOTFS/etc/init.d/$svc" ]; then
    chroot "$ROOTFS" /sbin/rc-update add "$svc" "$runlevel" 2>&1 \
      | grep -v "already installed" || true
  else
    log_warn "init 脚本不存在，跳过: $svc"
  fi
}

RC_UPDATE chronyd default
RC_UPDATE sshd default
RC_UPDATE cloud-init-local boot
RC_UPDATE cloud-init default
RC_UPDATE cloud-config default
RC_UPDATE cloud-final default

# ---------- 8. 清理 ----------

log_info "清理缓存/文档/日志/machine-id/SSH host key"

# apk 缓存
rm -rf "$ROOTFS/var/cache/apk/"*

# 临时文件
rm -rf "$ROOTFS/tmp/"* "$ROOTFS/var/tmp/"* 2>/dev/null || true

# 日志（保留目录结构）
find "$ROOTFS/var/log" -mindepth 1 -delete 2>/dev/null || true

# 文档
rm -rf "$ROOTFS/usr/share/doc/"*  2>/dev/null || true
rm -rf "$ROOTFS/usr/share/man/"*  2>/dev/null || true
rm -rf "$ROOTFS/usr/share/info/"* 2>/dev/null || true

# locale（保留 en/zh）
if [ -d "$ROOTFS/usr/share/locale" ]; then
  find "$ROOTFS/usr/share/locale" -mindepth 1 -maxdepth 1 \
    ! -name 'en*' ! -name 'zh*' ! -name 'locale.alias' \
    -exec rm -rf {} + 2>/dev/null || true
fi

# machine-id 重置（cloud-init 首启会重建）
if [ -f "$ROOTFS/etc/machine-id" ]; then
  : > "$ROOTFS/etc/machine-id"
fi
rm -f "$ROOTFS/var/lib/dbus/machine-id"

# SSH host key（首启重建）
rm -f "$ROOTFS"/etc/ssh/ssh_host_*

# cloud-init 残留状态（防止携带 build 环境痕迹）
rm -rf "$ROOTFS/var/lib/cloud/"* 2>/dev/null || true

log_ok "rootfs 当前大小: $(du -sh "$ROOTFS" | cut -f1)"
log_ok "阶段 2 (customize) 完成"
