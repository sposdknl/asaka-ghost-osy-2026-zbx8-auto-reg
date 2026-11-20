#!/usr/bin/env bash
set -e
CONF=/etc/zabbix/zabbix_agent2.conf

# keep the existing unique hostname on re-runs, otherwise create a new one
EXISTING=$(grep -E '^Hostname=kozakm-debian-' "$CONF" | cut -d= -f2 || true)
ZBX_HOSTNAME=${EXISTING:-kozakm-debian-$(cat /proc/sys/kernel/random/uuid)}

[ -f "$CONF-orig" ] || cp -v "$CONF" "$CONF-orig"

sed -i -E '/^(Hostname|Server|ServerActive|HostMetadata|Timeout)=/d' "$CONF"
cat >> "$CONF" <<EOF
Hostname=$ZBX_HOSTNAME
Server=enceladus.pfsense.cz
ServerActive=enceladus.pfsense.cz
Timeout=30
HostMetadata=SPOS
EOF

echo "Zabbix hostname: $ZBX_HOSTNAME"
systemctl restart zabbix-agent2