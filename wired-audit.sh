#!/bin/ash

traffic_wait=30
run_extended=0

R=$(printf '\033[0;31m')
G=$(printf '\033[0;32m')
Y=$(printf '\033[1;33m')
N=$(printf '\033[0m')
C=$(printf '\033[0;36m')
W=$(printf '\033[1;37m')

show_help() {
    echo "${W}=== Wired Network Forensic Audit ===${N}"
    echo "A dynamic OpenWrt utility for auditing wired topology, hardware health, and firewall exposure."
    echo ""
    echo "${C}Usage:${N} $0 [OPTIONS]"
    echo ""
    echo "${C}Options:${N}"
    echo "  -h, --help        Show this help message and exit"
    echo "  -v, --verbose     Run extended checks (Speedtest & Raw Kernel Firewall Dump)"
    echo "  -t, --time <sec>  Set custom traffic measurement time in seconds (Default: 30)"
    echo ""
    exit 0
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) show_help ;;
        -v|--verbose) run_extended=1 ;;
        -t|--time) 
            if echo "$2" | grep -qE '^[0-9]+$'; then
                traffic_wait="$2"
                shift
            else
                echo "${R}[Error] -t requires a numeric argument (e.g., -t 10).${N}"
                exit 1
            fi
            ;;
        *) echo "${R}[Error] Unknown option: $1${N}"; echo "Use -h or --help for usage."; exit 1 ;;
    esac
    shift
done

echo "=== Wired Network Forensic Audit ==="
echo "[Info] Gathering System Context & Topology..."
echo ""
echo "${C}--- System Configuration & Policy Context ---${N}"
echo "${W}[Routing & Policies]${N}"

policy_rules=$(ip rule show | grep -vE "lookup (local|main|default)" | grep -v "suppress_prefixlength 0")
if [ -n "$policy_rules" ]; then
    echo "${Y}  [!] Policy Routing / VPN Logic Detected:${N}"
    echo "$policy_rules" | awk '{printf "      %s\n", $0}'
fi

ip route show table main | awk '{printf "  %s\n", $0}'
echo ""

echo "${W}[Firewall Zones]${N}"
zones=$(uci show firewall | grep "=zone" | cut -d. -f2 | cut -d= -f1 | sort -u)
for zone in $zones; do
    zname=$(uci -q get firewall."$zone".name)
    znet=$(uci -q get firewall."$zone".network)
    zinput=$(uci -q get firewall."$zone".input)
    zforward=$(uci -q get firewall."$zone".forward)
    zmasq=$(uci -q get firewall."$zone".masq)
    [ "$zmasq" = "1" ] && nat_status="(NAT)" || nat_status=""
    echo "  Zone '${zname}': Networks=[$znet] | Input=$zinput / Forward=$zforward ${nat_status}"
done
echo ""

echo "${W}[Firewall Audit: All Explicit Rules & Port Forwards]${N}"

found_exposure=0

rules=$(uci show firewall | grep "=rule" | cut -d. -f2 | cut -d= -f1 | sort -u)
for rule in $rules; do
    name=$(uci -q get firewall."$rule".name)
    src=$(uci -q get firewall."$rule".src)
    dest_port=$(uci -q get firewall."$rule".dest_port)
    proto=$(uci -q get firewall."$rule".proto)
    target=$(uci -q get firewall."$rule".target)
    enabled=$(uci -q get firewall."$rule".enabled)
    
    [ -z "$name" ] && name="(Unnamed)"
    [ -z "$enabled" ] && enabled="1"
    [ -z "$src" ] && src="*"
    [ -z "$target" ] && target="ACCEPT"
    
    if [ "$enabled" = "1" ]; then
        if [ -n "$dest_port" ]; then
             echo "  [RULE]  $name: Allow $src -> Port $dest_port ($proto) -> $target"
        else
             echo "  [RULE]  $name: Allow $src -> All Ports -> $target"
        fi
        found_exposure=1
    fi
done

