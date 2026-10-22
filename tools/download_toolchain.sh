#!/usr/bin/env bash
# 分段并行下载大文件（用于国内访问 Arm 官方 CDN 慢的场景）
# 用法: ./download_toolchain.sh <URL> <输出文件> [分段数=8]
# 依赖: bash, curl, cat, rm, stat
# 原理: 服务器支持 Range 时，每段一个连接并行下载，绕开单连接限速。

set -u

URL="$1"
OUT="$2"
N="${3:-8}"

echo ">> 解析最终地址与文件大小..."
# 跟随重定向拿到最终 URL 和总大小
FINAL_URL=$(curl -sIL -o /dev/null -w '%{url_effective}' "$URL")
TOTAL=$(curl -sIL "$URL" | grep -i '^content-length:' | tail -1 | tr -dc '0-9')

if [ -z "$TOTAL" ] || [ "$TOTAL" -le 0 ]; then
    echo "!! 无法获取文件大小，退出"
    exit 1
fi
echo ">> 最终地址: $FINAL_URL"
echo ">> 总大小: $TOTAL 字节 ($(awk "BEGIN{printf \"%.1f\", $TOTAL/1048576}") MB), 分 $N 段"

SEG=$(( (TOTAL + N - 1) / N ))
TMPDIR_DL="${OUT}.parts"
mkdir -p "$TMPDIR_DL"

# 单段下载（手动计算续传偏移 + 大小校验，失败重试最多 8 轮）
# 注意：curl 的 `-C -` 与 `-r` 不能同时使用，必须自己算偏移并用 >> 追加写。
download_part() {
    local idx=$1
    local start=$(( idx * SEG ))
    local end=$(( (idx + 1) * SEG - 1 ))
    [ $end -ge $TOTAL ] && end=$(( TOTAL - 1 ))
    local want=$(( end - start + 1 ))
    local part="$TMPDIR_DL/part_$(printf '%02d' $idx)"

    for round in 1 2 3 4 5 6 7 8; do
        local have
        have=$(stat -c %s "$part" 2>/dev/null || echo 0)
        if [ "$have" = "$want" ]; then
            echo ">> 段 $idx 已完成 ($have/$want)"
            return 0
        fi
        local from=$(( start + have ))
        curl -s --retry 5 -r "${from}-${end}" "$FINAL_URL" >> "$part"
        local got
        got=$(stat -c %s "$part" 2>/dev/null || echo 0)
        if [ "$got" = "$want" ]; then
            echo ">> 段 $idx 完成 ($got/$want)"
            return 0
        fi
        echo ">> 段 $idx 不完整 ($got/$want)，第 $round 轮重试..."
        sleep 2
    done
    echo "!! 段 $idx 多次重试仍失败"
    return 1
}

for i in $(seq 0 $((N - 1))); do
    download_part "$i" &
done

FAIL=0
for job in $(jobs -p); do
    wait "$job" || FAIL=1
done
[ $FAIL -ne 0 ] && { echo "!! 有分段下载失败，保留 $TMPDIR_DL 可重跑续传"; exit 1; }

echo ">> 合并分段..."
cat "$TMPDIR_DL"/part_* > "$OUT"
GOT=$(stat -c %s "$OUT")
if [ "$GOT" = "$TOTAL" ]; then
    rm -rf "$TMPDIR_DL"
    echo ">> 下载完成: $OUT ($GOT 字节)，校验通过"
else
    echo "!! 合并后大小不符 ($GOT != $TOTAL)，保留 $TMPDIR_DL 排查"
    exit 1
fi
