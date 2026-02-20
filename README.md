# OpenWrt Net Audit

A suite of forensic network audit and RF management tools for OpenWrt routers running on **MediaTek hardware** (GL.iNet GL-MT6000 and compatible). Built for operators who want real diagnostic depth from the shell — no GUI, no guesswork.

---

## Tools

| Script | Purpose |
|---|---|
| `rf-survey.sh` | Full-spectrum WiFi site survey with channel ranking and interactive channel switching |
| `wifi-audit.sh` | Forensic WiFi health audit — clients, signal, SNR, PHY rates, traffic, WAN egress |
| `wired-audit.sh` | Forensic wired network audit — topology, firewall exposure, client reachability, hardware health |

---

## Hardware & Software Requirements

| Requirement | Detail |
|---|---|
| **Router SoC** | MediaTek MT7986 (Filogic 830) or similar MediaTek platform |
| **Firmware** | OpenWrt 21.02-SNAPSHOT or later |
| **Config System** | UCI (Unified Configuration Interface) |
| **Shell** | `/bin/ash` (BusyBox) |
| **WiFi Tools** | `iwinfo`, `iwpriv` (MediaTek-specific — required for site survey) |
| **Network Tools** | `ip`, `ping`, `nslookup`, `awk`, `grep`, `bridge` (standard OpenWrt) |

> **Important:** `rf-survey.sh` uses `iwpriv SiteSurvey` which is a **MediaTek driver-specific command**. It will not function on Qualcomm Atheros (ath9k/ath10k/ath11k) or Broadcom hardware. `wifi-audit.sh` and `wired-audit.sh` use standard `iwinfo` and sysfs and are more broadly portable, but have been tested primarily on MediaTek platforms.

---

## Installation

```sh
# SSH into your router
ssh root@192.168.8.1

# Download scripts (adjust filenames/paths as needed)
wget -O /root/rf-survey.sh https://raw.githubusercontent.com/Arelius-D/openwrt-netaudit/main/rf-survey.sh
wget -O /root/wifi-audit.sh https://raw.githubusercontent.com/Arelius-D/openwrt-netaudit/main/wifi-audit.sh
wget -O /root/wired-audit.sh https://raw.githubusercontent.com/Arelius-D/openwrt-netaudit/main/wired-audit.sh

# Make executable
chmod +x /root/rf-survey.sh /root/wifi-audit.sh /root/wired-audit.sh
```

No package dependencies beyond what ships with a standard OpenWrt image.

---

## rf-survey.sh — Full Spectrum Site Survey

Scans all detected WiFi radios simultaneously using MediaTek's `SiteSurvey` engine, ranks every valid channel by neighbor density, and lets you apply a new channel immediately from the same session.

### Usage

```sh
./rf-survey.sh            # Interactive: survey + channel switcher
./rf-survey.sh -s|--scan  # Scan-only: print results and exit (no interaction)
./rf-survey.sh -h|--help  # Show help
```

### What It Does

1. **Auto-discovers all radios** dynamically from UCI — no hardcoded interface names
2. **Triggers a hardware-level scan** on each radio via `iwpriv SiteSurvey=1`
3. **Ranks every valid channel** on each band by number of neighbouring networks:

| Rating | Neighbours |
|---|---|
| `EXCELLENT` | 0 |
| `GOOD` | 1–2 |
| `FAIR` | 3–5 |
| `CROWDED` | 6+ |

4. **Marks DFS channels** (52–144) so you know what you're selecting
5. **Marks your current channel** with `*` in the results table
6. **Applies the change live** via `uci set` + `wifi reload` if you select a new channel

### Example Output

```
=== Full Spectrum Site Survey ===
Scanning all radios... please wait (approx 10s)...

  > Scanning 2.4GHz (ra0)... Done.
  > Scanning 5GHz (rax0)... Done.

=== SURVEY RESULTS ===

Radio 1: 2.4GHz (ra0) | Current: Channel 6
---------------------------------------------------------
Rank  Channel    Neighbors  Status
---------------------------------------------------------
 #1   Channel 1    [0]      EXCELLENT
 #2   Channel 11   [1]      GOOD
*#3   Channel 6    [4]      FAIR
...

Radio 2: 5GHz (rax0) | Current: Channel 36
---------------------------------------------------------
 #1   Channel 149  [0]      EXCELLENT
 #2   Channel 36   [1]      GOOD     (DFS)
...
```

---

## wifi-audit.sh — WiFi Forensic Audit

A structured health check for your WiFi stack. Runs through radio state, client associations, signal quality, traffic flow, and WAN reachability in a single pass.

### Usage

```sh
./wifi-audit.sh                   # Default: 45s traffic measurement window
./wifi-audit.sh -t 15             # Custom traffic window (15 seconds)
./wifi-audit.sh -h                # Help
```

### Audit Stages

**1. Radio Detection & State**
Detects all AP-mode interfaces via `iwinfo`. Confirms each radio is up and beaconing. Reports the current channel.

