#!/bin/bash
set -e

# Цвета
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Установка NetFlow Monitor (MikroTik -> GoFlow2 -> Vector -> ClickHouse) ===${NC}"
echo ""

# --- 1. ПОДГОТОВКА ---
echo -e "${BLUE}[1/6] Обновление системы...${NC}"
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg wget

# --- 2. CLICKHOUSE (База данных) ---
echo -e "${BLUE}[2/6] Установка ClickHouse...${NC}"

# Ключи и репозиторий
mkdir -p /usr/share/keyrings
curl -fsSL "https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key" | gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg --yes

echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" | tee /etc/apt/sources.list.d/clickhouse.list
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clickhouse-server clickhouse-client

# Разрешаем доступ к базе извне (для Grafana)
echo "<clickhouse><listen_host>0.0.0.0</listen_host></clickhouse>" > /etc/clickhouse-server/config.d/listen_network.xml
chown clickhouse:clickhouse /etc/clickhouse-server/config.d/listen_network.xml

systemctl enable clickhouse-server
systemctl restart clickhouse-server

# Ждем старта и создаем таблицу
echo "Создание таблицы..."
sleep 5
clickhouse-client --query "CREATE TABLE IF NOT EXISTS default.flows (
    TimeReceived UInt64,
    TimeFlowStart UInt64,
    TimeFlowEnd UInt64,
    SrcAddr IPv6,
    DstAddr IPv6,
    SamplerAddress IPv6,
    SrcPort UInt16,
    DstPort UInt16,
    Proto UInt8,
    Etype UInt16,
    Bytes UInt64,
    Packets UInt64,
    SequenceNum UInt32,
    SamplingRate UInt64,
    InIf UInt32,
    OutIf UInt32,
    TCPFlags UInt16,
    LogStatus UInt32,
    SrcMac UInt64,
    DstMac UInt64,
    TimeFlowStartMs UInt64,
    TimeFlowEndMs UInt64,
    DstCountry String DEFAULT ''
) ENGINE = MergeTree()
PARTITION BY toDate(toDateTime(TimeReceived))
ORDER BY (TimeReceived, SrcAddr, DstAddr)
TTL toDateTime(TimeReceived) + INTERVAL 30 DAY;"

# --- 3. GOFLOW2 (Коллектор) ---
echo -e "${BLUE}[3/6] Установка GoFlow2 v2.2.3...${NC}"
cd /tmp
wget -q https://github.com/netsampler/goflow2/releases/download/v2.2.3/goflow2_2.2.3_amd64.deb
dpkg -i goflow2_2.2.3_amd64.deb
rm goflow2_2.2.3_amd64.deb

# Создаем службу (Пишет в JSON файл)
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

# Настройка ротации логов (чтобы JSON не забил диск)
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

# --- 4. VECTOR (Обработчик) ---
echo -e "${BLUE}[4/6] Установка Vector v0.51.1...${NC}"
wget -q https://github.com/vectordotdev/vector/releases/download/v0.51.1/vector_0.51.1-1_amd64.deb
dpkg -i vector_0.51.1-1_amd64.deb
rm vector_0.51.1-1_amd64.deb

# --- 5. GEOIP БАЗА ---
echo -e "${BLUE}[5/6] Скачивание базы GeoIP...${NC}"
mkdir -p /etc/vector
wget -q -O /etc/vector/GeoLite2-City.mmdb "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"

# --- 6. КОНФИГУРАЦИЯ VECTOR ---
echo -e "${BLUE}[6/6] Настройка Vector (JSON -> ClickHouse)...${NC}"

cat > /etc/vector/vector.yaml <<EOF
data_dir: "/var/lib/vector"

# 1. GeoIP База
enrichment_tables:
  geoip_table:
    type: "geoip"
    path: "/etc/vector/GeoLite2-City.mmdb"

# 2. Источник (Файл от GoFlow2)
sources:
  goflow_file:
    type: "file"
    include: [ "/var/log/netflow.json" ]
    ignore_older_secs: 600

# 3. Преобразование (VRL скрипт)
transforms:
  process_json:
    type: "remap"
    inputs: ["goflow_file"]
    source: |
      . = parse_json!(.message)

      # Время (округление до секунд)
      ns_rec = to_float(.time_received_ns) ?? 0.0
      .TimeReceived = to_int(floor(ns_rec / 1000000000.0))
      ns_start = to_float(.time_flow_start_ns) ?? 0.0
      .TimeFlowStart = to_int(floor(ns_start / 1000000000.0))
      ns_end = to_float(.time_flow_end_ns) ?? 0.0
      .TimeFlowEnd = to_int(floor(ns_end / 1000000000.0))

      # Адреса (очистка от ::ffff:)
      raw_src = to_string(.src_addr) ?? "::"
      .SrcAddr = replace(raw_src, "::ffff:", "")
      raw_dst = to_string(.dst_addr) ?? "::"
      .DstAddr = replace(raw_dst, "::ffff:", "")
      .SamplerAddress = to_string(.sampler_address) ?? "::"

      # GeoIP (Определение страны)
      geo_data, err = get_enrichment_table_record("geoip_table", { "ip": .DstAddr })
      if err == null && geo_data != null {
        .DstCountry = geo_data.country.names.en 
      } else {
        .DstCountry = ""
      }

      # Числа
      .SrcPort = to_int(.src_port) ?? 0
      .DstPort = to_int(.dst_port) ?? 0
      .Bytes = to_int(.bytes) ?? 0
      .Packets = to_int(.packets) ?? 0
      .SequenceNum = to_int(.sequence_num) ?? 0
      .SamplingRate = to_int(.sampling_rate) ?? 0
      .InIf = to_int(.in_if) ?? 0
      .OutIf = to_int(.out_if) ?? 0
      .TCPFlags = to_int(.tcp_flags) ?? 0

      # Заглушки
      .LogStatus = 0
      .SrcMac = 0
      .DstMac = 0
      .Etype = 0
      .TimeFlowStartMs = 0
      .TimeFlowEndMs = 0

      # Протокол (Текст -> Число)
      p_str = upcase(to_string(.proto) ?? "")
      if p_str == "ICMP" { .Proto = 1 }
      else {
        if p_str == "TCP" { .Proto = 6 }
        else {
          if p_str == "UDP" { .Proto = 17 }
          else { .Proto = 0 }
        }
      }

# 4. Вывод (ClickHouse)
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
echo -e "${GREEN}=== УСТАНОВКА ЗАВЕРШЕНА! ===${NC}"
echo "--------------------------------------------------"
echo "1. ClickHouse слушает порты 8123 (HTTP) и 9000 (TCP)."
echo "2. Сервер ждет NetFlow на порту UDP 2055."
echo "--------------------------------------------------"
echo "Настройка MikroTik (Terminal):"
echo "/ip traffic-flow set enabled=yes interfaces=all active-flow-timeout=30s"
echo "/ip traffic-flow target add dst-address=$MY_IP port=2055 version=9"
echo "--------------------------------------------------"
echo "Подключение в Grafana:"
echo "Data Source: ClickHouse"
echo "URL: http://$MY_IP:8123"
