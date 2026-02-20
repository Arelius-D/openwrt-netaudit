#!/bin/ash

R=$(printf '\033[0;31m')
G=$(printf '\033[0;32m')
Y=$(printf '\033[1;33m')
N=$(printf '\033[0m')
C=$(printf '\033[0;36m')
W=$(printf '\033[1;37m')

show_help() {
    echo "${W}=== Full Spectrum Site Survey ===${N}"
    echo "A dynamic OpenWrt utility for scanning WiFi channels across all radios and applying changes interactively."
    echo ""
    echo "${C}Usage:${N} $0 [OPTIONS]"
    echo ""
    echo "${C}Options:${N}"
    echo "  -h, --help   Show this help message and exit"
    echo "  -s, --scan   Scan-only mode: print results and exit without interaction"
    echo ""
    exit 0
}

SCAN_ONLY=0
for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help ;;
        -s|--scan) SCAN_ONLY=1 ;;
    esac
done

while true; do
    echo "=== Full Spectrum Site Survey ==="
    echo "Scanning all radios... please wait (approx 10s)..."
    echo ""

    i=1
    
    device_list=$(uci show wireless | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1)

    for dev in $device_list; do
        raw_band=$(uci -q get wireless."$dev".band)
        
        if [ "$raw_band" = "2g" ]; then
            band="2.4GHz"
        elif [ "$raw_band" = "5g" ]; then
            band="5GHz"
        else
            band="${raw_band}"
        fi
        
        iface_section=$(uci show wireless | grep ".device='$dev'" | head -n 1 | cut -d. -f2)
        
        [ -z "$iface_section" ] && continue

        iface=$(uci -q get wireless."$iface_section".ifname)
        
        [ -z "$iface" ] && continue

        if [ -d "/sys/class/net/$iface" ]; then
            echo -n "  > Scanning $band ($iface)... "
            
            iwpriv "$iface" set SiteSurvey=1
            sleep 4
            
            iwpriv "$iface" get_site_survey > "/tmp/scan_${iface}.raw"
            
            curr_chan=$(uci -q get wireless."$dev".channel)
            curr_mode=$(uci -q get wireless."$dev".htmode)
            
            eval "dev_$i=$dev"
            eval "iface_$i=$iface"
            eval "band_$i=$band"
            eval "curr_$i=$curr_chan"
            eval "mode_$i=$curr_mode"
            
            echo "Done."
            i=$((i + 1))
        else
            echo "[Error] Interface $iface defined for $dev but missing in /sys/class/net"
        fi
    done
    
    total_radios=$((i - 1))

    echo ""
    echo "=== SURVEY RESULTS ==="
    
    idx=1
    while [ $idx -le $total_radios ]; do
        t_iface=$(eval echo \$iface_$idx)
        t_band=$(eval echo \$band_$idx)
        t_curr=$(eval echo \$curr_$idx)
        t_dev=$(eval echo \$dev_$idx)
        
        echo ""
        echo "${C}Radio $idx: $t_band ($t_iface) | Current: Channel $t_curr${N}"
        echo "---------------------------------------------------------"
        printf "%-4s %-12s %-10s %-15s\n" "Rank" "Channel" "Neighbors" "Status"
        echo "---------------------------------------------------------"

        scan_file="/tmp/scan_${t_iface}.raw"
        sort_file="/tmp/sort_${t_iface}.txt"
        > "$sort_file"
        
        valid_channels=$(iwinfo "$t_iface" freqlist | grep "Channel" | sed 's/.*Channel \([0-9]*\).*/\1/')
        
        for ch in $valid_channels; do
            cnt=$(awk -v c="$ch" '$2 == c {count++} END {print count+0}' "$scan_file")
            
            if [ "$cnt" -eq 0 ]; then status="A_EXCELLENT"; 
            elif [ "$cnt" -lt 3 ]; then status="B_GOOD"; 
            elif [ "$cnt" -lt 6 ]; then status="C_FAIR"; 
            else status="D_CROWDED"; fi
            
            echo "$cnt $ch $status" >> "$sort_file"
        done
        
        rank=1
        sort -n "$sort_file" | while read count ch stat; do
            if [ "$stat" = "A_EXCELLENT" ]; then dstat="${G}EXCELLENT${N}"; fi
            if [ "$stat" = "B_GOOD" ]; then      dstat="${G}GOOD     ${N}"; fi
            if [ "$stat" = "C_FAIR" ]; then      dstat="${Y}FAIR     ${N}"; fi
            if [ "$stat" = "D_CROWDED" ]; then   dstat="${R}CROWDED  ${N}"; fi

            note=""
            if [ "$ch" -ge 52 ] && [ "$ch" -le 144 ]; then note="(DFS)"; fi
            
            mark=" "
            if [ "$ch" = "$t_curr" ]; then mark="*"; fi
            
            printf "%s%-3s Channel %-4s %-10s %b %s\n" "$mark" "#$rank" "$ch" "[$count]" "$dstat" "$note"
            rank=$((rank + 1))
        done
        echo "---------------------------------------------------------"
        
        idx=$((idx + 1))
    done

    if [ "$SCAN_ONLY" -eq 1 ]; then
        exit 0
    fi

    echo ""
    echo "Options:"
    echo "  1-$total_radios) Select a Radio to change its Channel"
    echo "  r) Re-scan"
    echo "  q) Quit"
    echo ""
    printf "Your choice: "
    read choice

    case "$choice" in
        q) exit 0 ;;
        r) continue ;;
        [1-9]*)
            if [ "$choice" -gt "$total_radios" ] 2>/dev/null; then continue; fi
            
            target_dev=$(eval echo \$dev_$choice)
            target_iface=$(eval echo \$iface_$choice)
            
            if [ -z "$target_dev" ]; then continue; fi

            echo ""
            printf "Enter new Channel for Radio $choice ($target_iface): "
            read new_chan
            
            if [ -n "$new_chan" ]; then
                echo ""
                echo "Applying Channel $new_chan to $target_dev..."
                uci set wireless.$target_dev.channel="$new_chan"
                uci commit wireless
                wifi reload
                
                echo "Done. Reloading..."
                sleep 2
            fi
            ;;
        *) continue ;;
    esac
done
