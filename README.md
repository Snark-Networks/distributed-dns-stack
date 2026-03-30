# Distributed DNS Stack

Authoritative reverse DNS server stack with dnsdist load balancer, CoreDNS, Prometheus metrics, Loki log aggregation, and Grafana dashboards. Deployed and managed with Ansible and Docker Compose.

## Architecture

```
DNS Query (port 53, UDP+TCP, IPv4+IPv6)
         │
         ▼
   ┌──────────────────────────────────┐   [dnsdist_servers]
   │   dnsdist  (port 53)             │
   │   load balancer — ACLs, health   │   • One or more hosts
   │   checks, rate limiting, logging │   • Scale horizontally by
   │   metrics:  :8083/metrics        │     adding to inventory
   └────────────┬─────────────────────┘
                │ TCP+UDP :5300
                │ (auto-configured from inventory)
                ▼
   ┌──────────────────────────────────┐   [coredns_servers]
   │   CoreDNS  (port 5300)           │
   │   authoritative — zone files +   │   • One or more hosts
   │   template PTR auto-generation   │   • Scale horizontally by
   │   metrics:  :9153/metrics        │     adding to inventory
   └──────────────────────────────────┘

   ┌──────────────────────────────────────────────────────────────┐
   │  Prometheus  scrapes dnsdist :8083 and CoreDNS :9153         │   [monitoring_servers]
   │  Promtail    tails dnsdist + CoreDNS container logs → Loki   │
   │  Loki        stores and indexes query logs                   │
   │  Grafana     dashboards at http://<server>:3000              │
   └──────────────────────────────────────────────────────────────┘
```

Each service tier is **independently deployable and horizontally scalable**:

- Add hosts to `[dnsdist_servers]` to scale the DNS frontend
- Add hosts to `[coredns_servers]` to scale the authoritative backend
- dnsdist.conf is **auto-generated** from the `[coredns_servers]` inventory — every CoreDNS host becomes a backend automatically; no manual config needed

Each tier runs its own Docker Compose stack using `network_mode: host`. dnsdist runs as root to bind port 53. systemd-resolved is disabled so port 53 is free. Zone files and Corefile live on CoreDNS servers only.

**Zones served** (replace with your actual reverse zones):
- `2.0.192.in-addr.arpa` — IPv4 reverse DNS for 192.0.2.0/24
- `0.0.8.b.d.0.1.0.0.2.ip6.arpa` — IPv6 reverse DNS for 2001:db8::/40

> **Note:** IP addresses and domains in this repo use RFC 5737 (192.0.2.0/24) and RFC 3849 (2001:db8::/40) documentation ranges. Replace them with your own network ranges and domain before deploying.

---

## Deployment Models

The inventory has three independent groups — any can run on the same host or separate hosts:

| Group | Runs | Scales by |
|-------|------|-----------|
| `dnsdist_servers` | dnsdist (port 53 frontend) | Adding hosts to this group |
| `coredns_servers` | CoreDNS (port 5300 backend) | Adding hosts to this group |
| `monitoring_servers` | Prometheus + Loki + Grafana | Fixed at one host |

### All-in-One (Same Host for Everything)

Put the same IP in all three groups. dnsdist will automatically use `127.0.0.1` as the CoreDNS backend address:

```yaml
dnsdist_servers:
  hosts:
    server01:
      ansible_host: 192.0.2.1
coredns_servers:
  hosts:
    server01:
      ansible_host: 192.0.2.1
monitoring_servers:
  hosts:
    monitoring01:
      ansible_host: 192.0.2.1
```

No other changes needed — all defaults are configured for same-server operation.

### dnsdist and CoreDNS on Separate Hosts

Put different IPs in each group. dnsdist.conf is auto-generated with the CoreDNS host as a backend:

```yaml
dnsdist_servers:
  hosts:
    dnsdist01:
      ansible_host: 192.0.2.1
      metrics_scrape_address: "192.0.2.1"

coredns_servers:
  hosts:
    coredns01:
      ansible_host: 192.0.2.10
      metrics_scrape_address: "192.0.2.10"

monitoring_servers:
  hosts:
    monitoring01:
      ansible_host: 192.0.2.20
```

Update group_vars for split networking:

```yaml
# group_vars/dnsdist_servers.yml
dnsdist_webserver_acl: "127.0.0.0/8, ::1/128, 192.0.2.20/32"  # allow monitoring server
loki_push_url: "http://192.0.2.20:3100/loki/api/v1/push"

# group_vars/coredns_servers.yml
loki_push_url: "http://192.0.2.20:3100/loki/api/v1/push"

# group_vars/monitoring_servers.yml
loki_http_listen_address: "0.0.0.0"   # accept Promtail from remote DNS servers
```

Firewall requirements:
- dnsdist hosts → CoreDNS hosts: TCP+UDP **5300**
- monitoring host → dnsdist hosts: TCP **8083**
- monitoring host → CoreDNS hosts: TCP **9153**
- DNS hosts → monitoring host: TCP **3100** (Loki)

### Horizontal Scaling — Multiple dnsdist Frontends

Add hosts to `dnsdist_servers`. Each one gets the same auto-generated backend list:

```yaml
dnsdist_servers:
  hosts:
    dnsdist01:
      ansible_host: 192.0.2.1
      metrics_scrape_address: "192.0.2.1"
    dnsdist02:
      ansible_host: 192.0.2.2
      metrics_scrape_address: "192.0.2.2"
```

```bash
make deploy-dnsdist       # provisions the new frontend
make deploy-monitoring    # updates Prometheus to scrape it
```

### Horizontal Scaling — Multiple CoreDNS Backends

Add hosts to `coredns_servers` and to the relevant `site_*` group. Only the CoreDNS hosts in a dnsdist's site group become its backends:

```yaml
coredns_servers:
  hosts:
    coredns-us-east-1: { ansible_host: 192.0.2.10, metrics_scrape_address: "192.0.2.10" }
    coredns-us-east-2: { ansible_host: 192.0.2.11, metrics_scrape_address: "192.0.2.11" }

site_us_east:
  hosts:
    dnsdist-us-east:
    coredns-us-east-1:
    coredns-us-east-2:
```

```bash
make deploy-coredns       # provisions new CoreDNS server with zone files
make deploy-dnsdist       # regenerates dnsdist.conf with new backend included
make deploy-monitoring    # updates Prometheus to scrape new server
```

### Multiple Geographic Sites

Create one `site_*` group per location. Each dnsdist frontend uses only the CoreDNS servers in its own site — no cross-site backend traffic:

