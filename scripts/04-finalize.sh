#!/usr/bin/env bash
# 阶段 4: 输出最终 qcow2 + 严格自检 + 校验和
#   - qemu-img convert -p -O qcow2（v3 默认，不压缩，最大兼容）
#   - 通过 qemu-img info JSON 自检格式合规
#   - qemu-img check 结构检查
#   - 生成 SHA256

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

parse_args "$@"
require_root
load_source_env
require_cmd qemu-img sha256sum python3

log_info "阶段 4 (finalize) - 启动 [boot=${BOOT_TYPE}]"

INPUT="$BUILD_DIR/output-${BOOT_TYPE}.img"
OUTPUT="$OUTPUT_DIR/slim-alpine-${ALPINE_VERSION}-${BOOT_TYPE}.qcow2"

[ -f "$INPUT" ] || die "未找到输入镜像: $INPUT（先跑 03-build-image.sh）"

ensure_dir "$OUTPUT_DIR"
rm -f "$OUTPUT" "${OUTPUT}.sha256"

# ---------- 1. 转换为 qcow2 ----------

log_info "qemu-img convert (raw -> qcow2 v3 默认参数)"
qemu-img convert -p -O qcow2 "$INPUT" "$OUTPUT"

# ---------- 2. qemu-img info 自检 ----------

log_info "=== qemu-img info ==="
qemu-img info "$OUTPUT"

log_info "格式合规性自检"

# 通过 python3 解析 JSON 做严格断言
python3 - "$OUTPUT" <<'PY_EOF'
import json, subprocess, sys

img = sys.argv[1]
info = json.loads(subprocess.check_output(
    ["qemu-img", "info", "--output=json", img]))

errors = []

if info.get("format") != "qcow2":
    errors.append(f"format 错误: {info.get('format')!r}, 期望 'qcow2'")

fmt = info.get("format-specific", {}) or {}
if fmt.get("type") != "qcow2":
    errors.append(f"format-specific.type 错误: {fmt.get('type')!r}")
else:
    data = fmt.get("data", {}) or {}
    compat = data.get("compat")
    if compat not in ("1.1", "0.10"):
        errors.append(f"compat 异常: {compat!r}, 期望 '1.1' 或 '0.10'")
    if data.get("encrypt"):
        errors.append("不应有加密 (encrypt=True)")
    if data.get("compression-type"):
        errors.append(f"不应有 compression-type: {data['compression-type']!r}")
    if data.get("extended-l2"):
        errors.append("不应启用 extended-l2 (阿里云不支持)")

if errors:
    print("\n❌ 格式自检失败:")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)

print("✅ 格式自检通过")
PY_EOF

# ---------- 3. qemu-img check ----------

log_info "qemu-img check（结构损坏检测）"
qemu-img check "$OUTPUT"

# ---------- 4. 生成 SHA256 ----------

log_info "生成 SHA256"
( cd "$OUTPUT_DIR" && sha256sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256" )

log_ok "=== 最终产物 ==="
ls -lh "$OUTPUT" "${OUTPUT}.sha256"
echo
cat "${OUTPUT}.sha256"

log_ok "阶段 4 (finalize) 完成"
