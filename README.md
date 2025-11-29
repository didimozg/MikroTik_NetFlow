# 📘 Guide: Network Traffic Monitoring (NetFlow)

## Phase 1. Server Setup (LXC/Linux)

I have prepared a **unified script** that automates the entire process:

1.  Installs **ClickHouse** and creates the database table.
2.  Installs **GoFlow2** and configures it to write to a JSON file.
3.  Installs **Vector**, downloads the **GeoIP database**, and configures parsing.
4.  Sets up **Log Rotation** (to prevent the JSON file from filling the disk).

### How to run the script

1.  Log in to your LXC container console.
2.  Create the file:
    ```bash
    nano install_netflow.sh
    ```
3.  Paste the code below.
4.  Run it: `bash install_netflow.sh`

<!-- end list -->

```bash
#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== NetFlow Stack Installation (MikroTik -> GoFlow2 -> Vector -> ClickHouse) ===${NC}"
echo ""

# --- 1. PREPARATION ---
echo -e "${BLUE}[1/7] Updating system...${NC}"
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg wget

# --- 2. CLICKHOUSE (Database) ---
echo -e "${BLUE}[2/7] Installing ClickHouse...${NC}"

# Keys and Repository
mkdir -p /usr/share/keyrings
curl -fsSL "https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key" -o /tmp/clickhouse.key
if [ ! -s /tmp/clickhouse.key ]; then
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x8919F6BD2B48D754" -o /tmp/clickhouse.key
fi
cat /tmp/clickhouse.key | gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg --yes
rm /tmp/clickhouse.key

echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" | tee /etc/apt/sources.list.d/clickhouse.list
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clickhouse-server clickhouse-client

# Allow external access (required for Grafana)
echo "<clickhouse><listen_host>0.0.0.0</listen_host></clickhouse>" > /etc/clickhouse-server/config.d/listen_network.xml
chown clickhouse:clickhouse /etc/clickhouse-server/config.d/listen_network.xml

systemctl enable clickhouse-server
systemctl restart clickhouse-server

# Wait for start and create table
echo "Creating 'flows' table..."
sleep 5
clickhouse-client --query "CREATE TABLE IF NOT EXISTS default.flows (
    TimeReceived UInt64, TimeFlowStart UInt64, TimeFlowEnd UInt64,
    SrcAddr IPv6, DstAddr IPv6, SamplerAddress IPv6,
    SrcPort UInt16, DstPort UInt16, Proto UInt8, Etype UInt16,
    Bytes UInt64, Packets UInt64, SequenceNum UInt32, SamplingRate UInt64,
    InIf UInt32, OutIf UInt32, TCPFlags UInt16, LogStatus UInt32,
    SrcMac UInt64, DstMac UInt64, TimeFlowStartMs UInt64, TimeFlowEndMs UInt64,
    DstCountry String DEFAULT ''
) ENGINE = MergeTree()
PARTITION BY toDate(toDateTime(TimeReceived))
ORDER BY (TimeReceived, SrcAddr, DstAddr)
TTL toDateTime(TimeReceived) + INTERVAL 30 DAY;"

# --- 3. GOFLOW2 (Collector) ---
echo -e "${BLUE}[3/7] Installing GoFlow2 v2.2.3...${NC}"
cd /tmp
wget -q https://github.com/netsampler/goflow2/releases/download/v2.2.3/goflow2_2.2.3_amd64.deb
dpkg -i goflow2_2.2.3_amd64.deb
rm goflow2_2.2.3_amd64.deb

# Service Config (Writes JSON to file)
cat > /etc/systemd/system/goflow2.service <<EOF
[Unit]
Description=GoFlow2 NetFlow Collector
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/goflow2 -listen "netflow://:2055" -format "json" -transport "file" -transport.file "/var/log/netflow.json"
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable goflow2
systemctl restart goflow2

# --- 4. LOG ROTATION ---
echo -e "${BLUE}[4/7] Configuring Log Rotation...${NC}"
cat > /etc/logrotate.d/netflow <<EOF
/var/log/netflow.json {
    hourly
    rotate 1
    size 500M
    missingok
    notifempty
    copytruncate
    compress
}
EOF

# --- 5. VECTOR (Processor) ---
echo -e "${BLUE}[5/7] Installing Vector v0.51.1...${NC}"
wget -q https://github.com/vectordotdev/vector/releases/download/v0.51.1/vector_0.51.1-1_amd64.deb
dpkg -i vector_0.51.1-1_amd64.deb
rm vector_0.51.1-1_amd64.deb

# --- 6. GEOIP DATABASE ---
echo -e "${BLUE}[6/7] Downloading GeoIP Database...${NC}"
mkdir -p /etc/vector
wget -q -O /etc/vector/GeoLite2-City.mmdb "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"

# --- 7. VECTOR CONFIGURATION ---
echo -e "${BLUE}[7/7] Configuring Vector (JSON -> ClickHouse)...${NC}"

cat > /etc/vector/vector.yaml <<EOF
data_dir: "/var/lib/vector"

enrichment_tables:
  geoip_table:
    type: "geoip"
    path: "/etc/vector/GeoLite2-City.mmdb"

sources:
  goflow_file:
    type: "file"
    include: [ "/var/log/netflow.json" ]
    ignore_older_secs: 600

transforms:
  process_json:
    type: "remap"
    inputs: ["goflow_file"]
    source: |
      . = parse_json!(.message)
      
      # Time Handling (Rounding to seconds)
      ns_rec = to_float(.time_received_ns) ?? 0.0
      .TimeReceived = to_int(floor(ns_rec / 1000000000.0))
      ns_start = to_float(.time_flow_start_ns) ?? 0.0
      .TimeFlowStart = to_int(floor(ns_start / 1000000000.0))
      ns_end = to_float(.time_flow_end_ns) ?? 0.0
      .TimeFlowEnd = to_int(floor(ns_end / 1000000000.0))

      # Addresses (Clean up ::ffff:)
      raw_src = to_string(.src_addr) ?? "::"
      .SrcAddr = replace(raw_src, "::ffff:", "")
      raw_dst = to_string(.dst_addr) ?? "::"
      .DstAddr = replace(raw_dst, "::ffff:", "")
      .SamplerAddress = to_string(.sampler_address) ?? "::"

      # GeoIP Lookup
      geo_data, err = get_enrichment_table_record("geoip_table", { "ip": .DstAddr })
      if err == null && geo_data != null {
        .DstCountry = geo_data.country.names.en 
      } else {
        .DstCountry = ""
      }

      # Numeric Fields
      .SrcPort = to_int(.src_port) ?? 0
      .DstPort = to_int(.dst_port) ?? 0
      .Bytes = to_int(.bytes) ?? 0
      .Packets = to_int(.packets) ?? 0
      .SequenceNum = to_int(.sequence_num) ?? 0
      .SamplingRate = to_int(.sampling_rate) ?? 0
      .InIf = to_int(.in_if) ?? 0
      .OutIf = to_int(.out_if) ?? 0
      .TCPFlags = to_int(.tcp_flags) ?? 0

      # Placeholders
      .LogStatus = 0
      .SrcMac = 0
      .DstMac = 0
      .Etype = 0
      .TimeFlowStartMs = 0
      .TimeFlowEndMs = 0

      # Protocols (String -> Int)
      p_str = upcase(to_string(.proto) ?? "")
      if p_str == "ICMP" { .Proto = 1 }
      else {
        if p_str == "TCP" { .Proto = 6 }
        else {
          if p_str == "UDP" { .Proto = 17 }
          else { .Proto = 0 }
        }
      }

sinks:
  clickhouse_out:
    type: "clickhouse"
    inputs: ["process_json"]
    endpoint: "http://127.0.0.1:8123"
    database: "default"
    table: "flows"
    compression: "gzip"
    batch:
      max_bytes: 1048576
      timeout_secs: 1
    skip_unknown_fields: true
EOF

systemctl enable vector
systemctl restart vector

MY_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}=== INSTALLATION COMPLETE! ===${NC}"
echo "--------------------------------------------------"
echo "1. ClickHouse listening on ports 8123 (HTTP) and 9000 (TCP)."
echo "2. Server listening for NetFlow on UDP port 2055."
echo "--------------------------------------------------"
echo "Configure your MikroTik (Terminal):"
echo "/ip traffic-flow set enabled=yes interfaces=all active-flow-timeout=30s"
echo "/ip traffic-flow target add dst-address=$MY_IP port=2055 version=9"
echo "--------------------------------------------------"
echo "Grafana Connection:"
echo "Data Source Type: ClickHouse"
echo "URL: http://$MY_IP:8123"
```

