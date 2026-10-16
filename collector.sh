#!/bin/bash
# collector.sh — сбор метрик хоста, вывод одной строки JSON
# Принудительно C-локаль, чтобы printf/awk не портили числа запятыми.
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

# CPU usage — два снимка /proc/stat
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

# Все реальные файловые системы (JSON-массив)
# Исключаем tmpfs, devtmpfs, squashfs, overlay и служебные разделы.
DISKS_JSON=$(df -kT 2>/dev/null | awk '
BEGIN { printf "["; first=1 }
NR>1 {
    fstype = $2
    if (fstype !~ /^(ext2|ext3|ext4|xfs|btrfs|zfs|f2fs|vfat|ntfs|exfat)$/) next

    # монтирование может содержать пробелы — берём с 7-го поля и далее
    mount = $7
    for (i = 8; i <= NF; i++) mount = mount " " $i

    # пропускаем служебные
    if (mount == "/boot" || mount == "/boot/efi") next
    if (mount ~ /^\/snap/) next
    if (mount ~ /^\/var\/lib\/docker/) next
    if (mount ~ /^\/run\//) next

    pct = $6
    gsub(/%/, "", pct)

    if (!first) printf ","
    first = 0
    printf "{\"mount\":\"%s\",\"fstype\":\"%s\",\"total_kb\":%d,\"used_kb\":%d,\"pct\":%d}", mount, fstype, $3, $4, pct
}
END { printf "]" }
')

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

# Сеть — сумма по всем не-lo интерфейсам
read -r NET_RX NET_TX <<< "$(awk 'NR>2 {
    iface=$1; sub(/:$/, "", iface);
    if (iface != "lo" && iface !~ /^(docker|veth|br-)/) { rx+=$2; tx+=$10 }
} END { printf "%d %d", rx+0, tx+0 }' /proc/net/dev)"

# Топ-5 процессов по CPU
TOP=$(ps -eo pcpu=,comm= --sort=-pcpu 2>/dev/null | head -5 \
      | awk '{cpu=$1; $1=""; sub(/^[ \t]+/, ""); printf "%s:%.1f;", $0, cpu}')
TOP=${TOP%;}

# Вывод JSON
printf '{"hostname":"%s","uptime":%d,"load":"%s %s %s","cores":%d,"cpu_pct":%s,"mem_total_kb":%d,"mem_used_kb":%d,"mem_pct":%s,"swap_total_kb":%d,"swap_used_kb":%d,"disks":%s,"temp_c":%d,"net_rx":%d,"net_tx":%d,"top":"%s"}\n' \
    "$HOSTNAME" "$UPTIME" "$L1" "$L5" "$L15" "$CORES" "$CPU_PCT" \
    "$MEM_TOTAL" "$MEM_USED" "$MEM_PCT" "$SWAP_TOTAL" "$SWAP_USED" \
    "$DISKS_JSON" "$TEMP_C" "$NET_RX" "$NET_TX" "$TOP"
