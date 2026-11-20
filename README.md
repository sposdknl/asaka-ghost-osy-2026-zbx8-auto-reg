# Debian 13 VM se Zabbix Agent 2 (Vagrant)

Postup, jak pomocí Vagrantu vytvořit virtuální stroj s Debianem 13, nainstalovat na něj Zabbix Agent 2 a nechat ho automaticky zaregistrovat na monitorovacím serveru `enceladus.pfsense.cz`.

## Obsah repozitáře

| Soubor | Účel |
|---|---|
| `Vagrantfile` | Definice VM (box, síť, provisioning) |
| `install-zabbix-agent2.sh` | Instalace Zabbix Agent 2 z oficiálního repozitáře |
| `configure-zabbix-agent2.sh` | Konfigurace agenta (hostname, server, metadata) |
| `id_rsa.pub` | Veřejný SSH klíč nahrávaný do VM |
| `id_rsa` | Soukromý SSH klíč (**nikdy ho necommitovat**) |

## Požadavky

- VirtualBox
- Vagrant
- OpenSSH klient (ve Windows 10/11 je součástí systému, příkaz `ssh-keygen`)
- Přístup ze sítě k `enceladus.pfsense.cz` na portu 10051 (školní síť nebo VPN)

## 1. Vygenerování SSH klíče

Ve složce s Vagrantfilem (PowerShell):

```powershell
ssh-keygen -t rsa -b 4096 -f id_rsa -N '""'
```

Vzniknou soubory `id_rsa` (soukromý) a `id_rsa.pub` (veřejný). Veřejný klíč se při provisioningu nahraje do VM, abychom se mohli připojit přes SSH.

> Soukromý klíč patří do `.gitignore`. Pokud se někdy dostal na veřejné místo, vygenerujte nový.

## 2. Vagrantfile

```ruby
IMAGE_NAME = "bento/debian-13"

Vagrant.configure("2") do |config|
    config.ssh.insert_key = false

    config.vm.provider "virtualbox" do |v|
        v.memory = 2048
        v.cpus = 2
    end

    config.vm.define "debian" do |debian|
        debian.vm.box = IMAGE_NAME
        debian.vm.network "forwarded_port", guest: 22, host: 2206, host_ip: "127.0.0.1"
        debian.vm.hostname = "debian13"
    end

    config.vm.provision "file", source: "id_rsa.pub", destination: "~/.ssh/me.pub"
    config.vm.provision "shell", inline: <<-SHELL
        cat /home/vagrant/.ssh/me.pub >> /home/vagrant/.ssh/authorized_keys
    SHELL

    config.vm.provision "shell", path: "install-zabbix-agent2.sh"
    config.vm.provision "shell", path: "configure-zabbix-agent2.sh"
end
```

Poznámky:

- Cesta v `source:` u `file` provisioneru se počítá od složky, kde leží Vagrantfile. Soubor `id_rsa.pub` tam proto musí existovat, jinak Vagrant skončí chybou `File upload source file ... must exist`.
- SSH do VM je přesměrováno na `127.0.0.1:2206`.
- Shell provisionery běží pod rootem, `sudo` není potřeba.

## 3. Instalace agenta (`install-zabbix-agent2.sh`)

```bash
#!/usr/bin/env bash
set -e
export DEBIAN_FRONTEND=noninteractive

wget -q https://repo.zabbix.com/zabbix/8.0/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_8.0+debian13_all.deb
dpkg -i zabbix-release_latest_8.0+debian13_all.deb
apt-get update
apt-get install -y zabbix-agent2 zabbix-agent2-plugin-mongodb zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql
systemctl enable zabbix-agent2
systemctl restart zabbix-agent2
```

- Příkazy nesmí být zakomentované (`#`), jinak se nic nenainstaluje a konfigurační soubor `/etc/zabbix/zabbix_agent2.conf` nevznikne.
- Přepínač `-y` je nutný, protože při provisioningu nemá kdo odpovídat na dotazy apt.
- `set -e` zastaví skript při první chybě.