-----

## Phase 2. MikroTik Configuration

Copy and paste these commands into your MikroTik terminal. Replace `SERVER_IP` with the IP address of your LXC container.

```mikrotik
# 1. Enable Traffic Flow (30s timeout for live graphs)
/ip traffic-flow set enabled=yes interfaces=all active-flow-timeout=30s inactive-flow-timeout=15s cache-entries=256k

# 2. Add Target Server (Replace SERVER_IP)
/ip traffic-flow target add dst-address=SERVER_IP port=2055 version=9
```

-----

## Phase 3. Grafana Configuration

### 1\. Connect Data Source

  * **Type:** ClickHouse
  * **URL:** `http://SERVER_IP:8123`
  * **Auth:** User: `default`, Password: (empty).
  * Click **Save & Test**.

### 2\. SQL Queries for Dashboards

Use these queries when creating panels (Visualization: **Table** or **Time Series**).

**A. Total Bandwidth Graph (Bits/sec)**
*(Visualization: Time Series, Unit: bits/sec)*

```sql
SELECT
    $__timeGroup(toDateTime(TimeReceived), '1m') as time,
    sum(Bytes) * 8 / 60 as "Bits/sec"
FROM flows
WHERE $__timeFilter(toDateTime(TimeReceived))
GROUP BY time
ORDER BY time ASC
```

**B. Top Destinations by Country**
*(Visualization: Table, Unit: bytes(IEC))*

```sql
SELECT
    -- Show Country Name if available, else 'Unknown'
    if(DstCountry != '', DstCountry, 'Unknown') as "Country",
    
    -- Clean IP address (remove ::ffff:)
    replaceOne(toString(DstAddr), '::ffff:', '') as "IP Address",
    
    -- Sum Traffic
    sum(Bytes) as "Traffic"

FROM flows
WHERE $__timeFilter(toDateTime(TimeReceived))
  -- Filter: Hide local traffic (optional)
  AND NOT startsWith(toString(DstAddr), '::ffff:192.168.')

GROUP BY "IP Address", "Country"
ORDER BY "Traffic" DESC
LIMIT 20
```

**C. Top Local Downloaders**
*(Visualization: Table / Bar Chart)*

```sql
SELECT
    replaceOne(toString(SrcAddr), '::ffff:', '') as "Local IP",
    sum(Bytes) as "Traffic"
FROM flows
WHERE $__timeFilter(toDateTime(TimeReceived))
  -- Filter: Match only local IPs
  AND startsWith(toString(SrcAddr), '::ffff:192.168.')
GROUP BY "Local IP"
ORDER BY "Traffic" DESC
LIMIT 10
```
<img width="1570" height="604" alt="изображение" src="https://github.com/user-attachments/assets/845376c5-c5ad-4f2c-b328-6620cd49dc1e" />