```yaml
dnsdist_servers:
  hosts:
    dnsdist-us-east:  { ansible_host: 192.0.2.1 }
    dnsdist-eu-west:  { ansible_host: 198.51.100.1 }

coredns_servers:
  hosts:
    coredns-us-east-1: { ansible_host: 192.0.2.10 }
    coredns-us-east-2: { ansible_host: 192.0.2.11 }
    coredns-eu-west-1: { ansible_host: 198.51.100.10 }

site_us_east:
  hosts:
    dnsdist-us-east:
    coredns-us-east-1:
    coredns-us-east-2:

site_eu_west:
  hosts:
    dnsdist-eu-west:
    coredns-eu-west-1:
```

`dnsdist-us-east` gets backends `coredns-us-east-1` and `coredns-us-east-2`. `dnsdist-eu-west` gets only `coredns-eu-west-1`. The backend list is resolved at deploy time from inventory — no per-host variables required.

To add a new site: add a `site_<name>` group, add hosts to the tier groups, then:
```bash
make deploy-coredns    # new CoreDNS servers
make deploy-dnsdist    # new dnsdist servers (with correct site backends)
make deploy-monitoring # update Prometheus scrape config
```

---

## Prerequisites

On the **control machine** (where you run Ansible and make):

```bash
# Ansible
sudo apt install ansible          # Ubuntu/Debian
# or: brew install ansible        # macOS

# bind9utils — provides named-checkzone for local zone validation
sudo apt install bind9utils       # Ubuntu/Debian
# or: brew install bind           # macOS

# Python 3 — required by scripts/ipv6-ptr.sh for IPv6 address expansion
# Usually pre-installed; verify with: python3 --version

# SSH key must be present at ~/.ssh/id_rsa and authorized on all target servers
# Verify with: ssh root@YOUR_SERVER_IP echo ok
```

On the **target servers**:

| Requirement | Detail |
|---|---|
| **OS** | Ubuntu 24.04 LTS (recommended) or Debian 12. **RHEL, Fedora, Alpine, and other non-Debian systems are not supported.** The playbook will fail immediately with a clear error if run against an unsupported OS. |
| **Pre-installed software** | None — Ansible installs Docker CE and all dependencies from scratch. |
| **Access** | Root SSH access, or a user with passwordless `sudo`. |

---

## First-Time Deployment

```bash
# 1. Clone this repo
git clone <repo-url>
cd distributed-dns-stack

# 2. Edit the inventory — set your server IPs and deployment topology
$EDITOR ansible/inventory/hosts.yml

# 3. Edit zone files — update zone names, SOA nameservers, and NS records
$EDITOR zones/db.2.0.192.in-addr.arpa
$EDITOR zones/db.0.0.8.b.d.0.1.0.0.2.ip6.arpa

# 4. Update the Corefile template with your zone names and domain
#    In roles/coredns/templates/Corefile.j2, replace every occurrence of:
#      2.0.192.in-addr.arpa          → your IPv4 reverse zone name
#      0.0.8.b.d.0.1.0.0.2.ip6.arpa → your IPv6 reverse zone name
#      example.com                   → your domain (in all 'answer' lines)
#    See "Adding a New Zone" for full step-by-step instructions.
$EDITOR ansible/roles/coredns/templates/Corefile.j2

# 5. Update the dnsdist health check zone to match a zone CoreDNS will serve
$EDITOR ansible/inventory/group_vars/dnsdist_servers.yml   # dnsdist_health_check_zone

# 6. Change the default password (used in dnsdist and Prometheus — one place)
$EDITOR ansible/inventory/group_vars/all.yml               # dnsdist_webserver_password

# 7. Change the Grafana admin password
$EDITOR ansible/roles/monitoring/files/docker-compose.yml  # GF_SECURITY_ADMIN_PASSWORD

# 8. Full deployment: installs Docker, deploys all tiers, syncs zones
make deploy
```

Ansible will:
1. Disable systemd-resolved if active (so dnsdist can bind port 53), and write a static `/etc/resolv.conf` (1.1.1.1 / 8.8.8.8) if one is not already present
2. Install Docker CE and the Compose plugin
3. Deploy CoreDNS on `coredns_servers` with zone files
4. Deploy dnsdist on `dnsdist_servers` with auto-generated backend list from inventory
5. Deploy Promtail (log shipper) on all DNS servers
6. Register all stacks as systemd services (auto-start on boot)
7. Deploy Prometheus, Loki, and Grafana on the monitoring server

---

## Repository Structure

```
distributed-dns-stack/
├── Makefile                          # Common operation shortcuts
├── zones/                            # Zone files — SOA and NS authority records
│   ├── db.2.0.192.in-addr.arpa
│   └── db.0.0.8.b.d.0.1.0.0.2.ip6.arpa
├── scripts/
│   ├── update-serial.sh              # Bump SOA serial (YYYYMMDDnn format)
│   ├── check-zones.sh                # Validate all zones with named-checkzone
│   └── ipv6-ptr.sh                   # Compute PTR label for an IPv6 address
└── ansible/
    ├── ansible.cfg
    ├── inventory/
    │   ├── hosts.yml                 # Server inventory (dnsdist_servers + coredns_servers + monitoring_servers)
    │   └── group_vars/
    │       ├── all.yml               # Shared vars (dnsdist_webserver_password)
    │       ├── dnsdist_servers.yml   # dnsdist vars (webserver address, ACL, health check zone)
    │       ├── coredns_servers.yml   # CoreDNS vars (metrics address, DNS port)
    │       └── monitoring_servers.yml # Monitoring server vars (Loki listen address)
    ├── site.yml                      # Full deployment (all tiers in dependency order)
    ├── deploy-dns.yml                # Both DNS tiers (CoreDNS then dnsdist)
    ├── deploy-coredns.yml            # CoreDNS backend servers only
    ├── deploy-dnsdist.yml            # dnsdist frontend servers only
    ├── deploy-zones.yml              # Zone files only (fast reload, no Docker changes)
    ├── deploy-monitoring.yml         # Monitoring stack + Promtail config update
    ├── deploy-monitoring-fresh.yml   # First-time monitoring deployment (installs Docker first)
    └── roles/
        ├── docker/                   # Installs Docker CE, disables systemd-resolved
        ├── dnsdist/                  # Deploys dnsdist frontend
        │   ├── tasks/main.yml
        │   ├── handlers/main.yml
        │   ├── templates/
        │   │   └── dnsdist.conf.j2   # Backends auto-generated from [coredns_servers] inventory
        │   └── files/
        │       └── docker-compose.yml
        ├── coredns/                  # Deploys CoreDNS backend
        │   ├── tasks/main.yml
        │   ├── handlers/main.yml
        │   ├── templates/
        │   │   └── Corefile.j2       # CoreDNS config (Jinja2 template)
        │   └── files/
        │       └── docker-compose.yml
        ├── dns-zones/                # Syncs zone files to coredns_servers, reloads CoreDNS
        ├── promtail/                 # Deploys Promtail on DNS servers (ships logs to Loki)
        │   ├── templates/config.yml.j2
        │   └── files/docker-compose.yml
        └── monitoring/               # Deploys Prometheus + Loki + Grafana
            ├── templates/
            │   ├── prometheus.yml.j2 # Scrapes dnsdist_servers :8083 + coredns_servers :9153
            │   └── loki-config.yml.j2
            └── files/
                ├── docker-compose.yml
                └── grafana/provisioning/
```

