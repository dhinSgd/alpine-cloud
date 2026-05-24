#!/bin/sh
# 阿里云 ECS 全面系统测试脚本
# 用法：ssh 登录后执行 sh test-aliyun.sh

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

pass() { printf "${GREEN}✓${NC} %s\n" "$*"; }
fail() { printf "${RED}✗${NC} %s\n" "$*"; exit 1; }
warn() { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
info() { printf "${BLUE}ℹ${NC} %s\n" "$*"; }

echo "========================================"
echo "Alpine Cloud 镜像 - 阿里云 ECS 全面测试"
echo "========================================"
echo ""

# ---------- 1. 基础系统信息 ----------
info "[1/12] 基础系统信息"
echo "  OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "  Kernel: $(uname -r)"
echo "  Hostname: $(hostname)"
echo "  Uptime: $(uptime -p)"
pass "系统信息正常"
echo ""

# ---------- 2. 根文件系统 btrfs ----------
info "[2/12] 检查根文件系统 btrfs"
ROOT_FS=$(df -T / | tail -1 | awk '{print $2}')
if [ "$ROOT_FS" = "btrfs" ]; then
  pass "根文件系统是 btrfs"
else
  fail "根文件系统不是 btrfs，实际: $ROOT_FS"
fi
echo ""

# ---------- 3. btrfs 压缩 zstd ----------
info "[3/12] 检查 btrfs zstd 压缩"
MOUNT_OPTS=$(mount | grep ' on / type btrfs')
echo "  挂载选项: $MOUNT_OPTS"
if echo "$MOUNT_OPTS" | grep -qE 'compress(-force)?=zstd'; then
  pass "btrfs 启用了 zstd 压缩"
else
  fail "btrfs 未启用 zstd 压缩"
fi
echo ""

# ---------- 4. btrfs 子卷 @ ----------
info "[4/12] 检查 btrfs 子卷 @"
if echo "$MOUNT_OPTS" | grep -q 'subvol=/@'; then
  pass "根分区使用 @ 子卷"
else
  fail "根分区未使用 @ 子卷"
fi
echo ""

# ---------- 5. btrfs 文件系统健康 ----------
info "[5/12] 检查 btrfs 文件系统健康"
btrfs filesystem df / > /tmp/btrfs-df.txt
cat /tmp/btrfs-df.txt
if [ $? -eq 0 ]; then
  pass "btrfs filesystem df 正常"
else
  fail "btrfs filesystem df 失败"
fi
echo ""

# ---------- 6. 磁盘空间与扩容 ----------
info "[6/12] 检查磁盘空间"
df -h / | tail -1
DISK_SIZE=$(df -h / | tail -1 | awk '{print $2}')
echo "  根分区大小: $DISK_SIZE"
if [ "$DISK_SIZE" = "922.0M" ] || [ "$DISK_SIZE" = "1.0G" ]; then
  warn "磁盘未扩容（仍为 1GB），cloud-init growpart 可能未生效"
else
  pass "磁盘已扩容到 $DISK_SIZE"
fi
echo ""

# ---------- 7. 网络配置 ----------
info "[7/12] 检查网络配置"
ip -4 addr show | grep 'inet ' | grep -v '127.0.0.1'
IPV4=$(ip -4 addr show | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')
if [ -n "$IPV4" ]; then
  pass "已获取 IPv4 地址: $IPV4"
else
  fail "未获取 IPv4 地址"
fi
echo ""

# ---------- 8. 外网连通性 ----------
info "[8/12] 检查外网连通性"
if ping -c 2 -W 3 8.8.8.8 > /dev/null 2>&1; then
  pass "外网连通（ping 8.8.8.8 成功）"
else
  warn "外网不通（ping 8.8.8.8 失败），可能是安全组限制"
fi
echo ""

# ---------- 9. DNS 解析 ----------
info "[9/12] 检查 DNS 解析"
if nslookup aliyun.com > /dev/null 2>&1; then
  pass "DNS 解析正常"
else
  warn "DNS 解析失败"
fi
echo ""

# ---------- 10. sshd 服务 ----------
info "[10/12] 检查 sshd 服务"
if pidof sshd > /dev/null; then
  pass "sshd 进程运行中"
else
  fail "sshd 进程未运行"
fi
if rc-status default | grep -q 'sshd.*started'; then
  pass "sshd 服务已启用"
else
  warn "sshd 服务未在 default runlevel"
fi
echo ""

# ---------- 11. cloud-init 状态 ----------
info "[11/12] 检查 cloud-init 状态"
cloud-init status > /tmp/cloud-init-status.txt 2>&1
cat /tmp/cloud-init-status.txt
CI_STATUS=$(grep 'status:' /tmp/cloud-init-status.txt | awk '{print $2}')
if [ "$CI_STATUS" = "done" ]; then
  pass "cloud-init 状态: done"
elif [ "$CI_STATUS" = "degraded" ]; then
  warn "cloud-init 状态: degraded（部分功能失败，但可接受）"
else
  warn "cloud-init 状态: $CI_STATUS"
fi
echo ""

# ---------- 12. 阿里云元数据服务 ----------
info "[12/12] 检查阿里云元数据服务"
if command -v curl > /dev/null 2>&1; then
  INSTANCE_ID=$(curl -s --connect-timeout 3 http://100.100.100.200/latest/meta-data/instance-id 2>/dev/null || echo "")
  if [ -n "$INSTANCE_ID" ]; then
    pass "阿里云元数据服务可访问"
    echo "  实例 ID: $INSTANCE_ID"
  else
    warn "无法访问阿里云元数据服务（100.100.100.200）"
  fi
else
  warn "curl 未安装，跳过元数据检查"
fi
echo ""

# ---------- 总结 ----------
echo "========================================"
echo "${GREEN}测试完成！${NC}"
echo "========================================"
echo ""
echo "关键指标："
echo "  - 文件系统: $ROOT_FS"
echo "  - 压缩: $(echo "$MOUNT_OPTS" | grep -oE 'compress(-force)?=zstd[^,]*')"
echo "  - 子卷: $(echo "$MOUNT_OPTS" | grep -oE 'subvol=/[^,]*')"
echo "  - 磁盘大小: $DISK_SIZE"
echo "  - IPv4: ${IPV4:-无}"
echo "  - cloud-init: $CI_STATUS"
echo ""