redirects=$(uci show firewall | grep "=redirect" | cut -d. -f2 | cut -d= -f1 | sort -u)
for red in $redirects; do
    name=$(uci -q get firewall."$red".name)
    src=$(uci -q get firewall."$red".src)
    src_dport=$(uci -q get firewall."$red".src_dport)
    dest_ip=$(uci -q get firewall."$red".dest_ip)
    dest_port=$(uci -q get firewall."$red".dest_port)
    enabled=$(uci -q get firewall."$red".enabled)
    
    [ -z "$name" ] && name="(Unnamed)"
    [ -z "$enabled" ] && enabled="1"
    [ -z "$src" ] && src="*"

    if [ "$enabled" = "1" ] && [ -n "$src_dport" ]; then
        echo "  [NAT]   $name: $src:$src_dport -> LAN $dest_ip:$dest_port"
        found_exposure=1
    fi
done

[ "$found_exposure" -eq 0 ] && echo "  (No explicit rules or port forwards found.)"
echo ""
echo "${C}--- Physical & Logical Interface Audit ---${N}"

networks=$(uci show network | grep "=interface" | cut -d. -f2 | cut -d= -f1 | grep -v "loopback" | sort -u)

audit_phy_port() {
    local port=$1
    if [ ! -d "/sys/class/net/$port" ]; then return; fi

    operstate=$(cat /sys/class/net/"$port"/operstate 2>/dev/null)
    if [ "$operstate" != "up" ]; then
        echo "    [${Y}DOWN${N}] Physical Port: $port (Link Down)"
        return
    fi

    speed=$(cat /sys/class/net/"$port"/speed 2>/dev/null)
    duplex=$(cat /sys/class/net/"$port"/duplex 2>/dev/null)
    
    rx_err=$(cat /sys/class/net/"$port"/statistics/rx_errors 2>/dev/null)
    
    speed_status="${G}OK${N}"
    if echo "$speed" | grep -qE '^[0-9]+$'; then
        [ "$speed" -lt 1000 ] && speed_status="${Y}SLOW (<1Gbps)${N}"
    else
        speed="Unknown"
    fi
    
    if [ "$rx_err" -gt 0 ]; then
        err_msg="${Y}History: ${rx_err} PhyErrors (Monitor if increasing)${N}"
    else
        err_msg="${G}Clean${N}"
    fi

    echo "    [${G}UP${N}]    Physical Port: $port | Speed: ${speed}Mbps ($duplex) | $err_msg"
    
    safe_port=$(echo "$port" | tr '-' '_')
    eval start_err_${safe_port}=$rx_err
}

for net in $networks; do
    dev=$(uci -q get network."$net".device)
    [ -z "$dev" ] && dev=$(uci -q get network."$net".ifname)

    if [ -z "$dev" ] || [ ! -d "/sys/class/net/$dev" ]; then continue; fi

    ip_addr=$(ip -4 addr show "$dev" | grep -o 'inet [0-9.]\+' | awk '{print $2}')
    mac_addr=$(cat /sys/class/net/"$dev"/address 2>/dev/null)
    
    echo "Logical: ${W}$net${N} -> Device: $dev"
    echo "    [Info] IP: ${ip_addr:-None} | MAC: $mac_addr"

    dhcp_sec=$(uci show dhcp | grep ".interface='$net'" | cut -d. -f2)
    if [ -n "$dhcp_sec" ]; then
        ignore=$(uci -q get dhcp."$dhcp_sec".ignore)
        if [ "$ignore" = "1" ]; then
             echo "    [Info] DHCP: Disabled"
        else
             limit=$(uci -q get dhcp."$dhcp_sec".limit)
             echo "    [${G}ON${N}]    DHCP Server Active (Limit: $limit hosts)"
        fi
    else
        echo "    [Info] DHCP: No Server Configured"
    fi

    if [ -d "/sys/class/net/$dev/bridge" ]; then
        if [ -d "/sys/class/net/$dev/brif" ]; then
            for member in $(ls "/sys/class/net/$dev/brif"); do
                if iwinfo "$member" info >/dev/null 2>&1; then continue; fi
                audit_phy_port "$member"
            done
        fi
    elif [ -f "/sys/class/net/$dev/speed" ]; then
        audit_phy_port "$dev"
    fi
    echo ""
done

