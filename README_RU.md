# 📘 Инструкция: Мониторинг Трафика (NetFlow)

**Стек:** MikroTik → GoFlow2 (JSON) → Vector (GeoIP) → ClickHouse → Grafana.

-----

## Этап 1. Настройка Сервера (LXC)

Я подготовил **единый скрипт**, который сделает всю грязную работу:

1.  Установит **ClickHouse** и создаст таблицу.
2.  Установит **GoFlow2** и настроит его писать в файл.
3.  Установит **Vector**, скачает базу **GeoIP** и настроит парсинг.
4.  Настроит **ротацию логов** (чтобы JSON-файл не забил диск).

### Запуск скрипта

1.  Зайдите в консоль LXC контейнера.
2.  Создайте файл:
    ```bash
    nano install_netflow_stack_ru.sh
    ```
3.  Вставьте этот код целиком:

<!-- end list -->

```bash
#!/bin/bash
set -e

# Цвета
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Установка NetFlow Stack (MikroTik -> GoFlow2 -> Vector -> ClickHouse) ===${NC}"

# 1. УСТАНОВКА ЗАВИСИМОСТЕЙ
echo -e "${BLUE}[1/7] Подготовка системы...${NC}"
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg wget

# 2. CLICKHOUSE
echo -e "${BLUE}[2/7] Установка ClickHouse...${NC}"
mkdir -p /usr/share/keyrings
# Скачиваем ключ надежным методом
curl -fsSL "https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key" -o /tmp/clickhouse.key
if [ ! -s /tmp/clickhouse.key ]; then
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x8919F6BD2B48D754" -o /tmp/clickhouse.key
fi
cat /tmp/clickhouse.key | gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg --yes
rm /tmp/clickhouse.key

echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" | tee /etc/apt/sources.list.d/clickhouse.list
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clickhouse-server clickhouse-client

# Разрешаем доступ извне
echo "<clickhouse><listen_host>0.0.0.0</listen_host></clickhouse>" > /etc/clickhouse-server/config.d/listen_network.xml
chown clickhouse:clickhouse /etc/clickhouse-server/config.d/listen_network.xml
systemctl restart clickhouse-server

# Создаем таблицу
echo "Создание таблицы flows..."
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

# 3. GOFLOW2
echo -e "${BLUE}[3/7] Установка GoFlow2 v2.2.3...${NC}"
cd /tmp
wget -q https://github.com/netsampler/goflow2/releases/download/v2.2.3/goflow2_2.2.3_amd64.deb
dpkg -i goflow2_2.2.3_amd64.deb
rm goflow2_2.2.3_amd64.deb

# Служба GoFlow2 (Пишет JSON в файл)
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

# 4. РОТАЦИЯ ЛОГОВ
echo -e "${BLUE}[4/7] Настройка ротации логов...${NC}"
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

# 5. VECTOR
echo -e "${BLUE}[5/7] Установка Vector...${NC}"
wget -q https://github.com/vectordotdev/vector/releases/download/v0.51.1/vector_0.51.1-1_amd64.deb
dpkg -i vector_0.51.1-1_amd64.deb
rm vector_0.51.1-1_amd64.deb

# 6. GEOIP
echo -e "${BLUE}[6/7] Скачивание базы GeoIP...${NC}"
mkdir -p /etc/vector
wget -q -O /etc/vector/GeoLite2-City.mmdb "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"

# 7. КОНФИГУРАЦИЯ VECTOR
echo -e "${BLUE}[7/7] Настройка Vector...${NC}"
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
      
      ns_rec = to_float(.time_received_ns) ?? 0.0
      .TimeReceived = to_int(floor(ns_rec / 1000000000.0))
      ns_start = to_float(.time_flow_start_ns) ?? 0.0
      .TimeFlowStart = to_int(floor(ns_start / 1000000000.0))
      ns_end = to_float(.time_flow_end_ns) ?? 0.0
      .TimeFlowEnd = to_int(floor(ns_end / 1000000000.0))

      raw_src = to_string(.src_addr) ?? "::"
      .SrcAddr = replace(raw_src, "::ffff:", "")
      raw_dst = to_string(.dst_addr) ?? "::"
      .DstAddr = replace(raw_dst, "::ffff:", "")
      .SamplerAddress = to_string(.sampler_address) ?? "::"

      geo_data, err = get_enrichment_table_record("geoip_table", { "ip": .DstAddr })
      if err == null && geo_data != null { .DstCountry = geo_data.country_name } else { .DstCountry = "" }

      .SrcPort = to_int(.src_port) ?? 0
      .DstPort = to_int(.dst_port) ?? 0
      .Bytes = to_int(.bytes) ?? 0
      .Packets = to_int(.packets) ?? 0
      .SequenceNum = to_int(.sequence_num) ?? 0
      .SamplingRate = to_int(.sampling_rate) ?? 0
      .InIf = to_int(.in_if) ?? 0
      .OutIf = to_int(.out_if) ?? 0
      .TCPFlags = to_int(.tcp_flags) ?? 0
      .LogStatus = 0
      .SrcMac = 0
      .DstMac = 0
      .Etype = 0
      .TimeFlowStartMs = 0
      .TimeFlowEndMs = 0

      p_str = upcase(to_string(.proto) ?? "")
      if p_str == "ICMP" { .Proto = 1 } else { if p_str == "TCP" { .Proto = 6 } else { if p_str == "UDP" { .Proto = 17 } else { .Proto = 0 } } }

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
echo -e "${GREEN}=== ГОТОВО! ===${NC}"
echo "1. ClickHouse: http://$MY_IP:8123"
echo "2. NetFlow Server: $MY_IP порт 2055"
```

