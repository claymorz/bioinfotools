#!/bin/bash
set -euo pipefail

# ====== 默认配置 ======
JBROWSE_DIR="/bjued/jbrowse"
CONFIG_JSON="$JBROWSE_DIR/config.json"
DRY_RUN=0
THRESHOLD=10
SUMMARY_FILE="./bam_add_summary.tsv"

usage() {
    echo "Usage: $0 <bam_directory> [--dry-run] [--threshold N]"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

INPUT_DIR=$1
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --threshold)
            THRESHOLD=$2
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

# ====== 检查依赖 ======
command -v samtools >/dev/null 2>&1 || { echo "samtools 未安装"; exit 1; }
command -v jbrowse >/dev/null 2>&1 || { echo "jbrowse 未安装"; exit 1; }

# ====== 提取 assemblies 和 tracks 名称 (兼容 awk) ======
ASSEMBLIES=$(awk '
    /"assemblies"[[:space:]]*:/ {in_assemblies=1}
    in_assemblies && /"name"[[:space:]]*:/ {
        line=$0
        sub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/".*$/, "", line)
        if (line != "") print line
    }
    in_assemblies && /\]/ {in_assemblies=0}
' "$CONFIG_JSON" | sort -u)

EXISTING_TRACKS=$(awk '
    /"tracks"[[:space:]]*:/ {in_tracks=1}
    in_tracks && /"name"[[:space:]]*:/ {
        line=$0
        sub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/".*$/, "", line)
        if (line != "") print line
    }
    in_tracks && /\]/ {in_tracks=0}
' "$CONFIG_JSON" | sort -u)

echo "🔎 检测到 Assemblies: $ASSEMBLIES"
echo "🔎 已有 Tracks: $EXISTING_TRACKS"

# ====== 计算最长公共子串长度 ======
similarity_score() {
    local str1="$1"
    local str2="$2"
    local len1=${#str1}
    local len2=${#str2}
    local max_common=0

    for ((i=0; i<len1; i++)); do
        for ((j=0; j<len2; j++)); do
            local k=0
            while [[ $((i+k)) -lt $len1 && $((j+k)) -lt $len2 && "${str1:i+k:1}" == "${str2:j+k:1}" ]]; do
                ((k++))
            done
            (( k > max_common )) && max_common=$k
        done
    done
    echo $max_common
}

# ====== 找到最相似的物种名 ======
closest_match() {
    local filename="$1"
    local best_match=""
    local best_score=0

    for assembly in $ASSEMBLIES; do
        score=$(similarity_score "$(echo "$filename" | tr 'A-Z' 'a-z')" "$(echo "$assembly" | tr 'A-Z' 'a-z')")
        if (( score > best_score )); then
            best_score=$score
            best_match=$assembly
        fi
    done

    if (( best_score < THRESHOLD )); then
        echo ""
    else
        echo "$best_match:$best_score"
    fi
}

# ====== 初始化汇总文件 ======
echo -e "BAM_File\tSpecies\tScore\tAction" > "$SUMMARY_FILE"

# ====== 遍历 BAM 文件 ======
find "$INPUT_DIR" -type f -iname "*.bam" -print0 | while IFS= read -r -d '' bam_file; do
    filename=$(basename "$bam_file")
    track_name="${filename%.bam}"

    echo "==== 处理文件: $bam_file ===="
    action=""

    # 1. 建立索引
    if [ ! -f "${bam_file}.bai" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[Dry-run] 将建立索引: $bam_file"
        else
            echo "建立索引: $bam_file"
            samtools index "$bam_file"
        fi
    fi

    # 2. 检查是否已有该 track
    if echo "$EXISTING_TRACKS" | grep -Fxq "$track_name"; then
        echo "跳过：Track '$track_name' 已存在"
        action="Skipped (exists)"
        echo -e "$filename\t-\t-\t$action" >> "$SUMMARY_FILE"
        continue
    fi

    # 3. 找到物种名
    match_result=$(closest_match "$track_name")
    if [ -z "$match_result" ]; then
        echo "❌ 未找到匹配的物种名（低于阈值 $THRESHOLD），跳过"
        action="No match"
        echo -e "$filename\t-\t-\t$action" >> "$SUMMARY_FILE"
        continue
    fi

    species="${match_result%%:*}"
    score="${match_result##*:}"
    echo "✅ 匹配到物种名：$species (score=$score)"

    # 4. 添加 track
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[Dry-run] 将添加 track: $track_name -> $species"
        action="Dry-run add"
    else
        echo "添加 track: $track_name"
        jbrowse add-track "$bam_file" \
            --load symlink \
            --out "$JBROWSE_DIR" \
            --assemblyNames "$species" \
            --name "$track_name" \
            --target "$CONFIG_JSON"
        action="Added"
    fi

    # 记录汇总
    echo -e "$filename\t$species\t$score\t$action" >> "$SUMMARY_FILE"

done

echo "=== 处理完成，汇总表格已生成: $SUMMARY_FILE ==="
