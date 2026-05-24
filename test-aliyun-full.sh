#!/bin/sh
# 阿里云 ECS 全面系统测试脚本（增强版）
# 用法：ssh 登录后执行 sh test-aliyun-full.sh

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { printf "${GREEN}✓${NC} %s\n" "$*"; }
fail() { printf "${RED}✗${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
info() { printf "${BLUE}ℹ${NC} %s\n" "$*"; }

FAILED_TESTS=0
mark_fail() { FAILED_TESTS=$((FAILED_TESTS + 1)); fail "$*"; }

echo "========================================"
echo "Alpine Cloud 镜像 - 阿里云 ECS 全面测试"
echo "========================================"
echo ""

# ---------- 1. 基础系统信息 ----------
info "[1/20] 基础系统信息"
echo "  OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "  Kernel: $(uname -r)"
echo "  Hostname: $(hostname)"
echo "  Uptime: $(cat /proc/uptime | awk '{print int($1/60)" minutes"}')"
echo "  Load: $(cat /proc/loadavg | awk '{print $1,$2,$3}')"
pass "系统信息正常"
echo ""

# ---------- 2. 根文件系统 btrfs ----------
info "[2/20] 检查根文件系统 btrfs"
ROOT_FS=$(df -T / | tail -1 | awk '{print $2}')
if [ "$ROOT_FS" = "btrfs" ]; then
  pass "根文件系统是 btrfs"
else
  mark_fail "根文件系统不是 btrfs，实际: $ROOT_FS"
fi
echo ""

# ---------- 3. btrfs 压缩 zstd ----------
info "[3/20] 检查 btrfs zstd 压缩"
MOUNT_OPTS=$(mount | grep ' on / type btrfs')
echo "  挂载选项: $MOUNT_OPTS"
if echo "$MOUNT_OPTS" | grep -qE 'compress(-force)?=zstd'; then
  pass "btrfs 启用了 zstd 压缩"
else
  mark_fail "btrfs 未启用 zstd 压缩"
fi
echo ""

# ---------- 4. btrfs 子卷 @ ----------
info "[4/20] 检查 btrfs 子卷 @"
if echo "$MOUNT_OPTS" | grep -q 'subvol=/@'; then
  pass "根分区使用 @ 子卷"
else
  mark_fail "根分区未使用 @ 子卷"
fi
echo ""

# ---------- 5. btrfs 文件系统健康 ----------
info "[5/20] 检查 btrfs 文件系统健康"
btrfs filesystem df / > /tmp/btrfs-df.txt
cat /tmp/btrfs-df.txt
if [ $? -eq 0 ]; then
  pass "btrfs filesystem df 正常"
else
  mark_fail "btrfs filesystem df 失败"
fi
echo ""

# ---------- 6. 磁盘空间与扩容诊断 ----------
info "[6/20] 检查磁盘空间与扩容"
df -h / | tail -1
DISK_SIZE=$(df -h / | tail -1 | awk '{print $2}')
echo "  根分区大小: $DISK_SIZE"

# 检查物理磁盘大小（lsblk 可能不存在，用 fdisk 兜底）
if command -v lsblk > /dev/null 2>&1; then
  PHYSICAL_SIZE=$(lsblk -b -d -o NAME,SIZE 2>/dev/null | grep vda | awk '{print $2}')
  PHYSICAL_SIZE_GB=$((PHYSICAL_SIZE / 1024 / 1024 / 1024))
else
  # Alpine fdisk 输出格式: "Disk /dev/vda: 2097152 sectors, 1024M"
  SECTORS=$(fdisk -l /dev/vda 2>/dev/null | grep 'Disk /dev/vda:' | awk '{print $3}')
  if [ -n "$SECTORS" ] && [ "$SECTORS" -eq "$SECTORS" ] 2>/dev/null; then
    # 扇区大小通常是 512 字节
    PHYSICAL_SIZE_GB=$((SECTORS * 512 / 1024 / 1024 / 1024))
  else
    PHYSICAL_SIZE_GB="unknown"
  fi
fi
echo "  物理磁盘: ${PHYSICAL_SIZE_GB}GB"

if [ "$DISK_SIZE" = "922.0M" ] || [ "$DISK_SIZE" = "1.0G" ]; then
  # 检查是否真的需要扩容
  if [ "$PHYSICAL_SIZE_GB" = "1" ] || [ "$PHYSICAL_SIZE_GB" = "0" ]; then
    pass "磁盘大小正常（1GB 磁盘已满分区，无需扩容）"
  else
    warn "磁盘未扩容（仍为 1GB），物理磁盘 ${PHYSICAL_SIZE_GB}GB"
    echo "  诊断 cloud-init growpart 日志："
    grep -i growpart /var/log/cloud-init.log 2>/dev/null | tail -5 || echo "    无 growpart 日志"
  fi
  echo "  分区表："
  fdisk -l /dev/vda 2>/dev/null | grep -E '^/dev/vda' || echo "    fdisk 不可用"
else
  pass "磁盘已扩容到 $DISK_SIZE"
fi
echo ""

# ---------- 7. 网络配置 ----------
info "[7/20] 检查网络配置"
ip -4 addr show | grep 'inet ' | grep -v '127.0.0.1'
IPV4=$(ip -4 addr show | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')
if [ -n "$IPV4" ]; then
  pass "已获取 IPv4 地址: $IPV4"
else
  mark_fail "未获取 IPv4 地址"
fi
echo ""

# ---------- 8. 外网连通性 ----------
info "[8/20] 检查外网连通性"
if ping -c 2 -W 3 8.8.8.8 > /dev/null 2>&1; then
  pass "外网连通（ping 8.8.8.8 成功）"
else
  warn "外网不通（ping 8.8.8.8 失败），可能是安全组限制"
fi
echo ""

# ---------- 9. DNS 解析 ----------
info "[9/20] 检查 DNS 解析"
if nslookup aliyun.com > /dev/null 2>&1; then
  pass "DNS 解析正常"
else
  warn "DNS 解析失败"
fi
echo ""

# ---------- 10. sshd 服务 ----------
info "[10/20] 检查 sshd 服务"
if pidof sshd > /dev/null; then
  pass "sshd 进程运行中"
else
  mark_fail "sshd 进程未运行"
fi
if rc-status default | grep -q 'sshd.*started'; then
  pass "sshd 服务已启用"
else
  warn "sshd 服务未在 default runlevel"
fi
echo ""

# ---------- 11. cloud-init 状态 ----------
info "[11/20] 检查 cloud-init 状态"
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
info "[12/20] 检查阿里云元数据服务"
if command -v curl > /dev/null 2>&1; then
  INSTANCE_ID=$(curl -s --connect-timeout 3 http://100.100.100.200/latest/meta-data/instance-id 2>/dev/null || echo "")
  if [ -n "$INSTANCE_ID" ]; then
    pass "阿里云元数据服务可访问"
    echo "  实例 ID: $INSTANCE_ID"
    REGION=$(curl -s --connect-timeout 3 http://100.100.100.200/latest/meta-data/region-id 2>/dev/null || echo "unknown")
    echo "  区域: $REGION"
  else
    warn "无法访问阿里云元数据服务（100.100.100.200）"
  fi
else
  warn "curl 未安装，跳过元数据检查"
fi
echo ""

# ---------- 13. 时间同步 chronyd ----------
info "[13/20] 检查时间同步 chronyd"
if pidof chronyd > /dev/null; then
  pass "chronyd 进程运行中"
  chronyc tracking 2>/dev/null | head -5 || echo "  (chronyc tracking 不可用)"
else
  warn "chronyd 进程未运行"
fi
echo ""

# ---------- 14. 内存使用 ----------
info "[14/20] 检查内存使用"
free -h
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
MEM_USED=$(free -m | grep Mem | awk '{print $3}')
MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
echo "  内存使用率: ${MEM_PERCENT}%"
if [ $MEM_PERCENT -lt 80 ]; then
  pass "内存使用正常"
else
  warn "内存使用率较高: ${MEM_PERCENT}%"
fi
echo ""

# ---------- 15. 磁盘 I/O 性能简测 ----------
info "[15/20] 磁盘 I/O 性能简测"
echo "  写入测试（100MB）..."
dd if=/dev/zero of=/tmp/test-io bs=1M count=100 oflag=direct 2>&1 | grep -E 'copied|MB/s'
rm -f /tmp/test-io
pass "磁盘 I/O 测试完成"
echo ""

# ---------- 16. apk 包管理器 ----------
info "[16/20] 检查 apk 包管理器"
if apk update > /dev/null 2>&1; then
  pass "apk update 成功"
else
  mark_fail "apk update 失败"
fi
echo ""

# ---------- 17. 安装测试包（nano） ----------
info "[17/20] 测试安装软件包（nano）"
if command -v nano > /dev/null 2>&1; then
  echo "  nano 已安装，跳过"
  pass "nano 可用"
else
  echo "  安装 nano..."
  if apk add --no-cache nano > /dev/null 2>&1; then
    pass "nano 安装成功"
  else
    mark_fail "nano 安装失败"
  fi
fi
echo ""

# ---------- 18. Docker 安装与测试 ----------
info "[18/20] Docker 安装与测试"
if command -v docker > /dev/null 2>&1; then
  echo "  Docker 已安装"
else
  echo "  安装 Docker..."
  if apk add --no-cache docker > /dev/null 2>&1; then
    pass "Docker 安装成功"
  else
    mark_fail "Docker 安装失败"
    echo ""
    info "[19/20] 跳过 Docker 服务测试"
    echo ""
    info "[20/20] 跳过 Docker 容器测试"
    echo ""
    goto_summary=1
  fi
fi

if [ "${goto_summary:-0}" -eq 0 ]; then
  # ---------- 19. Docker 服务启动 ----------
  info "[19/20] Docker 服务启动"
  if ! rc-service docker status > /dev/null 2>&1; then
    echo "  启动 Docker 服务..."
    rc-service docker start > /dev/null 2>&1
    sleep 3
  fi

  # 检查 dockerd 是否运行
  DOCKER_RETRY=0
  while [ $DOCKER_RETRY -lt 5 ]; do
    if pidof dockerd > /dev/null 2>&1; then
      break
    fi
    sleep 1
    DOCKER_RETRY=$((DOCKER_RETRY + 1))
  done

  if pidof dockerd > /dev/null; then
    pass "Docker daemon 运行中"
    # 加入开机自启
    if ! rc-update show default | grep -q docker; then
      rc-update add docker default > /dev/null 2>&1
      echo "  已加入开机自启"
    fi
  else
    mark_fail "Docker daemon 未运行"
    echo "  尝试查看日志："
    tail -10 /var/log/docker.log 2>/dev/null || echo "    无日志文件"
  fi
  echo ""

  # ---------- 20. Docker 容器测试 ----------
  info "[20/20] Docker 容器测试（hello-world）"
  echo "  拉取并运行 hello-world 镜像..."
  if timeout 60 docker run --rm hello-world > /tmp/docker-test.log 2>&1; then
    pass "Docker 容器运行成功"
    echo "  输出："
    cat /tmp/docker-test.log | head -10
  else
    mark_fail "Docker 容器运行失败"
    echo "  错误日志："
    cat /tmp/docker-test.log
  fi
  echo ""
fi

# ---------- 总结 ----------
echo "========================================"
if [ $FAILED_TESTS -eq 0 ]; then
  echo "${GREEN}✓ 所有测试通过！${NC}"
else
  echo "${RED}✗ ${FAILED_TESTS} 项测试失败${NC}"
fi
echo "========================================"
echo ""
echo "关键指标："
echo "  - 文件系统: $ROOT_FS"
echo "  - 压缩: $(echo "$MOUNT_OPTS" | grep -oE 'compress(-force)?=zstd[^,]*')"
echo "  - 子卷: $(echo "$MOUNT_OPTS" | grep -oE 'subvol=/[^,]*')"
echo "  - 磁盘大小: $DISK_SIZE (物理 ${PHYSICAL_SIZE_GB}GB)"
echo "  - IPv4: ${IPV4:-无}"
echo "  - cloud-init: $CI_STATUS"
echo "  - 内存使用: ${MEM_PERCENT}%"
echo ""

exit $FAILED_TESTS
