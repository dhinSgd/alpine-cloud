# 阿里云 ECS 部署指南

## 步骤 1：选择对应启动方式的镜像

| ECS 规格族 | 选择 |
|-----------|------|
| g7/c7/g8/c8 等新规格 | `uefi.qcow2`（推荐） |
| g6/c6 等老规格      | `bios.qcow2` |

不确定时，可在 ECS 控制台**实例规格详情**查看“启动模式”。

## 步骤 2：上传到阿里云 OSS

阿里云镜像导入要求镜像存放在与目标 region 同地域的 OSS bucket 中。

### 创建 bucket（如已存在跳过）

OSS 控制台 → 新建 Bucket：

- 地域：与目标 ECS 同地域
- 读写权限：私有
- 存储类型：标准

### 用 ossutil 上传

```bash
# 安装 ossutil
curl -O https://gosspublic.alicdn.com/ossutil/1.7.16/ossutil64
chmod +x ossutil64 && sudo mv ossutil64 /usr/local/bin/ossutil

# 配置（按提示填 AK/SK/endpoint）
ossutil config

# 分片上传（推荐）
ossutil cp -u slim-alpine-3.23.4-uefi.qcow2 \
  oss://<your-bucket>/slim-alpine-3.23.4-uefi.qcow2 \
  --part-size 104857600 --parallel 8
```

也可在 OSS 控制台直接拖拽上传。

## 步骤 3：导入自定义镜像

阿里云 ECS 控制台 → **镜像** → **自定义镜像** → **从 OSS 导入镜像**：

| 字段 | 取值 |
|-----|------|
| OSS 对象地址 | 上传后的对象 URL（无须公开访问） |
| 镜像名称 | 例如 `slim-alpine-3.23.4-uefi` |
| 镜像格式 | `qcow2` |
| 操作系统平台 | `Linux` |
| 系统盘大小 (GiB) | ≥ `1`，推荐 `20` 或更大（btrfs 首启自动扩容） |
| 架构 | `x86_64` |
| 系统版本 | `Others Linux` |
| 启动模式 | 与镜像匹配（`uefi.qcow2` 选 UEFI，`bios.qcow2` 选 BIOS） |

> 首次导入需授权 ECS 访问 OSS，控制台会提示一键开通。

导入是异步的，等待镜像状态从「等待中」变为「可用」（通常 3-10 分钟）。

## 步骤 4：创建 ECS 实例

ECS 控制台 → **创建实例** → **镜像** 处选择**自定义镜像**：

- 选择上一步导入的镜像
- 实例规格：与镜像启动模式匹配
- 网络：按需选择 VPC/安全组（开放 22 端口）
- 系统盘大小：≥ 1GB（建议 ≥ 20GB）
- **登录凭证**：可使用「自定义密码」或「密钥对」
  - 使用密钥对：cloud-init 会注入到 `/root/.ssh/authorized_keys`
  - 使用密码：会覆盖镜像内置的 `slimalpine123`

## 步骤 5：登录与初始化

```bash
ssh root@<公网IP>
# 首次输入密码 slimalpine123（如未在控制台覆盖）
```

进入后第一时间：

```bash
# 1. 修改密码
passwd

# 2. 校验自动扩容是否生效
df -hT /
btrfs filesystem usage /

# 3. 校验时间同步
chronyc tracking
```

## 常用维护操作

### 手动扩容（cloud-init 未生效时的兜底）

```bash
# 找到根设备
ROOTDEV=$(findmnt -n -o SOURCE /)
DISK=$(lsblk -no PKNAME "$ROOTDEV")

# 扩展分区
growpart "/dev/$DISK" "$(echo "$ROOTDEV" | grep -oE '[0-9]+$')"

# 扩展 btrfs
btrfs filesystem resize max /
```

### 查看 btrfs 压缩效果

```bash
apk add compsize 2>/dev/null || true
compsize / 2>/dev/null || btrfs filesystem du /
```

### 关闭/重启服务

```bash
service chronyd restart
service sshd restart
```

## 安全建议

- ✅ 首次登录立即改密码
- ✅ 仅开放必要端口（22、80、443 等）
- ✅ 用密钥对而非密码登录
- ✅ 修改默认 SSH 端口 / 安装 fail2ban
- ✅ 定期 `apk update && apk upgrade`