---

## Make Targets

| Target | What it does |
|--------|-------------|
| `make deploy` | Full deployment: Docker + all tiers + zones + monitoring |
| `make deploy-dns` | Both DNS tiers: CoreDNS backends then dnsdist frontends |
| `make deploy-coredns` | CoreDNS backend servers only |
| `make deploy-dnsdist` | dnsdist frontend servers only (also regenerates backend list from inventory) |
| `make deploy-zones` | Sync zone files and reload CoreDNS only (fast — no Docker changes) |
| `make deploy-monitoring` | Monitoring stack + updates Promtail config on all DNS servers |
| `make deploy-monitoring-fresh` | First-time monitoring deployment — installs Docker first |
| `make check` | Validate all zone files locally with named-checkzone |
| `make reload` | Send SIGHUP to CoreDNS on all `coredns_servers` (immediate zone reload) |
| `make test` | Run DNS smoke tests against dnsdist and CoreDNS directly |
| `make logs-dnsdist` | Tail dnsdist container logs on primary dnsdist server |
| `make logs-coredns` | Tail CoreDNS container logs on primary CoreDNS server |
| `make mon-logs` | Tail monitoring container logs |
| `make mon-status` | Show monitoring container status |

---

## Managing Zone Files

Zone files live in `zones/`. They contain **SOA and NS records only** — PTR records for known hosts are managed as template blocks in the Corefile (see [Zone Templates](#zone-templates-auto-generated-ptr-records) below).

### Editing a Zone File

Common reasons to edit a zone file: updating nameservers, changing SOA parameters, or updating the serial after any change.

```bash
# 1. Edit the zone file
$EDITOR zones/db.2.0.192.in-addr.arpa

# 2. Bump the SOA serial — always required after any change
./scripts/update-serial.sh

# 3. Validate locally
make check

# 4. Deploy — copies files to all servers and sends SIGHUP to CoreDNS
make deploy-zones
```

**Changing nameservers:** update both the SOA's primary NS field and the `NS` record(s):
```
@   IN  SOA  ns1.example.com. hostmaster.example.com. ( ... )
@   IN  NS   ns1.example.com.
@   IN  NS   ns2.example.com.   ; add secondary
```

**Changing SOA timing parameters:**
```
@  IN  SOA  ns1.example.com. hostmaster.example.com. (
       2026032801   ; Serial   — increment after every change (YYYYMMDDnn)
       3600         ; Refresh  — how often secondary NS servers poll for changes
       900          ; Retry    — retry interval if a refresh fails
       604800       ; Expire   — secondary stops answering if it can't reach primary after this long
       300          ; Minimum  — negative caching TTL (NXDOMAIN TTL)
   )
```

After any change, bump the serial and run `make deploy-zones`. CoreDNS receives a SIGHUP and re-reads the file within seconds. No downtime.

### IPv6 PTR Labels

IPv6 PTR records require reversing every nibble (hex digit) of the address. Use the helper script:

```bash
# Show the full PTR name and the label relative to your zone
./scripts/ipv6-ptr.sh 2001:db8:f9:2::13:1 0.0.8.b.d.0.1.0.0.2.ip6.arpa
```

Manual computation: expand the address to 32 hex digits, reverse them, join with dots, append `.ip6.arpa.`

```
2001:0db8:00f9:0002:0000:0000:0013:0001
→ 1.0.0.0.3.1.0.0.0.0.0.0.0.0.0.0.2.0.0.0.9.f.0.0.8.b.d.0.1.0.0.2.ip6.arpa.
```

---

## Adding a New Zone

Each reverse DNS zone requires three things: a zone file, a Corefile server block, and a dnsdist health check zone update.

### Step 1 — Determine the Zone Name

**IPv4:** reverse the network octets (drop the host octet for a /24), append `.in-addr.arpa`:

| Network | Zone name |
|---------|-----------|
| `10.0.1.0/24` | `1.0.10.in-addr.arpa` |
| `192.168.10.0/24` | `10.168.192.in-addr.arpa` |
| `203.0.113.0/24` | `113.0.203.in-addr.arpa` |

**IPv6:** expand the address, take the first N nibbles of the prefix (N = prefix\_length / 4), reverse them, join with dots, append `.ip6.arpa`:

| Prefix | Prefix length | Fixed nibbles | Zone name |
|--------|--------------|---------------|-----------|
| `2001:db8::/32` | /32 | 8 | `8.b.d.0.1.0.0.2.ip6.arpa` |
| `2001:db8::/40` | /40 | 10 | `0.0.8.b.d.0.1.0.0.2.ip6.arpa` |
| `2001:db8:1::/48` | /48 | 12 | `1.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa` |
| `2001:db8:1:2::/64` | /64 | 16 | `2.0.0.0.1.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa` |

### Step 2 — Create the Zone File

Create `zones/db.<zone-name>`. For an IPv4 /24 (`10.0.1.0/24`):

```
$ORIGIN 1.0.10.in-addr.arpa.
$TTL 3600

@   IN  SOA  ns1.example.com. hostmaster.example.com. (
                 2026010101  ; Serial
                 3600        ; Refresh
                 900         ; Retry
                 604800      ; Expire
                 300         ; Minimum TTL
             )

@   IN  NS   ns1.example.com.
```

For IPv6, the `$ORIGIN` is the zone name. No PTR records go here — they are handled by templates in the Corefile.

### Step 3 — Add a Corefile Server Block

Open `ansible/roles/coredns/templates/Corefile.j2` and add a server block. The file is a Jinja2 template — use `{{ coredns_prometheus_address }}` for the prometheus directive so it picks up the correct address from `group_vars/coredns_servers.yml`. See [Zone Templates](#zone-templates-auto-generated-ptr-records) for the full template syntax and how to adapt it for different prefix lengths.

**IPv4 /24 example** (`1.0.10.in-addr.arpa`):

```
1.0.10.in-addr.arpa.:5300 {
    file /zones/db.1.0.10.in-addr.arpa {
        reload 60s
    }

    # Explicit PTR for a known host — add one block per host, before the catch-all
    template IN PTR 1.0.10.in-addr.arpa. {
        match ^5\.1\.0\.10\.in-addr\.arpa\.$
        answer "{{ .Name }} 3600 IN PTR gateway.example.com."
        fallthrough
    }

    # Catch-all: auto-generate PTR for any IP not matched above
    template IN PTR 1.0.10.in-addr.arpa. {
        match ^(?P<octet>[0-9]+)\.1\.0\.10\.in-addr\.arpa\.$
        answer "{{ .Name }} 3600 IN PTR 10-0-1-{{ .Group.octet }}.example.com."
    }

    transfer { to * }
    prometheus {{ coredns_prometheus_address }}
    log
    errors
    reload
}
```

> **Note:** `{{ coredns_prometheus_address }}` is a Jinja2 variable resolved by Ansible. `{{ .Name }}` and `{{ .Group.octet }}` are CoreDNS Go template fields — type them literally in the `.j2` file. See the existing server blocks in `Corefile.j2` for the correct pattern using `{% raw %}` blocks.

**IPv6 /48 example** (`1.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa` for `2001:db8:1::/48`):

A /48 leaves 80 variable bits = 20 nibbles. Groups of 4 produce 5 clean groups — no prefix correction needed.

```
1.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa.:5300 {
    file /zones/db.1.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa {
        reload 60s
    }

    # Catch-all: auto-generate PTR (20 variable nibbles → 5 groups of 4)
    template IN PTR 1.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa. {
        match ^(?P<n1>[0-9a-f])\.(?P<n2>[0-9a-f])\.(?P<n3>[0-9a-f])\.(?P<n4>[0-9a-f])\.(?P<n5>[0-9a-f])\.(?P<n6>[0-9a-f])\.(?P<n7>[0-9a-f])\.(?P<n8>[0-9a-f])\.(?P<n9>[0-9a-f])\.(?P<n10>[0-9a-f])\.(?P<n11>[0-9a-f])\.(?P<n12>[0-9a-f])\.(?P<n13>[0-9a-f])\.(?P<n14>[0-9a-f])\.(?P<n15>[0-9a-f])\.(?P<n16>[0-9a-f])\.(?P<n17>[0-9a-f])\.(?P<n18>[0-9a-f])\.(?P<n19>[0-9a-f])\.(?P<n20>[0-9a-f])\.1\.0\.0\.0\.8\.b\.d\.0\.1\.0\.0\.2\.ip6\.arpa\.$
        answer "{{ .Name }} 3600 IN PTR ip6-{{ .Group.n20 }}{{ .Group.n19 }}{{ .Group.n18 }}{{ .Group.n17 }}-{{ .Group.n16 }}{{ .Group.n15 }}{{ .Group.n14 }}{{ .Group.n13 }}-{{ .Group.n12 }}{{ .Group.n11 }}{{ .Group.n10 }}{{ .Group.n9 }}-{{ .Group.n8 }}{{ .Group.n7 }}{{ .Group.n6 }}{{ .Group.n5 }}-{{ .Group.n4 }}{{ .Group.n3 }}{{ .Group.n2 }}{{ .Group.n1 }}.example.com."
    }

    transfer { to * }
    prometheus {{ coredns_prometheus_address }}
    log
    errors
    reload
}
```

### Step 4 — Update the dnsdist Health Check

dnsdist performs SOA health checks against a specific zone to determine if CoreDNS is alive. Any zone CoreDNS serves will work — you only need to update it if you remove the zone it currently checks. To check against your new zone, edit `ansible/inventory/group_vars/dnsdist_servers.yml`:

```yaml
dnsdist_health_check_zone: "1.0.10.in-addr.arpa."  # any zone CoreDNS serves
```

### Step 5 — Deploy

```bash
make deploy
```

CoreDNS needs a container restart (not just a SIGHUP) to pick up new server blocks in the Corefile. `make deploy` handles this automatically.

---

## Zone Templates (Auto-generated PTR Records)

CoreDNS's `template` plugin generates PTR responses dynamically for IPs that don't have explicit records. This means every IP in your range returns a valid PTR instead of NXDOMAIN.

### How It Works

The Corefile uses a two-level template chain for each zone:

1. **Specific template** — exact-match regex for known hosts; has `fallthrough` so non-matching queries reach the next template
2. **Catch-all template** — matches any IP in the zone and generates an automatic hostname

```
CoreDNS plugin chain per zone:
  file plugin         → serves SOA, NS records; always passes through to next plugin
  specific template   → matches explicit hosts (e.g. 192.0.2.1 → host1.example.com)
      ↓ (fallthrough on no-match)
  catch-all template  → auto-generates PTR for everything else
```

### Auto-generated Hostname Format

| Zone | Example query | Generated PTR |
|------|--------------|---------------|
| IPv4 /24 | `dig -x 192.0.2.200` | `192-0-2-200.example.com.` |
| IPv6 /40 | `dig -x 2001:db8:f9:2::1` | `ip6-00f9-0002-0000-0000-0000-0001.example.com.` |

### Changing the Auto-generated Hostname Format

The format is controlled by the `answer` line in the catch-all template block. Edit `ansible/roles/coredns/templates/Corefile.j2` and change it to whatever naming convention you prefer.

**IPv4 — current format** (`192-0-2-N.example.com`):
```
answer "{{ .Name }} 3600 IN PTR 192-0-2-{{ .Group.octet }}.example.com."
```

**IPv4 — alternative: subdomain style** (`ptr.192.0.2.N.example.com`):
```
answer "{{ .Name }} 3600 IN PTR ptr.192.0.2.{{ .Group.octet }}.example.com."
```

**Changing the domain suffix** — replace `example.com` with your domain throughout the Corefile:
```
answer "{{ .Name }} 3600 IN PTR 192-0-2-{{ .Group.octet }}.yourdomain.net."
```

**IPv6 — current format** (`ip6-00f9-0002-...-0001.example.com`):
```
answer "{{ .Name }} 3600 IN PTR ip6-00{{ .Group.n22 }}{{ .Group.n21 }}-...-{{ .Group.n1 }}.example.com."
```

The `ip6-` prefix and grouping are just convention — change them to any format that suits your naming scheme. After editing, run `make deploy`.

### Adding or Editing an Explicit PTR Record

**Add** a template block **before** the catch-all block for the relevant zone:

IPv4 — the `match` is the full PTR query name with each dot escaped as `\.`:
```
template IN PTR 2.0.192.in-addr.arpa. {
    match ^14\.2\.0\.192\.in-addr\.arpa\.$
    answer "{{ .Name }} 3600 IN PTR newhost.example.com."
    fallthrough
}
```

IPv6 — first get the PTR label:
```bash
./scripts/ipv6-ptr.sh 2001:db8:f9:2::14:1 0.0.8.b.d.0.1.0.0.2.ip6.arpa
# Zone label: 1.0.0.0.4.1.0.0.0.0.0.0.0.0.0.0.2.0.0.0.9.f.0.0
```

Then add a template block — the `match` is the full query name (zone label + zone name), each dot escaped:
```
template IN PTR 0.0.8.b.d.0.1.0.0.2.ip6.arpa. {
    match ^1\.0\.0\.0\.4\.1\.0\.0\.0\.0\.0\.0\.0\.0\.0\.0\.2\.0\.0\.0\.9\.f\.0\.0\.8\.b\.d\.0\.1\.0\.0\.2\.ip6\.arpa\.$
    answer "{{ .Name }} 3600 IN PTR newhost.example.com."
    fallthrough
}
```

**Edit** an existing explicit record — find the template block with the matching `match` regex and change the hostname in the `answer` line.

**Remove** an explicit record — delete the entire `template` block. The catch-all will then generate an auto-PTR for that IP instead.

After any Corefile change, run `make deploy`.

### Adapting Templates for Different Prefix Lengths

The catch-all template regex must match exactly the variable nibbles for the zone's prefix length.

**IPv4** always uses a single capture group for the last octet — no adjustment needed for /24.

**IPv6** — the number of capture groups equals the number of variable nibbles (128 − prefix\_length) / 4:

| Prefix length | Variable nibbles | Capture groups | Groups of 4 in hostname |
|--------------|-----------------|----------------|------------------------|
| /32 | 24 | n1–n24 | 6 clean groups |
| /40 | 22 | n1–n22 | 5 groups + 2 (prepend `00`) |
| /48 | 20 | n1–n20 | 5 clean groups |
| /56 | 18 | n1–n18 | 4 groups + 2 (prepend `00`) |
| /64 | 16 | n1–n16 | 4 clean groups |

**"Prepend 00" rule:** if the prefix length is not a multiple of 16 (not aligned to an IPv6 group boundary), the first variable nibbles cover a partial group. The hostname can be made readable by hard-coding the fixed nibbles of that partial group as a prefix in the `answer`.

For the /40 example (`2001:db8::/40`): the prefix covers `2001:db8:00` — the `00` part of the 3rd group is fixed. The answer prefixes `00` before the two MSB variable nibbles to reconstruct the full 3rd group:
```
answer "... ip6-00{{ .Group.n22 }}{{ .Group.n21 }}-..."
           ^^— fixed nibbles from zone prefix
```

For /32 and /48, the prefix aligns to group boundaries so no prefix correction is needed.

**Building the regex for a new prefix length** — replace the zone suffix and adjust the number of `(?P<nN>[0-9a-f])` groups:

```
# /48 zone — 20 variable nibbles — zone suffix is your zone name
match ^(?P<n1>[0-9a-f])\.(?P<n2>[0-9a-f])\ ... \.(?P<n20>[0-9a-f])\.ZONE\.SUFFIX\.ip6\.arpa\.$
```

The answer template reads captures from highest (MSB) to lowest (LSB): `{{ .Group.n20 }}{{ .Group.n19 }}...{{ .Group.n1 }}`.

### Two Template Systems in Corefile.j2

The Corefile is a Jinja2 template (rendered by Ansible at deploy time) that contains CoreDNS Go template syntax inside `answer` lines. These are two completely separate template engines:

| Syntax | Engine | Resolved by | Example |
|--------|--------|-------------|---------|
| `{{ coredns_prometheus_address }}` | Jinja2 | Ansible at deploy time | Becomes `127.0.0.1:9153` |
| `{{ .Name }}`, `{{ .Group.octet }}` | Go text/template | CoreDNS at query time | Becomes the queried name / captured regex group |

When editing `Corefile.j2`, Ansible variables use `{{ var_name }}` and CoreDNS template fields use `{{ .Field }}`. The CoreDNS fields are protected from Jinja2 processing using `{% raw %}...{% endraw %}` blocks (without the `-` whitespace-control dash) wrapping entire template sections — copy this pattern from the existing server blocks when adding new ones.

### CoreDNS Template Syntax Notes (v1.11.x)

- Named capture groups use `.Group.name`, **not** `.Matches[n]`
- `fallthrough` in a template block means: fall through to the next plugin **only when the match fails**
- The `file` plugin always calls the next plugin after writing its response (by design, to allow DNSSEC stacking); templates therefore always run and the last one to write wins for PTR queries
- Multiple `template` blocks in the same server block are processed in order — first match wins (provided prior blocks use `fallthrough`)

---

## Adding a New DNS Server

### Adding a CoreDNS backend

1. Provision a fresh Ubuntu 24.04 server with your SSH key
2. Add it to `[coredns_servers]` in `ansible/inventory/hosts.yml`:
   ```yaml
   coredns_servers:
     hosts:
       coredns01:
         ansible_host: 192.0.2.10
         metrics_scrape_address: "192.0.2.10"
       coredns02:                              # new
         ansible_host: 192.0.2.11
         metrics_scrape_address: "192.0.2.11"
   ```
3. Run `make deploy-coredns` — provisions Docker, CoreDNS, and zone files on the new server only
4. Run `make deploy-dnsdist` — regenerates `dnsdist.conf` on all frontends to include the new backend automatically
5. Run `make deploy-monitoring` — updates Prometheus scrape config to include the new server
6. Update your NS records to include the new server if it serves as an authoritative NS

### Adding a dnsdist frontend

1. Provision a fresh Ubuntu 24.04 server with your SSH key
2. Add it to `[dnsdist_servers]` in `ansible/inventory/hosts.yml`:
   ```yaml
   dnsdist_servers:
     hosts:
       dnsdist01:
         ansible_host: 192.0.2.1
         metrics_scrape_address: "192.0.2.1"
       dnsdist02:                             # new
         ansible_host: 192.0.2.2
         metrics_scrape_address: "192.0.2.2"
   ```
3. Run `make deploy-dnsdist` — provisions Docker and dnsdist on the new server. The full CoreDNS backend list is auto-generated from inventory.
4. Run `make deploy-monitoring` — updates Prometheus scrape config to include the new server

---

## Restricting Zone Transfers (AXFR)

By default, zone transfers are open to any host. To restrict to specific secondary nameservers, edit the `transfer` block in `ansible/roles/coredns/templates/Corefile.j2`:

```
transfer {
    to 1.2.3.4;        # secondary NS 1
    to 5.6.7.8;        # secondary NS 2
}
```

Then run `make deploy` to apply.

---

## Enabling Rate Limiting

dnsdist can drop clients that exceed a query rate threshold. Uncomment in `ansible/roles/dnsdist/templates/dnsdist.conf.j2`:

```lua
-- Drop source IPs sending more than 100 queries per second
addAction(MaxQPSIPRule(100), DropAction())
```

Then run `make deploy` to apply.

---

## CoreDNS Reload Behaviour

CoreDNS has two distinct reload mechanisms — it is important to use the right one:

| Change type | How to apply |
|-------------|-------------|
| Zone file records (SOA, NS) | `make deploy-zones` — copies files and sends **SIGHUP**; no downtime |
| Corefile changes (new zones, new/modified templates, plugin config) | `make deploy` — triggers a **container restart**; brief interruption |

SIGHUP causes CoreDNS to re-read zone files in place. It does **not** reinitialize network listeners or reload template configuration, so it cannot pick up changes to the Corefile. Container restarts handle those.

---

## Boot Persistence

All stacks are registered as systemd services that start automatically on boot:

```
# On dnsdist_servers:
dnsdist.service          — manages /opt/dnsdist/docker-compose.yml
promtail.service         — manages /opt/promtail/docker-compose.yml

# On coredns_servers:
coredns.service          — manages /opt/coredns/docker-compose.yml
promtail.service         — manages /opt/promtail/docker-compose.yml

# On monitoring_servers:
monitoring-stack.service — manages /opt/monitoring/docker-compose.yml
```

These depend on `docker.service`, so they start after Docker is ready. To check or control them manually:

```bash
# On dnsdist servers:
ssh root@YOUR_DNSDIST_SERVER systemctl status dnsdist
ssh root@YOUR_DNSDIST_SERVER systemctl status promtail
ssh root@YOUR_DNSDIST_SERVER systemctl restart dnsdist

# On CoreDNS servers:
ssh root@YOUR_COREDNS_SERVER systemctl status coredns
ssh root@YOUR_COREDNS_SERVER systemctl status promtail
ssh root@YOUR_COREDNS_SERVER systemctl restart coredns
```

---

## Security

**Change all default credentials before deploying to a real server.** The defaults in this repo are placeholders.

| Credential | File | Default |
|------------|------|---------|
| dnsdist web UI + Prometheus auth password | `ansible/inventory/group_vars/all.yml` | `changeme` |
| Grafana admin password | `ansible/roles/monitoring/files/docker-compose.yml` | `changeme` |

The dnsdist password is now defined in one place (`group_vars/all.yml`) and automatically used in both dnsdist.conf and prometheus.yml at deploy time. See [Changing dnsdist Credentials](#changing-dnsdist-credentials).

Default port exposure (all-in-one deployment):

| Surface | Exposure | Notes |
|---------|----------|-------|
| Port 53 UDP+TCP | Public (all IPs) | Authoritative queries only; no recursion |
| Port 3000 (Grafana) | Public | Password-protected; change default before exposing |
| Port 8083 (dnsdist web UI) | Localhost only | Access via SSH tunnel |
| Port 9090 (Prometheus) | Localhost only | No auth; access via SSH tunnel |
| Port 9153 (CoreDNS metrics) | Localhost only | No auth |
| Port 3100 (Loki) | Localhost only | No auth |
| Port 5300 (CoreDNS DNS) | Localhost only | Not exposed publicly; dnsdist frontend only |
| systemd-resolved | Disabled | Conflicts with port 53; static `/etc/resolv.conf` uses 1.1.1.1 / 8.8.8.8 |

> **Split deployments:** When DNS and monitoring servers are separate, ports 8083 and 9153 on the DNS servers must be reachable by the monitoring server (set `coredns_prometheus_address` and `dnsdist_webserver_address` to `0.0.0.0:PORT`). Port 3100 on the monitoring server must be reachable by DNS servers (set `loki_http_listen_address` to `0.0.0.0`). Restrict access with firewall rules — allow only the specific monitoring/DNS server IPs, not the whole internet.

SSH tunnel to access localhost-only UIs from your browser:
```bash
# Tunnel to a dnsdist server (for the web UI):
ssh -L 8083:127.0.0.1:8083 root@YOUR_DNSDIST_SERVER
# http://localhost:8083  → dnsdist web UI

# Tunnel to the monitoring server (for Prometheus):
ssh -L 9090:127.0.0.1:9090 root@YOUR_MON_SERVER
# http://localhost:9090  → Prometheus
```

---

## Monitoring

**Grafana** — `http://YOUR_SERVER_IP:3000` (admin login)

Two dashboards are provisioned automatically:

#### DNS Infrastructure Overview

Combined dnsdist + CoreDNS dashboard with high-level traffic health:

| Panel | Source | Shows |
|-------|--------|-------|
| Query rate, NXDOMAIN/SERVFAIL rate | dnsdist | Traffic health at a glance |
| Backend status and latency | dnsdist | CoreDNS health from dnsdist's view |
| Queries/s by zone | CoreDNS | Which zone is receiving traffic |
| Response codes by zone | CoreDNS | NXDOMAIN/SERVFAIL breakdown per zone |
| Latency p50/p95/p99 | CoreDNS | Real query latency distribution |
| UDP vs TCP split | CoreDNS | Protocol breakdown |
| Top queried names | Loki (logs) | Individual PTR names being looked up |
| Top client IPs | Loki (logs) | Who is querying the most (from CoreDNS logs) |
| Live query stream | Loki (logs) | Real-time CoreDNS query log |

#### dnsdist — Query Logs & Metrics

Dedicated dnsdist dashboard with **real client IPs** (CoreDNS always sees `127.0.0.1` since dnsdist is the proxy — real IPs come from dnsdist's own log stream):

| Panel | Source | Shows |
|-------|--------|-------|
| QPS, NXDOMAIN/SERVFAIL rates, latency, drops | Prometheus | Real-time frontend health |
| Backend status (UP/DOWN) | Prometheus | CoreDNS health check state |
| Queries/responses over time, response codes | Prometheus | Traffic trends |
| Latency (last 100 / last 1000), backend latency | Prometheus | End-to-end latency |
| ACL drops, rule drops, dynamic blocks, timeouts | Prometheus | Drop and error rates |
| Top real client IPs | Loki (dnsdist logs) | Actual DNS clients (not 127.0.0.1) |
| Top queried names | Loki (dnsdist logs) | Most-queried PTR names |
| Query type breakdown (pie) | Loki (dnsdist logs) | PTR vs SOA vs AXFR etc. |
| Per-server query volume and rate | Loki (dnsdist logs) | Traffic distribution across DNS servers |
| Live dnsdist query log | Loki (dnsdist logs) | Real-time dnsdist query stream |

### Log Labels (Loki / Promtail)

Promtail scrapes both the dnsdist and CoreDNS containers. Labels available in LogQL:

**dnsdist container** (`{container="dnsdist"}`):

| Label | Example values |
|-------|---------------|
| `container` | `dnsdist` |
| `host` | `coredns01` (Ansible inventory hostname) |
| `client_ip` | `1.2.3.4` — real DNS client IP |
| `qtype` | `PTR`, `SOA`, `A`, `AAAA` |
| `qname` | `1.2.0.192.in-addr.arpa.` |

**CoreDNS container** (`{container="coredns"}`):

| Label | Example values |
|-------|---------------|
| `container` | `coredns` |
| `host` | `coredns01` |
| `level` | `INFO`, `ERROR` |
| `client_ip` | `127.0.0.1` — always dnsdist's address |
| `qtype` | `PTR`, `SOA`, `AXFR` |
| `qname` | `1.2.0.192.in-addr.arpa.` |
| `proto` | `udp`, `tcp` |
| `rcode` | `NOERROR`, `NXDOMAIN`, `SERVFAIL` |

Example LogQL queries in Grafana Explore:
```logql
# Real client IPs from dnsdist (not 127.0.0.1)
topk(20, sum by (client_ip) (count_over_time({container="dnsdist", client_ip!=""}[1h])))

# All NXDOMAIN responses (from CoreDNS)
{container="coredns", rcode="NXDOMAIN"}

# Top queried names in last hour (from CoreDNS)
topk(20, sum by (qname) (count_over_time({container="coredns", qname!=""}[1h])))

# Live query stream from a specific client IP
{container="dnsdist", client_ip="1.2.3.4"}
```

### Grafana Password

`GF_SECURITY_ADMIN_PASSWORD` in `docker-compose.yml` **only applies on the very first startup** when the database does not yet exist. After that, the password lives in Grafana's SQLite database.

**If the Grafana database is wiped** (e.g. after `rm -rf /opt/monitoring/grafana/data/*`), Grafana reverts to the env var value on next start. Reset your password with:

```bash
docker exec grafana grafana cli admin reset-admin-password 'yourpassword'
```

**To change the password going forward:**
1. Change it in the Grafana UI (Profile → Change Password)
2. Update `GF_SECURITY_ADMIN_PASSWORD` in `ansible/roles/monitoring/files/docker-compose.yml` to match
3. Run `make deploy-monitoring` so the compose file is in sync on all servers

### Changing dnsdist Credentials

The dnsdist web UI password is defined in **one place** and automatically applied to both dnsdist and Prometheus:

```yaml
# ansible/inventory/group_vars/all.yml
dnsdist_webserver_password: "your-new-password"
```

After changing it, run `make deploy` to apply (or `make deploy-dns` + `make deploy-monitoring` separately).

---

## Backups

| Data | Location | Backed up by |
|------|----------|-------------|
| Zone files | `zones/` in this repo | Git |
| Ansible config | `ansible/` in this repo | Git |
| Prometheus TSDB | `/opt/monitoring/prometheus/data/` | Not automated — back up this directory |
| Loki log data | `/opt/monitoring/loki/data/` | Not automated — back up this directory |
| Grafana dashboards | `ansible/roles/monitoring/files/grafana/provisioning/` | Git (provisioned from repo) |
| Grafana database (users, alerts) | `/opt/monitoring/grafana/data/` | Not automated — back up `grafana.db` |

Zone files and dashboard definitions are the most important — both live in this repo. The Prometheus and Loki data directories hold historical metrics and logs; losing them means losing history but not configuration.

---

## On-Server File Layout

```
# On dnsdist_servers:
/opt/dnsdist/
├── docker-compose.yml       # dnsdist service
└── dnsdist.conf             # listens :53, web UI :8083, backends auto-generated from inventory

/opt/promtail/               # log shipper (also on coredns_servers)
├── docker-compose.yml
└── config.yml               # tails dnsdist container logs → Loki

# On coredns_servers:
/opt/coredns/
├── docker-compose.yml       # CoreDNS service
├── Corefile                 # listens :5300, metrics :9153, health :8080
└── zones/                   # Zone files (synced from repo by Ansible)

/opt/promtail/               # log shipper (also on dnsdist_servers)
├── docker-compose.yml
└── config.yml               # tails CoreDNS container logs → Loki

# On monitoring_servers:
/opt/monitoring/
├── docker-compose.yml       # Monitoring stack (Prometheus + Loki + Grafana)
├── prometheus/
│   ├── prometheus.yml       # Scrapes dnsdist_servers :8083 + coredns_servers :9153
│   └── data/                # TSDB (30-day retention)
├── loki/
│   ├── config.yml
│   └── data/                # Log store (30-day retention)
└── grafana/
    ├── data/                # SQLite DB, user data
    └── provisioning/        # Datasources and dashboards (managed by Ansible)
```

---

## Testing DNS

From any machine with `dig`:
```bash
# Reverse lookup (shorthand — dig computes the in-addr.arpa name)
dig -x 192.0.2.1 @YOUR_SERVER_IP
dig -x 2001:db8:f9:2::13:1 @YOUR_SERVER_IP

# Auto-generated PTR for an IP with no explicit record
dig -x 192.0.2.200 @YOUR_SERVER_IP

# SOA — the 'aa' flag in the response confirms this is authoritative
dig SOA 2.0.192.in-addr.arpa @YOUR_SERVER_IP
dig SOA 0.0.8.b.d.0.1.0.0.2.ip6.arpa @YOUR_SERVER_IP

# Test TCP specifically
dig +tcp SOA 2.0.192.in-addr.arpa @YOUR_SERVER_IP

# Test over IPv6 transport
dig SOA 2.0.192.in-addr.arpa @YOUR_SERVER_IPV6

# Full zone transfer
dig AXFR 2.0.192.in-addr.arpa @YOUR_SERVER_IP

# Bypass dnsdist and query CoreDNS directly (port 5300, from the server itself)
ssh root@YOUR_SERVER_IP dig SOA 2.0.192.in-addr.arpa @127.0.0.1 -p 5300
```

---

## Troubleshooting

**CoreDNS not loading a zone file:**
```bash
ssh root@YOUR_COREDNS_SERVER 'docker logs coredns --tail=50'
# Permission errors mean the zone file is not world-readable (must be mode 0644)
ssh root@YOUR_COREDNS_SERVER 'ls -la /opt/coredns/zones/'
# Force immediate reload (zone files only — use container restart for Corefile changes)
ssh root@YOUR_COREDNS_SERVER 'docker kill --signal=SIGHUP coredns'
```

**dnsdist marking CoreDNS as DOWN:**
```bash
# Verify CoreDNS is answering the health check query directly
ssh root@YOUR_COREDNS_SERVER 'dig SOA YOUR_ZONE @127.0.0.1 -p 5300'
# Check dnsdist's view of backend state
ssh root@YOUR_DNSDIST_SERVER 'curl -s -u "dnsdist:changeme" http://127.0.0.1:8083/api/v1/servers/localhost | python3 -m json.tool | grep -E "name|state|queries"'
```

**Grafana shows no data:**
```bash
# Are all Prometheus targets up? (run on monitoring server)
ssh root@YOUR_MON_SERVER 'curl -s http://127.0.0.1:9090/api/v1/targets | python3 -m json.tool | grep -E "job|health"'
# Can the metrics endpoints be reached from the monitoring server?
curl -s http://YOUR_COREDNS_SERVER_IP:9153/metrics | head -5
curl -s -u "dnsdist:changeme" http://YOUR_DNSDIST_SERVER_IP:8083/metrics | head -5
# Is Loki ready?
ssh root@YOUR_MON_SERVER 'curl -s http://127.0.0.1:3100/ready'
```

**Loki log panels empty (no top queried names):**

Promtail runs on each DNS server and pushes logs to Loki. Check that it found the containers:
```bash
# On a DNS server:
ssh root@YOUR_DNS_SERVER 'curl -s http://127.0.0.1:9080/metrics | grep "promtail_targets_active"'
ssh root@YOUR_DNS_SERVER 'docker logs promtail --tail=20'
ssh root@YOUR_DNS_SERVER 'systemctl status promtail'
# Check that Promtail can reach Loki:
ssh root@YOUR_DNS_SERVER 'curl -s http://YOUR_MON_SERVER_IP:3100/ready'
```
Note: the "Top Queried Names" table requires queries to have already been logged. The panel will be empty on a server with no real traffic yet.

**Grafana login fails with correct password:**

Likely a stale browser session cookie. Open an incognito window and try again, or clear cookies for the site. If the password itself is wrong, reset it:
```bash
ssh root@YOUR_MON_SERVER 'docker exec grafana grafana cli admin reset-admin-password newpassword'
```

**Container won't start:**
```bash
ssh root@YOUR_DNSDIST_SERVER 'docker logs <container-name> --tail=30'
ssh root@YOUR_DNSDIST_SERVER 'docker compose -f /opt/dnsdist/docker-compose.yml ps'
ssh root@YOUR_COREDNS_SERVER 'docker compose -f /opt/coredns/docker-compose.yml ps'
ssh root@YOUR_MON_SERVER 'docker compose -f /opt/monitoring/docker-compose.yml ps'
```

**Stack not starting after reboot:**
```bash
# On dnsdist servers:
ssh root@YOUR_DNSDIST_SERVER 'systemctl status dnsdist'
ssh root@YOUR_DNSDIST_SERVER 'systemctl status promtail'
ssh root@YOUR_DNSDIST_SERVER 'journalctl -u dnsdist --since "10 minutes ago"'
# On CoreDNS servers:
ssh root@YOUR_COREDNS_SERVER 'systemctl status coredns'
ssh root@YOUR_COREDNS_SERVER 'systemctl status promtail'
ssh root@YOUR_COREDNS_SERVER 'journalctl -u coredns --since "10 minutes ago"'
# On monitoring server:
ssh root@YOUR_MON_SERVER 'systemctl status monitoring-stack'
ssh root@YOUR_MON_SERVER 'journalctl -u monitoring-stack --since "10 minutes ago"'
```

---

## Attribution

This repository does not create any new DNS or monitoring software. It provides Ansible automation, configuration templates, and a Grafana dashboard to deploy and connect the following open-source projects:

| Software | Role in this stack | License | Project |
|----------|--------------------|---------|---------|
| [CoreDNS](https://coredns.io) | Authoritative DNS server — serves zone files and auto-generates PTR records | Apache 2.0 | https://coredns.io |
| [dnsdist](https://dnsdist.org) | DNS load balancer and public-facing frontend on port 53 | Apache 2.0 | https://dnsdist.org |
| [Prometheus](https://prometheus.io) | Metrics collection, storage, and alerting | Apache 2.0 | https://prometheus.io |
| [Grafana Loki](https://grafana.com/oss/loki/) | Log aggregation and storage | Apache 2.0 | https://grafana.com/oss/loki/ |
| [Grafana Promtail](https://grafana.com/docs/loki/latest/send-data/promtail/) | Log shipping agent (tails CoreDNS container logs) | Apache 2.0 | https://grafana.com/oss/loki/ |
| [Grafana](https://grafana.com/grafana/) | Dashboard and visualization UI | AGPL 3.0 | https://grafana.com/grafana/ |
| [Docker](https://www.docker.com) | Container runtime for all services | Apache 2.0 | https://www.docker.com |
| [Ansible](https://www.ansible.com) | Automation and configuration management | GPL 3.0 | https://www.ansible.com |

The Ansible playbooks, Jinja2 configuration templates, shell scripts, zone file examples, and Grafana dashboard JSON in this repository are original work, released under the MIT License.

---

## License

MIT — see [LICENSE](LICENSE).
