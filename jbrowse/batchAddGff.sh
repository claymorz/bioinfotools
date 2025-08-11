#!/bin/bash
# 批量添加 GFF 到 JBrowse 脚本
# - 使用最长公共子串匹配 Assembly
# - 支持 debug 模式
# - 支持 force 模式
# - 支持 dry-run 模式
# - 支持 threshold 动态阈值

set -euo pipefail

DEBUG=false
FORCE=false
DRY_RUN=false
THRESHOLD=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) DEBUG=true; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    *) INPUT_DIR="$1"; shift ;;
  esac
done

if [[ -z "${INPUT_DIR:-}" ]]; then
  echo "用法: $0 <目录路径> [--debug] [--force] [--dry-run] [--threshold N]"
  exit 1
fi

OUTPUT_DIR="/bjued/jbrowse/gff"
CONFIG_FILE="/bjued/jbrowse/config.json"
LOG_FILE="./batchAddGff.log"
SUMMARY_FILE="./summary.csv"

mkdir -p "$OUTPUT_DIR"
echo "==== 批量添加 GFF $(date) ====" > "$LOG_FILE"
echo "文件名,Assembly 名称,状态,公共子串长度,错误信息" > "$SUMMARY_FILE"

if $DEBUG; then
  set -x
  trap 'echo "❌ 错误发生在文件: $current_file, 行号: $LINENO, 退出码: $?"' ERR
fi

