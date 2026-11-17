#!/usr/bin/env bash
# =============================================================================
# idle-timeout.sh — 带"无输出看门狗"的命令执行包装
#
# 用法:
#   ./idle-timeout.sh -i <空闲秒数> [-t <总超时秒数>] -- <命令> [参数...]
#
#   -i  连续多少秒没有任何新输出就判定"卡死", 强制 kill -9(默认 10)
#       -i 0 表示关闭空闲看门狗(只保留 -t 的总超时), 适合有交互输入的场景
#   -t  总超时秒数, 到点无论有无输出都杀掉(默认 0 = 不限制)
#
# 注意: 空闲看门狗只看"输出是否停止", 不区分"在等我输入"。若要人工在提示符
#       上敲命令(u-boot => / shell), 请直接运行命令, 或加 -i 0。
#
# 退出码:
#   0    命令自行结束
#   124  被空闲看门狗杀掉(无响应)
#   125  被总超时杀掉
#
# 用途: QEMU 启动固件/裸机时经常"静默挂死"(没有任何串口输出), 直接跑会一直占住
#       终端; 用它包一层, 无输出超过阈值就杀掉, 并把已捕获的输出打印出来。
# =============================================================================
set -uo pipefail

idle_secs=10
total_secs=0

while [ $# -gt 0 ]; do
    case "$1" in
        -i) shift; idle_secs="${1:?-i 需要一个秒数}" ;;
        -t) shift; total_secs="${1:?-t 需要一个秒数}" ;;
        --) shift; break ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) break ;;
    esac
    shift
done

[ $# -gt 0 ] || { echo "用法: $0 -i <空闲秒数> [-t <总超时秒数>] -- <命令> [参数...]" >&2; exit 2; }

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

"$@" >"$out" 2>&1 &
pid=$!

start=$(date +%s)
last_size=0
idle_ticks=0
idle_ticks_max=$((idle_secs * 2))     # 每 0.5s 采样一次
result=0

while kill -0 "$pid" 2>/dev/null; do
    size=$(stat -c%s "$out" 2>/dev/null || echo 0)
    if [ "$size" -ne "$last_size" ]; then
        last_size=$size
        idle_ticks=0
    else
        idle_ticks=$((idle_ticks + 1))
    fi

    if [ "$idle_secs" -gt 0 ] && [ "$idle_ticks" -ge "$idle_ticks_max" ]; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        echo "[idle-timeout] ${idle_secs}s 无任何输出, 已强制终止: $*" >&2
        result=124
        break
    fi

    if [ "$total_secs" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$total_secs" ]; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        echo "[idle-timeout] 总超时 ${total_secs}s, 已强制终止: $*" >&2
        result=125
        break
    fi

    sleep 0.5
done

# 命令正常结束时回收退出码
if [ "$result" -eq 0 ]; then
    wait "$pid"
    result=$?
fi

if [ "$result" -eq 124 ] || [ "$result" -eq 125 ]; then
    if [ "$last_size" -eq 0 ]; then
        echo "[idle-timeout] 期间没有任何输出(串口/标准输出均为空)" >&2
    else
        echo "[idle-timeout] 最后 ${last_size} 字节输出见下:" >&2
    fi
fi

cat "$out"
exit "$result"