4.  Запустите: `bash install_netflow_stack.sh`

-----

## Этап 2. Настройка MikroTik

Зайдите в WinBox -\> New Terminal.
Скопируйте и вставьте (заменив `IP_СЕРВЕРА` на IP вашего LXC):

```mikrotik
# Включаем Traffic Flow и настраиваем частую отправку (30 сек) для живых графиков
/ip traffic-flow set enabled=yes interfaces=all active-flow-timeout=30s inactive-flow-timeout=15s cache-entries=256k

# Добавляем сервер-получатель
# ВАЖНО: Замените IP_СЕРВЕРА на адрес вашего LXC
/ip traffic-flow target add dst-address=IP_СЕРВЕРА port=2055 version=9
```

-----

## Этап 3. Настройка Grafana (Визуализация)

### 1\. Подключите ClickHouse

  * **Data Sources** -\> **Add** -\> **ClickHouse**.
  * **URL:** `http://IP_СЕРВЕРА:8123`
  * **Auth:** User: `default`, Password: (пусто).
  * Нажмите **Save & Test**.

### 2\. Создайте Дашборд

Создайте новый Dashboard и добавьте панели.

#### 📊 Панель 1: Общая скорость (График)

Показывает нагрузку на канал в битах/сек.

  * **Visualization:** Time Series
  * **SQL Query:**

<!-- end list -->

```sql
SELECT
    $__timeGroup(toDateTime(TimeReceived), '1m') as time,
    sum(Bytes) * 8 / 60 as "Bits/sec"
FROM flows
WHERE $__timeFilter(toDateTime(TimeReceived))
GROUP BY time
ORDER BY time ASC
```

  * **Settings (справа):**
      * Unit: **bits/sec**

#### 🌍 Панель 2: Куда уходит трафик (Таблица с флагами)

Показывает ТОП направлений с названиями стран.

  * **Visualization:** Table
  * **SQL Query:**

<!-- end list -->

```sql
SELECT
    -- Если страна определилась, показываем её, иначе Unknown
    if(DstCountry != '', DstCountry, 'Unknown') as "Страна",
    
    -- Чистим IP от мусора ::ffff:
    replaceOne(toString(DstAddr), '::ffff:', '') as "IP Адрес",
    
    -- Считаем сумму
    sum(Bytes) as "Трафик"

FROM flows
WHERE $__timeFilter(toDateTime(TimeReceived))
  -- Фильтр: показываем только внешний трафик (где есть страна)
  AND DstCountry != ''

GROUP BY "IP Адрес", "Страна"
ORDER BY "Трафик" DESC
LIMIT 20
```

  * **Settings (справа):**
      * Unit (для колонки Трафик): **bytes(IEC)**
      * Cell display mode (для Трафика): **Gradient gauge** (Красивая полоска).

#### 💻 Панель 3: Кто качает? (Локальные IP)

Показывает, какой компьютер в доме забил канал.

  * **Visualization:** Table / Bar Chart
  * **SQL Query:**

<!-- end list -->

```sql
SELECT
    replaceOne(toString(SrcAddr), '::ffff:', '') as "Локальный IP",
    sum(Bytes) as "Трафик"
FROM flows
WHERE $__timeFilter(toDateTime(TimeReceived))
  -- Фильтр: берем только локальные IP (начинаются на 192.168.)
  AND startsWith(toString(SrcAddr), '::ffff:192.168.')
GROUP BY "Локальный IP"
ORDER BY "Трафик" DESC
LIMIT 10
```

**Готово\! Теперь у вас есть профессиональный мониторинг сетевого трафика.**
