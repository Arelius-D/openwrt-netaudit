#!/bin/ash

traffic_wait=45

R=$(printf '\033[0;31m')
G=$(printf '\033[0;32m')
Y=$(printf '\033[1;33m')
N=$(printf '\033[0m')
C=$(printf '\033[0;36m')
W=$(printf '\033[1;37m')

show_help() {
    echo "${W}=== WiFi Network Forensic Audit ===${N}"
    echo "A dynamic OpenWrt utility for auditing WiFi health, client reachability, and RF quality."
    echo ""
    echo "${C}Usage:${N} $0 [OPTIONS]"
    echo ""
    echo "${C}Options:${N}"
    echo "  -h, --help        Show this help message and exit"
    echo "  -t, --time <sec>  Set custom traffic measurement time in seconds (Default: 45)"
    echo ""
    exit 0
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) show_help ;;
        -t|--time) 
            if echo "$2" | grep -qE '^[0-9]+$'; then
                traffic_wait="$2"
                shift
            else
                echo "${R}[Error] -t requires a numeric argument (e.g., -t 15).${N}"
                exit 1
            fi
            ;;
        *) echo "${R}[Error] Unknown option: $1${N}"; echo "Use -h or --help for usage."; exit 1 ;;
    esac
    shift
done

echo "${W}=== WiFi Network Forensic Audit ===${N}"
echo "[Info] Gathering WiFi Context & Health..."
echo ""

wifi_ifaces=""
for dev in $(iwinfo 2>/dev/null | awk '/^[a-z0-9]+[[:space:]]+/ {print $1}' | sort -u); do
  if iwinfo "$dev" info 2>/dev/null | grep -q "Mode:.*Master"; then
    wifi_ifaces="$wifi_ifaces $dev"
  fi
done
wifi_ifaces="${wifi_ifaces# }"

if [ -z "$wifi_ifaces" ]; then
  echo "${R}[Failed] No AP WiFi interfaces detected (iwinfo required)${N}"
  exit 1
fi

echo "${G}[OK]${N} Detected AP interfaces: ${W}$wifi_ifaces${N}"
echo ""

up_count=0
for iface in $wifi_ifaces; do
  if iwinfo "$iface" info 2>/dev/null | grep -q "Access Point:"; then
    channel=$(iwinfo "$iface" info 2>/dev/null | grep "Channel:" | sed 's/.*Channel: //')
    echo "${G}[OK]${N} $iface radio up | Channel: $channel"
    up_count=$((up_count + 1))
  else
    echo "${R}[Failed]${N} $iface radio down or no beacon"
  fi
done
echo ""

if [ $up_count -eq 0 ]; then
  echo "${R}[Failed] No WiFi radios operational${N}"
  exit 1
fi

total_assoc=0
for iface in $wifi_ifaces; do
  assoc=$(iwinfo "$iface" assoclist 2>/dev/null | grep -c "dBm" || echo 0)
  total_assoc=$((total_assoc + assoc))
  if [ $assoc -gt 0 ]; then
    echo "${G}[Success]${N} $iface: $assoc client(s) associated"
  else
    echo "${Y}[Warning]${N} $iface: no clients associated"
  fi
done
echo "  [Info] Total associated clients: ${W}$total_assoc${N}"
echo ""

radio_context_ok=true
for iface in $wifi_ifaces; do
  assoc_out="$(iwinfo "$iface" assoclist 2>/dev/null)"
  if [ -n "$assoc_out" ]; then
    if echo "$assoc_out" | grep -q "RX:" && echo "$assoc_out" | grep -q "TX:"; then
      echo "${G}[OK]${N} $iface association context sane"
    else
      echo "${Y}[Warning]${N} $iface associations lack negotiated rates"
      radio_context_ok=false
    fi
  fi
done
echo ""

if [ $total_assoc -eq 0 ]; then
  echo "  [Info] No clients - skipping client/traffic tests"
  echo "${G}[Success] Radios up and ready${N}"
  exit 0
fi

bridge=""
for iface in $wifi_ifaces; do
  b=$(ip link show "$iface" 2>/dev/null | grep -o "master [a-zA-Z0-9.-]*" | awk '{print $2}')
  [ -n "$b" ] && bridge="$b" && break
done

if [ -n "$bridge" ]; then
  echo "${G}[OK]${N} WiFi bridged to $bridge"
else
  echo "${Y}[Warning]${N} No bridge detected"
fi
echo ""

