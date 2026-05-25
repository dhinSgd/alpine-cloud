# Alpine Cloud 镜像项目 TODO

## 当前状态（2026-05-25）

### ✅ 已完成
- [x] 移除 BIOS 支持，专注 UEFI + qcow2
- [x] 移除 `--boot` 参数，所有脚本硬编码 UEFI
- [x] 设置默认主机名为 `simplealpine`
- [x] 修复 VNC 黑屏问题（kernel cmdline console 顺序）
- [x] 增强 boot test 断言（9 项检查）
- [x] 创建阿里云 ECS 全面测试脚本（20 项检查）
- [x] 修复测试脚本 Alpine 兼容性问题
  - lsblk 缺失 → fdisk 兜底
- [x] **添加 SSH 密钥注入支持（双轨）**
  - cloud-init 配置加固：`disable_root: false` + `system_info.default_user: root`
  - 构建期注入：`SSH_AUTHORIZED_KEYS` 环境变量 → `/root/.ssh/authorized_keys`
  - 构建期日志只打印指纹（不泄漏公钥）
  - boot test 增加 Stage 10：SSH 公钥落盘校验（含 cat 内容）
  - 阿里云测试增加 BONUS：云上 cloud-init 自动注入验证
  - GitHub Actions 集成：secret `TEST_SSH_PUBLIC_KEY` 自动注入
  - 保留密码登录通道作为兜底
### 🔄 进行中
- [ ] **用户验证新镜像 VNC 修复效果**
  - 当前用户在旧镜像上完成了基础测试（btrfs/网络/Docker 均正常）
  - 需要销毁当前实例，用新镜像（含 VNC 修复）创建实例
  - 验证 VNC 控制台能否显示启动日志

---

## 短期任务（本周）

### 1. 验证与测试
- [ ] 用户在阿里云 ECS 验证新镜像 VNC 显示正常
- [ ] 运行完整 `test-aliyun-full.sh` 脚本（20 项测试）
- [ ] 确认所有测试项通过（特别是 Docker 工作流）

### 2. 文档完善
- [ ] 更新 README.md 添加阿里云部署指南
  - 导入自定义镜像步骤
  - 创建实例注意事项（VNC/串口控制台）
  - 首次登录配置（修改 root 密码）
- [ ] 补充测试脚本使用说明
  - `test-aliyun.sh` - 基础 12 项测试
  - `test-aliyun-full.sh` - 完整 20 项测试（含 Docker）

### 3. CI/CD 优化
- [ ] GitHub Actions 添加测试覆盖率报告
- [ ] 考虑添加多区域测试（不同云平台）

---

## 中期任务（本月）

### 1. 功能增强
- [ ] 支持自定义 cloud-init 配置注入
- [ ] 添加镜像压缩优化（进一步减小体积）

### 2. 安全加固
- [x] 添加 SSH 密钥注入支持（cloud-init）

### 3. 性能优化
- [ ] 分析 btrfs zstd:9 压缩率与性能平衡
- [ ] 测试不同 btrfs mount 选项（commit 间隔、discard 策略）
- [ ] 对比其他文件系统（ext4/xfs）的性能差异

---

---

## 已知问题与限制

### 设计决策
- **cgroups 不自动启动**：维持 Alpine 极简哲学，用户需要 Docker 时手动启动
  - 解决方案：测试脚本中自动处理
  - 未来考虑：可选的 "Docker 预配置" 变体镜像

### 技术限制
- **仅支持 UEFI**：不支持传统 BIOS 启动
- **磁盘扩容依赖 cloud-init**：手动部署需要手动扩容分区
- **默认 root 密码**：`slimalpine123`（部署后需立即修改）

---

## 参考资料

### 相关文档
- [设计文档](./2026-05-24-slim-alpine-cloud-image-design.md)
- [错误修复记录](./2026-05-24-slim-alpine-cloud-image-errorfix.md)

### 测试脚本
- `/workspace/alpine-cloud/test-aliyun.sh` - 基础测试
- `/workspace/alpine-cloud/test-aliyun-full.sh` - 完整测试

### 构建脚本
- `scripts/00-prepare.sh` - 下载官方镜像
- `scripts/01-extract.sh` - 提取 rootfs
- `scripts/02-customize.sh` - 定制系统
- `scripts/03-build-image.sh` - 构建目标镜像
- `scripts/04-finalize.sh` - 转换格式
- `scripts/05-test-boot.sh` - 启动测试

---

## 下一步行动

**立即执行**：
1. 等待用户在阿里云验证新镜像 VNC 修复效果
2. 根据用户反馈调整（如有问题）

**本周内**：
1. 完善 README.md 部署指南
2. 补充测试脚本文档

**持续跟进**：
1. 收集用户使用反馈
2. 优化构建流程
3. 探索多云支持可能性
