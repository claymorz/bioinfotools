#!/bin/bash
# 批量处理指定目录下的 .gz 文件
# 1. 解压
# 2. 建立 samtools 索引（若不存在）
# 3. 检查 config.json 是否已添加
# 4. 添加到 jbrowse

set -euo pipefail

INPUT_DIR="$1"
OUTPUT_DIR="/bjued/jbrowse/fa"
CONFIG_FILE="/bjued/jbrowse/config.json"

# 检查参数
if [[ -z "$INPUT_DIR" ]]; then
  echo "用法: $0 <目录路径>"
  exit 1
fi

# 遍历目录下所有 .gz 文件
for gzfile in "$INPUT_DIR"/*.gz; do
  [[ -f "$gzfile" ]] || continue
  
  echo "==== 处理文件: $gzfile ===="
  
  # 解压后的文件名
  fasta_file="${gzfile%.gz}"
  
  # 1. 解压（兼容无 -k）
  if [[ ! -f "$fasta_file" ]]; then
    echo "解压 $gzfile"
    gunzip -c "$gzfile" > "$fasta_file"
  else
    echo "已存在解压文件，跳过解压: $fasta_file"
  fi
  
  # 2. 建立 samtools 索引
  if [[ ! -f "$fasta_file.fai" ]]; then
    echo "建立索引: $fasta_file"
    samtools faidx "$fasta_file" || {
      echo "❌ 索引失败，可能是行长不一致。请先修复 FASTA 格式。"
      continue
    }
  else
    echo "索引已存在，跳过: $fasta_file.fai"
  fi
  
  # 3. 从文件名提取物种名
  filename=$(basename "$fasta_file")
  species_name="${filename%%.fasta*}"
  
  # 4. 检查是否已添加到 jbrowse
  if [[ -f "$CONFIG_FILE" ]] && jq -e --arg name "$species_name" '.assemblies[] | select(.name==$name)' "$CONFIG_FILE" > /dev/null 2>&1; then
    echo "⚠️  $species_name 已在 JBrowse 中，跳过添加"
  else
    echo "添加到 JBrowse: 物种名 = $species_name"
    jbrowse add-assembly "$fasta_file" \
      --name "$species_name" \
      --load symlink \
      --out "$OUTPUT_DIR" \
      --target="$CONFIG_FILE"
  fi
  
  echo "✅ 完成 $filename"
  echo
done

echo "=== 全部文件处理完成 ==="