for iface in $wifi_ifaces; do
  line=$(grep "^[[:space:]]*$iface:" /proc/net/dev 2>/dev/null || echo "")
  if [ -n "$line" ]; then
    rx=$(echo "$line" | awk '{print $2}')
    tx=$(echo "$line" | awk '{print $10}')
    eval init_rx_${iface}="$rx"
    eval init_tx_${iface}="$tx"
  fi
done

echo "  [Info] Initial counters recorded - waiting ${traffic_wait}s for traffic"
sleep $traffic_wait
echo ""

traffic_seen=false
for iface in $wifi_ifaces; do
  line=$(grep "^[[:space:]]*$iface:" /proc/net/dev 2>/dev/null || echo "")
  if [ -n "$line" ]; then
    rx=$(echo "$line" | awk '{print $2}')
    tx=$(echo "$line" | awk '{print $10}')
    init_rx=$(eval echo \$init_rx_${iface} || echo 0)
    init_tx=$(eval echo \$init_tx_${iface} || echo 0)
    delta_rx=$((rx - init_rx))
    delta_tx=$((tx - init_tx))
    if [ $delta_rx -gt 5000 ] || [ $delta_tx -gt 5000 ]; then
      echo "${G}[Success]${N} $iface traffic flow: +$delta_rx RX / +$delta_tx TX bytes"
      traffic_seen=true
    else
      echo "${Y}[Warning]${N} $iface low/idle traffic: +$delta_rx RX / +$delta_tx TX bytes"
    fi
  else
    echo "${R}[Failed]${N} $iface no counters"
  fi
done
echo ""

if $traffic_seen; then
  echo "${G}[Success] Outbound/inbound traffic confirmed over WiFi${N}"
else
  if $radio_context_ok; then
    echo "  [Info] No significant traffic observed (clients likely idle)"
  else
    echo "${Y}[Warning] No traffic and degraded association context${N}"
  fi
fi
echo ""

echo "${C}--- Hardware Transmission Health (TX Errors) ---${N}"
for iface in $wifi_ifaces; do
  tx_fail=$(iwinfo "$iface" info 2>/dev/null | grep "TX failed:" | awk '{print $3}')
  [ -z "$tx_fail" ] && tx_fail=$(cat /sys/class/net/"$iface"/statistics/tx_errors 2>/dev/null)
  [ -z "$tx_fail" ] && tx_fail=0

  if [ "$tx_fail" -gt 0 ]; then
    echo "${Y}[Warning]${N} $iface: $tx_fail packet transmission failures detected (Interference/HW issue)"
  else
    echo "${G}[OK]${N} $iface: Clean transmission (0 hardware errors)"
  fi
done
echo ""