## 4. Konfigurace agenta (`configure-zabbix-agent2.sh`)

```bash
#!/usr/bin/env bash
set -e
CONF=/etc/zabbix/zabbix_agent2.conf

# při opakovaném spuštění se zachová stávající unikátní hostname
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
```

Co skript dělá:

- Vytvoří unikátní jméno hostu ve tvaru `kozakm-debian-<uuid>`. UUID se bere z `/proc/sys/kernel/random/uuid`, takže nezávisí na balíčku `uuidgen`.
- Smaže staré hodnoty `Hostname`, `Server`, `ServerActive`, `HostMetadata` a `Timeout` a zapíše nové, takže ho lze spouštět opakovaně.
- Záloha původní konfigurace se vytvoří jen jednou (`zabbix_agent2.conf-orig`).
- `HostMetadata=SPOS` používá autoregistrační akce na serveru, aby hostu přiřadila šablonu.

## 5. Spuštění

```powershell
vagrant up
```

Při změně skriptů na již běžící VM:

```powershell
vagrant provision
# nebo jen shell provisionery:
vagrant provision --provision-with shell
```

## 6. Ověření

Konfigurace agenta (soubor vyžaduje `sudo`):

```powershell
vagrant ssh -c "sudo grep -E '^(Hostname|Server|ServerActive|HostMetadata|Timeout)=' /etc/zabbix/zabbix_agent2.conf"
```

Stav služby a log:

```powershell
vagrant ssh -c "systemctl status zabbix-agent2 --no-pager"
vagrant ssh -c "sudo tail -n 30 /var/log/zabbix/zabbix_agent2.log"
```

Na webu Zabbixu (Data collection → Hosts) vyhledejte `kozakm`. Host se objeví pod plným jménem včetně UUID, obvykle do 2–3 minut po restartu agenta. Hodnoty uvidíte v Monitoring → Latest data.

## Řešení problémů

| Problém | Příčina a řešení |
|---|---|
| `File upload source file ... id_rsa.pub must exist` | Klíč chybí nebo je cesta špatně. Vygenerujte ho (krok 1) do složky s Vagrantfilem. |
| Host se na webu neobjeví | Instalační skript měl zakomentované příkazy, agent není nainstalovaný. Opravte skript a spusťte `vagrant provision`. |
| Hostname je bez UUID | Původní skript ho ořezával příkazem `cut -d'-' -f1,2`. Použijte skript z kroku 4. |
| `sed` nic nezměnil po opakovaném spuštění | Původní skript hledal výchozí hodnoty z čisté konfigurace a při druhém běhu přepsal zálohu. Skript z kroku 4 s tím problém nemá. |
| `grep: ... Permission denied` | Konfigurace není čitelná pro uživatele `vagrant`, použijte `sudo`. |
| Stav hostu „unknown“ (šedá ikona ZBX) | Za NATem VirtualBoxu server nedosáhne na port 10050 (pasivní kontroly). Aktivní kontroly (agent → server, port 10051) fungují, ikona se časem srovná, nebo ji ignorujte, pokud chodí data. |
| Žádná data v Latest data | Zkontrolujte log agenta, dostupnost `enceladus.pfsense.cz:10051` (`nc -zv enceladus.pfsense.cz 10051`) a že host má přiřazenou aktivní šablonu (např. „Linux by Zabbix agent active“). |

## Poznámky

- Jméno hostu (`Hostname=`) po registraci neměňte, jinak se agent zaregistruje znovu jako nový host.
- Po `vagrant destroy` se při dalším `vagrant up` vygeneruje nové UUID a vznikne nový host. Starý host na serveru zůstane nedostupný a lze ho smazat.
- Čitelnější název na webu lze nastavit v poli **Visible name** u hostu, aniž by se změnil `Hostname=` agenta.
- `.gitignore` doporučený obsah:

```
.vagrant/
id_rsa
```