shopt -s nullglob nocaseglob
matched_files=("$INPUT_DIR"/*.gff*)
total_files=${#matched_files[@]}

echo "共匹配到 $total_files 个 GFF 文件" | tee -a "$LOG_FILE"

success_count=0
fail_count=0
skip_count=0

# ========== 函数：最长公共子串长度 ==========
longest_common_substring() {
  echo "$1 $2" | awk '
  {
    s1=$1; s2=$2;
    l1=length(s1); l2=length(s2);
    max=0;
    for(i=1;i<=l1;i++){
      for(j=1;j<=l2;j++){
        k=0;
        while(i+k<=l1 && j+k<=l2 && substr(s1,i+k,1)==substr(s2,j+k,1)){
          k++;
          if(k>max) max=k;
        }
      }
    }
    print max;
  }'
}

assemblies=($(grep -oP '"name":\s*"\K[^"]+' "$CONFIG_FILE"))

for file in "${matched_files[@]}"; do
  current_file="$file"
  [[ -f "$file" ]] || continue
  file=$(realpath "$file")
  filename=$(basename "$file")

  echo "==== 处理文件: $file ====" | tee -a "$LOG_FILE"

  # 定义最终文件名
  sorted_gff_gz="${file%.gz}.sorted.gff.gz"
  tbi_file="${sorted_gff_gz}.tbi"

  # 匹配 Assembly
  base_name=$(echo "$filename" | sed -E 's/(\.MAC.*|\.GFF.*|\.gff.*)//g')
  best_match=""
  best_score=0

  for asm in "${assemblies[@]}"; do
    lcs_len=$(longest_common_substring "$base_name" "$asm")
    if (( lcs_len > best_score )); then
      best_score=$lcs_len
      best_match=$asm
    fi
  done

  if (( best_score >= THRESHOLD )); then
    assembly_name="$best_match"
    echo "✅ 匹配到 Assembly: $assembly_name (公共子串长度=$best_score)"
  else
    echo "⚠️ 未找到匹配的 Assembly (LCS=$best_score)，跳过添加"
    echo "$filename,,未找到 Assembly,$best_score,LCS 低于阈值" >> "$SUMMARY_FILE"
    skip_count=$((skip_count+1))
    continue
  fi

  # Dry-run 模式
  if $DRY_RUN; then
    echo "🟡 Dry-run: 将处理文件 $filename，匹配 Assembly=$assembly_name，公共子串长度=$best_score"
    echo "$filename,$assembly_name,DRY-RUN,$best_score," >> "$SUMMARY_FILE"
    continue
  fi

  # 如果文件和索引已存在，默认跳过
  if [[ -f "$sorted_gff_gz" && -f "$tbi_file" && $FORCE == false ]]; then
    echo "⚠️ 已存在压缩文件和索引，跳过重建: $sorted_gff_gz"
    echo "$filename,$assembly_name,已存在跳过,$best_score," >> "$SUMMARY_FILE"
    skip_count=$((skip_count+1))
    continue
  fi

  # 检查文件是否为 .gz 文件
  if [[ "$filename" == *.gz ]]; then
    # 如果是 .gz 文件，进行解压
    $DEBUG && echo "👉 开始解压: $file"
    temp_gff="${file%.gz}"
    gunzip -c "$file" > "$temp_gff"
    $DEBUG && echo "✅ 解压完成: $temp_gff"
  else
    # 非 .gz 文件，跳过解压，直接使用原文件
    temp_gff="$file"
    $DEBUG && echo "👉 跳过解压，直接使用文件: $temp_gff"
  fi

  # 初始化 filtered_count 变量，防止未赋值
  filtered_count=0

  # 排序部分，优先检查 jbrowse sort-gff 是否可用
  if command -v jbrowse &> /dev/null && jbrowse sort-gff --help &> /dev/null; then
    echo "👉 使用 jbrowse sort-gff 进行排序"
    sorted_gff="${temp_gff%.gff}.sorted.gff"  # 给排序结果指定文件名
    jbrowse sort-gff "$temp_gff" > "$sorted_gff"
    sorted_status="jbrowse_sort"
  else
    echo "👉 jbrowse sort-gff 不可用，使用默认排序方法"
    sorted_gff="${temp_gff%.gff}.sorted.gff"  # 给排序结果指定文件名
    filtered_count=$(grep -v "^#" "$temp_gff" | awk '!(NF>=9 && $5>=$4)' | wc -l)
    (grep "^#" "$temp_gff";
     grep -v "^#" "$temp_gff" | awk 'NF>=9 && $5>=$4' | sort -t"$(printf '\t')" -k1,1 -k4,4n
    ) > "$sorted_gff"
    sorted_status="awk_sort"
  fi

  # 输出排序结果
  echo "✅ 排序完成，使用方式：$sorted_status，过滤掉非法行数: $filtered_count"

  # 压缩
  $DEBUG && echo "👉 开始 bgzip 压缩"
  bgzip -c "$sorted_gff" > "$sorted_gff_gz"
  rm -f "$temp_gff" "$sorted_gff"
  $DEBUG && echo "✅ 压缩完成: $sorted_gff_gz"

  # 索引
  $DEBUG && echo "👉 开始建立索引"
  if ! tabix -f -p gff "$sorted_gff_gz"; then
    echo "❌ 索引创建失败: $sorted_gff_gz" | tee -a "$LOG_FILE"
    echo "$filename,$assembly_name,索引失败,$best_score,tabix 创建索引失败" >> "$SUMMARY_FILE"
    rm -f "$sorted_gff_gz"
    fail_count=$((fail_count+1))
    continue
  fi
  $DEBUG && echo "✅ 索引完成: $tbi_file"

  # 检查重复 Track
  track_name=$(basename "$sorted_gff_gz")
  if grep -q "\"name\": \"$track_name\"" "$CONFIG_FILE"; then
    echo "⚠️ Track $track_name 已存在，跳过添加"
    echo "$filename,$assembly_name,已存在跳过,$best_score,Track 已存在" >> "$SUMMARY_FILE"
    skip_count=$((skip_count+1))
    continue
  fi

  # 添加 Track
  jbrowse_output=$(jbrowse add-track "$sorted_gff_gz" \
    --name "$track_name" \
    --load symlink \
    --out "$OUTPUT_DIR" \
    --assemblyNames "$assembly_name" \
    --target="$CONFIG_FILE" 2>&1) || {
      echo "❌ 添加失败 $filename" | tee -a "$LOG_FILE"
      echo "$filename,$assembly_name,添加失败,$best_score,${jbrowse_output//$'\n'/ }" >> "$SUMMARY_FILE"
      fail_count=$((fail_count+1))
      continue
  }

  echo "✅ 成功添加 $filename" | tee -a "$LOG_FILE"
  echo "$filename,$assembly_name,成功,$best_score," >> "$SUMMARY_FILE"
  success_count=$((success_count+1))

done

echo "=== 全部 GFF 文件处理完成 $(date) ===" | tee -a "$LOG_FILE"
echo "总文件数: $total_files, 成功: $success_count, 失败: $fail_count, 跳过: $skip_count" | tee -a "$LOG_FILE"
echo "已生成结果 CSV: $SUMMARY_FILE"