if [ -n "$bridge" ]; then
  arp_table=$(ip -4 neigh show)
  
  for iface in $wifi_ifaces; do
    echo "${C}--- [$iface] Local Client Reachability ---${N}"
    
    mac_list=$(iwinfo "$iface" assoclist 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')

    client_ips=""
    for mac in $mac_list; do
      ip=$(echo "$arp_table" | grep -i "$mac" | awk '{print $1}' | head -n 1)
      if [ -n "$ip" ]; then
        client_ips="$client_ips $ip"
      fi
    done

    client_ips=$(echo "$client_ips" | tr ' ' '\n' | grep -v '^$')
    
    total_found=$(echo "$client_ips" | grep -c .)
    
    if [ "$total_found" -gt 0 ]; then
      target_count=$(( (total_found + 1) / 2 ))
      target_ips=$(echo "$client_ips" | awk 'BEGIN{srand()} {print rand()"\t"$0}' | sort -n | cut -f2 | head -n "$target_count")
      
      ping_ok=0
      ping_tried=0
      
      for ip in $target_ips; do
        hostname="Unknown"
        if [ -f "/tmp/dhcp.leases" ]; then
            name=$(grep -w "$ip" /tmp/dhcp.leases | awk '{print $4}' | head -n 1)
            [ -n "$name" ] && [ "$name" != "*" ] && hostname="$name"
        fi

        if ping -c 2 -W 2 "$ip" >/dev/null 2>&1; then
          echo "  > Client: $ip [${W}$hostname${N}] ... ${G}[OK]${N} ($iface)"
          ping_ok=$((ping_ok + 1))
        else
          echo "  > Client: $ip [${W}$hostname${N}] ... ${Y}[Failed/No Reply]${N} ($iface)"
        fi
        ping_tried=$((ping_tried + 1))
      done
      
      if [ $ping_ok -gt 0 ]; then
        echo "${G}[Success]${N} $iface: $ping_ok/$ping_tried random clients responded"
      else
        echo "${R}[Failed]${N} $iface: No clients responded to ping"
      fi
    else
      echo "  [Info] $iface: No associated clients have known IPs in ARP table"
    fi
    echo ""
  done
fi

echo "${C}--- Physical Link Quality (RSSI) ---${N}"
for iface in $wifi_ifaces; do
  signals=$(iwinfo "$iface" assoclist 2>/dev/null | awk '/dBm/ { for(i=1; i<=NF; i++) if($i ~ /^-[0-9]+$/) { print $i; break } }')
  
  if [ -n "$signals" ]; then
    strong_count=0
    weak_count=0
    total_count=0
    
    for rssi in $signals; do
      if [ "$rssi" -ge -75 ]; then
        strong_count=$((strong_count + 1))
      else
        weak_count=$((weak_count + 1))
      fi
      total_count=$((total_count + 1))
    done
    
    if [ $strong_count -gt 0 ]; then
      echo "${G}[Success]${N} $iface: $strong_count/$total_count clients have strong signal (>-75dBm)"
    else
      echo "${Y}[Warning]${N} $iface: All clients have weak signal (Possible antenna/power issue)"
    fi
  else
    echo "  [Info] $iface: Could not parse signal strength from driver"
  fi
done
echo ""

echo "${C}--- Signal-to-Noise Ratio (SNR) ---${N}"
for iface in $wifi_ifaces; do
  noise=$(iwinfo "$iface" info 2>/dev/null | sed -n 's/.*Noise: \?\(\-[0-9]\+\).*/\1/p')
  
  if [ -z "$noise" ]; then
      echo "  [Info] $iface: Driver does not report Noise Floor (cannot calc SNR)"
      continue
  fi

  signals=$(iwinfo "$iface" assoclist 2>/dev/null | awk '/dBm/ { for(i=1; i<=NF; i++) if($i ~ /^-[0-9]+$/) { print $i; break } }')
  
  if [ -n "$signals" ]; then
      low_snr_count=0
      total_count=0
      for rssi in $signals; do
          snr=$((rssi - noise))
          if [ "$snr" -lt 20 ]; then
              low_snr_count=$((low_snr_count + 1))
          fi
          total_count=$((total_count + 1))
      done

      if [ $low_snr_count -gt 0 ]; then
          echo "${Y}[Warning]${N} $iface: $low_snr_count/$total_count clients have low SNR (<20dB) | Floor: ${noise}dBm"
      else
          echo "${G}[Success]${N} $iface: All clients have healthy SNR (>20dB) | Floor: ${noise}dBm"
      fi
  else
      echo "  [Info] $iface: No clients associated"
  fi
done
echo ""

echo "${C}--- PHY Rate Quality (Negotiated Speed) ---${N}"
for iface in $wifi_ifaces; do
  rates=$(iwinfo "$iface" assoclist 2>/dev/null | grep -oE '[0-9.]+[[:space:]]*MBit/s' | awk '{print $1}')
  
  if [ -n "$rates" ]; then
      slow_count=0
      total_count=0
      for rate in $rates; do
          is_slow=$(echo "$rate" | awk '{if ($1 < 50) print 1; else print 0}')
          if [ "$is_slow" -eq 1 ]; then
              slow_count=$((slow_count + 1))
          fi
          total_count=$((total_count + 1))
      done

      if [ $slow_count -gt 0 ]; then
          echo "${Y}[Warning]${N} $iface: $slow_count/$total_count clients negotiating < 50Mbps"
      else
          echo "${G}[Success]${N} $iface: All clients negotiating high speed (>50Mbps)"
      fi
  else
      echo "  [Info] $iface: No rate information available"
  fi
done
echo ""

if [ -n "$bridge" ]; then
  bridge_ip=$(ip -4 addr show dev "$bridge" scope global 2>/dev/null | grep -o 'inet [0-9.]\+' | awk '{print $2}' | head -n1)
  if [ -n "$bridge_ip" ]; then
    echo "  [Info] Testing forced WAN egress from bridge IP $bridge_ip..."
    if ping -I "$bridge_ip" -c 3 -W 5 8.8.8.8 >/dev/null 2>&1; then
      echo "${G}[Success]${N} WAN egress OK: bridge-sourced traffic reaches internet"
    else
      echo "${R}[Critical]${N} WAN egress FAILED: local OK but no outbound (check PBR/VPN/firewall)"
    fi
  else
    echo "${Y}[Warning]${N} No bridge IP found - skipping forced egress test"
  fi
fi
echo ""

echo "=== Audit Complete ==="