**2. Client Association**
Counts associated clients per radio. Validates that association entries include negotiated RX/TX rates — missing rates can indicate driver issues.

**3. Traffic Flow**
Records per-interface byte counters, waits for the configured window, then calculates delta. Flags interfaces with less than 5KB of movement as idle — useful for catching silent failures where clients are associated but not passing traffic.

**4. Hardware TX Health**
Checks `TX failed` counters via `iwinfo` (with sysfs fallback). Any non-zero value is flagged as a potential interference or hardware issue.

**5. Client Reachability (50% Random Sample)**
Builds a MAC→IP map from the ARP table, then pings a random 50% sample of associated clients. Reports hostname from DHCP leases where available. This catches the common failure mode where clients are associated at L2 but broken at L3.

**6. RSSI Audit**
Checks signal strength for all associated clients. Flags any client below −75 dBm as weak. Useful for catching clients that are technically connected but too far away for reliable performance.

**7. SNR Audit**
Reads the noise floor from the driver and calculates SNR per client. Clients below 20 dB SNR are flagged. Low SNR often explains poor throughput even when RSSI looks acceptable.

**8. PHY Rate Audit**
Checks negotiated link speeds. Clients negotiating below 50 Mbps are flagged — this surfaces issues like a 5GHz client falling back to legacy rates due to driver negotiation problems or physical distance.

**9. WAN Egress Test**
Pings 8.8.8.8 sourced from the bridge IP. This specifically tests that bridge-sourced traffic is routing correctly to WAN — catches misconfigured PBR/VPN policy that would let router-sourced traffic through but silently break client traffic.

### Example Output

```
=== WiFi Network Forensic Audit ===
[OK] Detected AP interfaces: ra0 rax0

[OK] ra0 radio up | Channel: 6 (2.437 GHz) HT Mode: HE20
[OK] rax0 radio up | Channel: 44 (5.220 GHz) HT Mode: HE80

[Success] ra0: 7 client(s) associated
[Success] rax0: 8 client(s) associated
  [Info] Total associated clients: 15

[OK] WiFi bridged to br-lan1
  [Info] Initial counters recorded - waiting 45s for traffic

[Success] ra0 traffic flow: +68395 RX / +21009 TX bytes
[Success] rax0 traffic flow: +350072 RX / +243445 TX bytes

--- Hardware Transmission Health (TX Errors) ---
[OK] ra0: Clean transmission (0 hardware errors)
[OK] rax0: Clean transmission (0 hardware errors)

--- [ra0] Local Client Reachability ---
  > Client: 10.10.0.192 [KP105] ... [OK] (ra0)
  > Client: 10.10.0.155 [LGwebOSTV] ... [OK] (ra0)
[Success] ra0: 4/4 random clients responded

--- Physical Link Quality (RSSI) ---
[Success] ra0: 7/7 clients have strong signal (>-75dBm)
[Success] rax0: 8/8 clients have strong signal (>-75dBm)

--- Signal-to-Noise Ratio (SNR) ---
[Success] ra0: All clients have healthy SNR (>20dB) | Floor: -63dBm
[Success] rax0: All clients have healthy SNR (>20dB) | Floor: -63dBm

--- PHY Rate Quality (Negotiated Speed) ---
[Warning] ra0: 7/14 clients negotiating < 50Mbps
[Warning] rax0: 1/16 clients negotiating < 50Mbps

[Success] WAN egress OK: bridge-sourced traffic reaches internet
=== Audit Complete ===
```

### Signal Thresholds Reference

| Metric | Threshold | Flag |
|---|---|---|
| RSSI | < −75 dBm | Weak signal |
| SNR | < 20 dB | Poor noise environment |
| PHY Rate | < 50 Mbps | Legacy/degraded negotiation |
| Traffic Delta | < 5 KB | Idle / possible failure |

---

## wired-audit.sh — Wired Forensic Audit

A deep inspection of your wired topology, firewall posture, client connectivity, and physical port health.

### Usage

```sh
./wired-audit.sh                  # Standard run (30s traffic window)
./wired-audit.sh -t 60            # Custom traffic window
./wired-audit.sh -v               # Verbose: adds speedtest + raw kernel firewall dump
./wired-audit.sh -h               # Help
```

### Example Output