if command -v bridge >/dev/null 2>&1; then
    vlan_out=$(bridge vlan show 2>/dev/null | grep -v "vlan ids")
    if [ -n "$vlan_out" ]; then
        echo "${W}[Hardware Switch VLAN Mapping]${N}"
        echo "$vlan_out" | awk '{print "  " $0}'
        echo ""
    fi
fi

echo "${C}--- Wired Client Reachability ---${N}"

default_gw=$(ip route show default | awk '/default/ {print $3}' | head -n 1)

wifi_macs=$(iwinfo 2>/dev/null | awk '/Access Point:/ {print tolower($3)}')
assoc_macs=$(for iface in $(iwinfo | awk '/^[a-z0-9]+/ {print $1}'); do iwinfo "$iface" assoclist 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'; done | tr 'A-F' 'a-f')

for net in $networks; do
    dev=$(uci -q get network."$net".device)
    [ -z "$dev" ] && dev=$(uci -q get network."$net".ifname)
    if [ -z "$dev" ] || [ ! -d "/sys/class/net/$dev" ]; then continue; fi
    
    arp_entries=$(ip -4 neigh show dev "$dev" | grep "lladdr")
    
    if [ -n "$arp_entries" ]; then
        echo "Scanning $net ($dev)..."
        
        wired_list="/tmp/wired_${net}.tmp"
        > "$wired_list"
        
        echo "$arp_entries" | while read line; do
            mac=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}')
            mac_lower=$(echo "$mac" | tr 'A-F' 'a-f')
            
            is_wifi=0
            for wmac in $assoc_macs; do
                if [ "$mac_lower" = "$wmac" ]; then is_wifi=1; break; fi
            done
            
            if [ "$is_wifi" -eq 0 ]; then
                echo "$line" >> "$wired_list"
            fi
        done
        
        if [ -s "$wired_list" ]; then
            count=$(wc -l < "$wired_list")
            echo "  [Info] Detected ${W}$count${N} wired client(s). Testing reachability..."
            
            while read line; do
                ip=$(echo "$line" | awk '{print $1}')
                mac=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}')
                state=$(echo "$line" | awk '{print $NF}')
                
                hostname="Unknown"
                if [ -f "/tmp/dhcp.leases" ]; then
                    name=$(grep -i "$mac" /tmp/dhcp.leases | awk '{print $4}' | head -n 1)
                    [ -n "$name" ] && [ "$name" != "*" ] && hostname="$name"
                fi
                
                if [ "$ip" = "$default_gw" ]; then
                    echo -n "  > ${W}[WAN Gateway]${N} $ip ($mac) ... "
                    
                    gw_ping="${R}Blocked${N}"
                    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then gw_ping="${G}OK${N}"; fi
                    
                    inet_ping="${R}Fail${N}"
                    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then inet_ping="${G}OK${N}"; fi
                    
                    dns_check="${R}Fail${N}"
                    if nslookup google.com >/dev/null 2>&1; then dns_check="${G}OK${N}"; fi
                    
                    echo "[Ping: $gw_ping] [Internet: $inet_ping] [DNS: $dns_check]"
                else
                    echo -n "  > Client: $ip ($mac) [${W}$hostname${N}] [$state] ... "
                    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
                        echo "${G}[OK]${N}"
                    else
                        echo "${Y}[Unreachable]${N}"
                    fi
                fi
            done < "$wired_list"
        else
            echo "  [Info] 0 wired clients detected (all neighbors are WiFi)."
        fi
        
        rm -f "$wired_list"
        echo ""
    fi
done

echo "${C}--- Active Traffic & Hardware Health (${traffic_wait}s Sample) ---${N}"

for net in $networks; do
    dev=$(uci -q get network."$net".device)
    [ -z "$dev" ] && dev=$(uci -q get network."$net".ifname)
    if [ -n "$dev" ] && [ -d "/sys/class/net/$dev" ]; then
          safe_dev=$(echo "$dev" | tr '-' '_')
          rx=$(cat /sys/class/net/"$dev"/statistics/rx_bytes 2>/dev/null)
          tx=$(cat /sys/class/net/"$dev"/statistics/tx_bytes 2>/dev/null)
          eval start_rx_${safe_dev}=$rx
          eval start_tx_${safe_dev}=$tx
    fi
