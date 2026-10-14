#!/bin/bash
# collector.sh — сбор метрик хоста, вывод одной строки JSON
# Принудительно ставим C-локаль, чтобы printf/awk не портили числа запятыми.
export LC_ALL=C
export LANG=C
set -u

HOSTNAME=$(hostname)

# Uptime (секунды)
UPTIME=$(awk '{print int($1)}' /proc/uptime)

# Load average
read -r L1 L5 L15 _ < /proc/loadavg

# Ядра CPU
CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)

# CPU usage — два снимка /proc/stat с интервалом 0.4с
cpu_snap() {
    awk '/^cpu / {t=0; for(i=2;i<=NF;i++) t+=$i; idle=$5+$6; print t, idle}' /proc/stat
}
read -r T1 I1 <<< "$(cpu_snap)"
sleep 0.4
read -r T2 I2 <<< "$(cpu_snap)"
DT=$((T2 - T1))
DI=$((I2 - I1))
if [ "$DT" -gt 0 ]; then
    CPU_PCT=$(awk "BEGIN {printf \"%.1f\", 100 * ($DT - $DI) / $DT}")
else
    CPU_PCT="0.0"
fi

# Память (kB)
MEM_TOTAL=$(awk '/^MemTotal:/     {print $2}' /proc/meminfo)
MEM_AVAIL=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
MEM_PCT=$(awk "BEGIN {printf \"%.1f\", 100 * $MEM_USED / $MEM_TOTAL}")

# Swap (kB)
SWAP_TOTAL=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
SWAP_FREE=$(awk  '/^SwapFree:/  {print $2}' /proc/meminfo)
SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))

# Disk / (kB)
DISK_LINE=$(df -k / | awk 'NR==2 {print $2, $3, $5}')
read -r DISK_TOTAL DISK_USED DISK_PCT_RAW <<< "$DISK_LINE"
DISK_PCT=${DISK_PCT_RAW%\%}

# Температура (°C)
TEMP_C=0
for tz in /sys/class/thermal/thermal_zone*/temp; do
    if [ -r "$tz" ]; then
        T=$(cat "$tz" 2>/dev/null || echo 0)
        T=${T%%.*}
        if [ -n "$T" ] && [ "$T" -gt 0 ] 2>/dev/null; then
            if [ "$T" -gt 1000 ]; then
                TEMP_C=$((T / 1000))
            else
                TEMP_C=$T
            fi
            break
        fi
    fi
done

# Сеть — сумма по всем не-lo интерфейсам. Принудительно целые через %d.
read -r NET_RX NET_TX <<< "$(awk 'NR>2 {
    iface=$1; sub(/:$/, "", iface);
    if (iface != "lo" && iface !~ /^(docker|veth|br-)/) { rx+=$2; tx+=$10 }
} END { printf "%d %d", rx+0, tx+0 }' /proc/net/dev)"

# Топ-3 процесса по CPU
TOP=$(ps -eo pcpu=,comm= --sort=-pcpu 2>/dev/null | head -3 \
      | awk '{cpu=$1; $1=""; sub(/^[ \t]+/, ""); printf "%s:%.1f;", $0, cpu}')
TOP=${TOP%;}

# Вывод JSON одной строкой
printf '{"hostname":"%s","uptime":%d,"load":"%s %s %s","cores":%d,"cpu_pct":%s,"mem_total_kb":%d,"mem_used_kb":%d,"mem_pct":%s,"swap_total_kb":%d,"swap_used_kb":%d,"disk_total_kb":%d,"disk_used_kb":%d,"disk_pct":%s,"temp_c":%d,"net_rx":%d,"net_tx":%d,"top":"%s"}\n' \
    "$HOSTNAME" "$UPTIME" "$L1" "$L5" "$L15" "$CORES" "$CPU_PCT" \
    "$MEM_TOTAL" "$MEM_USED" "$MEM_PCT" "$SWAP_TOTAL" "$SWAP_USED" \
    "$DISK_TOTAL" "$DISK_USED" "$DISK_PCT" "$TEMP_C" "$NET_RX" "$NET_TX" "$TOP"