```
=== Wired Network Forensic Audit ===

--- System Configuration & Policy Context ---
[!] Policy Routing / VPN Logic Detected:
    1:    from all iif lo lookup 16800
    1101: not from all fwmark 0x8000/0xc000 lookup 8000

[Firewall Zones]
  Zone 'wan': Networks=[wan wan6] | Input=DROP / Forward=REJECT (NAT)
  Zone 'lan1': Networks=[lan1] | Input=ACCEPT / Forward=ACCEPT

[Firewall Audit: All Explicit Rules & Port Forwards]
  [RULE]  Block-WAN-SSH: Allow wan -> Port 22 (tcp) -> DROP
  [RULE]  lan1_to_ui: Allow lan1 -> Port 80 443 (tcp) -> ACCEPT
  [NAT]   Forward-SSH-to-Device: wan:1010 -> LAN 10.10.0.100:22

--- Physical & Logical Interface Audit ---
Logical: lan1 -> Device: br-lan1
    [Info] IP: 10.10.0.1 | MAC: 1e:ac:25:94:2e:9e
    [ON]    DHCP Server Active (Limit: 100 hosts)
    [UP]    Physical Port: lan2 | Speed: 1000Mbps (full) | Clean

Logical: wan -> Device: eth1
    [Info] IP: 83.252.60.209 | MAC: 94:83:c4:a9:31:7f
    [Info] DHCP: Disabled
    [UP]    Physical Port: eth1 | Speed: 1000Mbps (full) | History: 74 PhyErrors (Monitor if increasing)

--- Wired Client Reachability ---
Scanning lan1 (br-lan1)...
  [Info] Detected 5 wired client(s). Testing reachability...
  > Client: 10.10.0.177 (c8:d0:83:b1:a2:27) [Vardagsrum] [REACHABLE] ... [OK]
  > Client: 10.10.0.100 (2c:cf:67:bf:9e:6d) [pi5] [REACHABLE] ... [OK]
  > Client: 10.10.0.158 (00:05:cd:fd:4b:48) [Marantz-SR6013] [REACHABLE] ... [OK]
  > [WAN Gateway] 83.252.60.1 (00:00:5e:00:01:1e) ... [Ping: Blocked] [Internet: OK] [DNS: OK]

--- Active Traffic & Hardware Health (30s Sample) ---
  [ACTIVE] lan1 (br-lan1): RX: 10 KB/s | TX: 37 KB/s
  [ACTIVE] wan (eth1): RX: 87 KB/s | TX: 11 KB/s

=== Audit Complete ===
```

### Audit Stages

**Stage 0 — System Configuration & Policy Context**

*Routing & Policies:* Dumps the main routing table. Detects any policy routing rules (VPN kill-switches, guest network isolation, multi-WAN) and surfaces them explicitly — these are invisible in the GL.iNet UI but directly affect traffic behaviour.

*Firewall Zones:* Lists all UCI firewall zones with their bound networks, input/forward policies, and NAT status.

*Firewall Rules & Port Forwards:* Iterates every explicit `firewall.rule` and `firewall.redirect` in UCI. All active rules and DNAT port forwards are printed. This gives you a complete picture of what is actually exposed, independent of the GUI representation.

**Stage 1 — Physical & Logical Interface Audit**

For every configured network interface, reports: IP address, MAC address, DHCP server status and pool size, physical port link state, negotiated speed/duplex, and historical RX error count. Bridge members are walked individually so each physical port gets its own line.

Also runs `bridge vlan show` for DSA-capable hardware to display the hardware switch VLAN map.

**Stage 2 — Wired Client Reachability**

Reads the ARP table for each network. Filters out WiFi clients (cross-references against `iwinfo assoclist`) to report only genuinely wired neighbours. For each wired client: resolves hostname from DHCP leases, pings for reachability, reports ARP neighbour state.

The WAN gateway gets special treatment: its entry triggers a three-part check — gateway ping, internet ping (8.8.8.8), and DNS resolution — giving you a layered connectivity diagnosis in one line.

**Stage 3 — Active Traffic & Hardware Health**

Records byte counters at start, sleeps for the measurement window, then calculates throughput per interface in KB/s. Simultaneously monitors physical port RX error counters — if errors *increase* during the window, it's flagged as a critical cable or hardware failure, not just historical noise.

**Stage 4 (Verbose) — Internet Speed Test**

Runs `speedtest-cli` or `speedtest` if available. Handles the common Ookla 403 block gracefully rather than dumping a confusing error.

**Stage 5 (Verbose) — Raw Kernel Firewall Dump**

Detects whether the router is running `fw4`/`nftables` (OpenWrt 22.03+) or legacy `fw3`/`iptables` and dumps the full kernel ruleset to `/tmp/raw_firewall_dump.txt`. Useful when you need to verify that UCI configuration has actually been applied to the kernel.

---

## Tested On

| Hardware | Firmware |
|---|---|
| GL.iNet GL-MT6000 (Flint 2) | OpenWrt 21.02-SNAPSHOT (Oct 2025 build) |

Community reports of working configurations on other MediaTek OpenWrt platforms are welcome.

---

## Known Limitations

- `rf-survey.sh` requires MediaTek `iwpriv` driver support. It will fail silently or with an error on non-MediaTek hardware.
- Speed test in `wired-audit.sh -v` requires `python3-speedtest-cli` to be installed via `opkg`.
- PHY rate and SNR parsing depends on driver reporting quality — some MediaTek driver versions report partial data. Scripts handle this gracefully with `[Info]` messages rather than false failures.
- DHCP hostname resolution requires `/tmp/dhcp.leases` to be populated (standard `dnsmasq` behaviour on OpenWrt).

---

## License

MIT — do what you want, attribution appreciated.

---

## Contributing

Issues and PRs welcome. If you're testing on hardware other than the GL-MT6000, please include your device model and OpenWrt version in any bug reports.