done

sleep $traffic_wait

for net in $networks; do
    dev=$(uci -q get network."$net".device)
    [ -z "$dev" ] && dev=$(uci -q get network."$net".ifname)
    
    if [ -n "$dev" ] && [ -d "/sys/class/net/$dev" ]; then
          safe_dev=$(echo "$dev" | tr '-' '_')
          
          rx_now=$(cat /sys/class/net/"$dev"/statistics/rx_bytes 2>/dev/null)
          tx_now=$(cat /sys/class/net/"$dev"/statistics/tx_bytes 2>/dev/null)
          rx_start=$(eval echo \$start_rx_${safe_dev})
          tx_start=$(eval echo \$start_tx_${safe_dev})
          
          delta_rx=$((rx_now - rx_start))
          delta_tx=$((tx_now - tx_start))
          speed_rx=$(( (delta_rx / traffic_wait) / 1024 ))
          speed_tx=$(( (delta_tx / traffic_wait) / 1024 ))
          
          err_check_list=""
          if [ -d "/sys/class/net/$dev/bridge" ] && [ -d "/sys/class/net/$dev/brif" ]; then
              for member in $(ls "/sys/class/net/$dev/brif"); do
                  if ! iwinfo "$member" info >/dev/null 2>&1; then err_check_list="$err_check_list $member"; fi
              done
          elif [ -f "/sys/class/net/$dev/speed" ]; then
              err_check_list="$dev"
          fi
          
          hw_issue=""
          for port in $err_check_list; do
              safe_port=$(echo "$port" | tr '-' '_')
              start_err=$(eval echo \$start_err_${safe_port})
              curr_err=$(cat /sys/class/net/"$port"/statistics/rx_errors 2>/dev/null)
              [ -z "$start_err" ] && start_err=0
              [ -z "$curr_err" ] && curr_err=0
              
              if [ "$curr_err" -gt "$start_err" ]; then
                  diff=$((curr_err - start_err))
                  hw_issue="${R}CRITICAL: $port gained +$diff Errors! (CABLE FAILING)${N}"
              fi
          done

          if [ "$delta_rx" -gt 1024 ] || [ "$delta_tx" -gt 1024 ]; then
              echo "  ${G}[ACTIVE]${N} $net ($dev): RX: ${speed_rx} KB/s | TX: ${speed_tx} KB/s"
          else
              echo "  [IDLE]    $net ($dev): No significant traffic"
          fi
          
          if [ -n "$hw_issue" ]; then
              echo "            $hw_issue"
          fi
    fi
done
echo ""

if [ "$run_extended" -eq 1 ]; then
    echo "${C}--- Internet Performance ---${N}"

    if command -v speedtest-cli >/dev/null 2>&1; then
        echo "  [Info] Running speedtest-cli... please wait..."
        
        st_out=$(speedtest-cli --simple 2>&1)
        
        if echo "$st_out" | grep -qi "403: Forbidden"; then
            echo "    ${Y}[Warning] Speedtest connection blocked by Ookla (HTTP 403).${N}"
        else
            echo "$st_out" | sed 's/^/    /'
        fi
        
    elif command -v speedtest >/dev/null 2>&1; then
        echo "  [Info] Running speedtest... please wait..."
        speedtest --simple | sed 's/^/    /'
    else
        echo "  [Info] Speedtest tool not found."
        echo "          To install: opkg install python3-speedtest-cli"
    fi
    echo ""

    dump_file="/tmp/raw_firewall_dump.txt"
    echo "${C}--- Generating Raw Kernel Dump ---${N}"

    if command -v fw4 >/dev/null 2>&1 && command -v nft >/dev/null 2>&1; then
        nft list ruleset > "$dump_file" 2>/dev/null
        echo "  [Info] Modern fw4/nftables detected. Raw rules saved to $dump_file"
    elif command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$dump_file" 2>/dev/null
        echo "  [Info] Legacy fw3/iptables detected. Raw rules saved to $dump_file"
    else
        echo "  [Warning] Could not generate raw kernel dump."
    fi
    echo ""
fi

echo "=== Audit Complete ==="
