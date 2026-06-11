# DNS Cluster (PowerDNS + Patroni + etcd) — Universal Stack

PowerDNS + PostgreSQL (Patroni) + etcd, quorum-based across multiple nodes.
This repository is **identical for all nodes**.

**Key design points:**

- Docker runs **system-wide** (not rootless).
- WireGuard runs **on the host** (systemd `wg-quick@wg0`), not inside a container.
- WireGuard peers use **FQDN endpoints**; on IP changes, endpoints are re-resolved automatically via a timer.
- Web UIs are exposed **only behind Caddy/HTTPS** (ports 80/443), not directly on 3000/9191.



### THIS PROJECT IS PROVIDED AS-IS.  
WE DO NOT GIVE ANY SUPPORT ON CUSTOM SETUPS.  
USE AT YOUR OWN RISK.

**Platform:** only tested on **Debian 12**. Other distributions (including Debian 13
or Ubuntu) may work but are unsupported.

## Architecture

```
                     public internet
                              │
                       :53 udp/tcp (PowerDNS)
                       :80/:443 (Caddy HTTPS)
                       :8081 (PowerDNS API)
                              │
              ┌───────────────▼───────────────┐
              │  Docker (system-wide)         │
              │  user dockeruseragent         │
              │                               │
              │  PowerDNS ─► pgbouncer ─►     │
              │              HAProxy          │
              │              ↓ /primary       │
              │              │                │
              │  Patroni ────┘   etcd         │
              │                               │
              │  Caddy ─► Grafana / PDA / UI  │
              └──────┬─────────────┬──────────┘
                     │             │
              ┌──────▼─────────────▼──────────┐
              │  Host (root)                  │
              │   wg-quick@wg0   -> 10.100.0.X│
              │   wg-reresolve.timer (5 min)  │
              └──────┬────────────────────────┘
                     │
            ┌────────┴────────┐
            │ WireGuard-Mesh  │
            │ 10.100.0.0/24   │
            │ Endpoints=FQDN  │
            └─────────────────┘
```

**Failover policy (Patroni tags):**

- Controlled per node via `.env` (`PATRONI_FAILOVER_PRIORITY_<NODE>`, `PATRONI_NOFAILOVER_<NODE>`).
- Defaults: `nofailover=false`, `failover_priority=50` (if not set).

## Our authoritative DNS servers (as209800.net)

If you want to run your domain on our nameservers:

- `ns1.cluster.as209800.net`
- `ns2.cluster.as209800.net`
- `ns3.cluster.as209800.net`
- `ns4.cluster.as209800.net`

At least **3 nameservers** are recommended.

Management is available via `https://elizon.app`.

## Initial setup (for each node)

### Prerequisites

Prepare DNS records (A and/or AAAA, depending on each node's WireGuard address-family preference):

At least **3 nameservers/nodes** are recommended for a resilient setup.

Why not 2? The control plane (etcd/Patroni) is quorum-based: with 2 nodes you cannot lose one node and still keep a majority (it becomes 1/2, no quorum), and network partitions risk split-brain scenarios. With 3 nodes you can tolerate one node being down and still have quorum (2/3).

**Per node — mesh endpoints (for WireGuard):**

- `ns1.<your-cluster-domain>` → public IP of ns1
- `ns2.<your-cluster-domain>` → public IP of ns2
- `ns3.<your-cluster-domain>` → public IP of ns3
- `ns4.<your-cluster-domain>` → public IP of ns4

**Per node — web UIs (for Caddy / Let's Encrypt):**

- `grafana.ns1.<your-cluster-domain>` → public IP of ns1
- `pdns-admin.ns1.<your-cluster-domain>` → public IP of ns1
- `ns1.<your-cluster-domain>` → public IP of ns1 (PowerDNS authoritative Web/API via HTTPS)
- (repeat accordingly for ns2, ns3, ns4)

(The domain is configurable via `NODE_FQDN_DOMAIN` in `.env.example`.)

> **Tip:** wildcard CNAMEs are fine:
> `*.ns1.<your-cluster-domain>` CNAME `ns1.<your-cluster-domain>`
> then the three mesh records are enough and all subdomains point there automatically.

You need at least 2 vCores and 4GB DDR4 RAM per Node.
4 vCores and 6GB DDR4 RAM are recommended.
You will need at least 25GB of storage.

### Step 1 — bring the stack to the host, run the installer

#### Option A (recommended): first-use installer (cluster-wide + per host)

Upload and decompress the project.

**1) Once (on any machine with the repo, without root):**

```bash
cd dnscluster
./scripts/first-use.sh init \
  --domain example.net \
  --nodes ns1,ns2,ns3,ns4 \
  --acme-email admin@example.com \
  --generate-secrets
```

**2) Per host (as root on each node):**

```bash
sudo ./scripts/first-use.sh apply --node ns1
sudo ./scripts/first-use.sh apply --node ns2 --with-firewall
sudo ./scripts/first-use.sh apply --node ns3
sudo ./scripts/first-use.sh apply --node ns4
```

The installer reads `CLUSTER_NODES` from `.env` and checks that `--node` is included.

Optional flags (same semantics as `install.sh`):

- `--with-firewall`: configure UFW with the required ports
- `--skip-docker`: skip Docker installation (if already installed)

During `apply`, `install.sh` also configures **systemd-resolved** when
`/etc/systemd/resolved.conf` exists and contains a `[Resolve]` section (see
[systemd-resolved / DNS stub](#systemd-resolved--disable-local-dns-stub) below).

#### `.env`: two locations — what `init` writes vs. what the host uses

`first-use init` patches `.env` in the **repo directory where you run it**
(e.g. `/tmp/dnscluster` or `~/dnscluster-1.0`). That file holds cluster-wide
settings such as `CLUSTER_NODES`, `NODE_FQDN_DOMAIN`, WireGuard IPs, and secrets.

`first-use apply` (via `install.sh`) provisions the host under
`/home/dockeruseragent/dnscluster/`. **All runtime scripts use that path**, including:

- `wireguard-render.sh` → `/etc/wireguard/wg0.conf`
- `node-init.sh`, `docker compose`, `cluster-sync.sh`, …

**Important:** on reinstall/update, `install.sh` copies the stack with `rsync` but
**explicitly excludes** `.env` and `wireguard/keys/` so existing secrets and keys on
the host are preserved. `apply` only reads the source `.env` to check that `--node` is
listed in `CLUSTER_NODES` — it does **not** copy the init `.env` to the target.

| Situation | Which `.env` is active on the host |
|-----------|-------------------------------------|
| First install, target dir did not exist yet (`cp -a`) | Source `.env` is copied along with the stack |
| Reinstall / update, target dir already exists (`rsync --exclude .env`) | **Existing** `/home/dockeruseragent/dnscluster/.env` is kept |
| Target had no `.env` | `.env.example` is copied as a fallback |

So a successful `init` in your upload directory does **not** automatically fix a stale
or wrong `.env` already sitting on the host. Typical symptom: `CLUSTER_NODES=ns1` on the
host while the repo `.env` still has `ns1,ns2,ns3,ns4` — WireGuard then renders **no
peers** (only the local node is listed), `wg show wg0` shows no `[Peer]` entries, and
pings to other mesh IPs fail with `Required key not available`.

**Verify on each node (compare both paths if you still have the upload tree):**

```bash
grep '^CLUSTER_NODES=' /home/dockeruseragent/dnscluster/.env
# optional, if you ran init elsewhere:
grep '^CLUSTER_NODES=' /path/to/your/upload/dnscluster/.env
```

Expected on every node (identical cluster-wide value):

```bash
CLUSTER_NODES=ns1,ns2,ns3,ns4
```

**Fix — copy cluster-wide settings to the live stack** (pick one):

```bash
# A) Full .env from init (passwords/secrets must already match across nodes)
sudo cp /path/to/upload/dnscluster/.env /home/dockeruseragent/dnscluster/.env
sudo chown dockeruseragent:dockeruseragent /home/dockeruseragent/dnscluster/.env

# B) Patch only the node list
sudo sed -i 's/^CLUSTER_NODES=.*/CLUSTER_NODES=ns1,ns2,ns3,ns4/' \
  /home/dockeruseragent/dnscluster/.env
```

Then refresh node identity and WireGuard on that host:

```bash
cd /home/dockeruseragent/dnscluster
sudo -iu dockeruseragent ./scripts/node-init.sh ns1   # or ns2, ns3, ns4
sudo rm -f /etc/wireguard/wg0.conf                    # force re-render if peers were empty
sudo ./scripts/wireguard-render.sh
sudo systemctl restart wg-quick@wg0
sudo wg show wg0
```

> **Tip:** run `init` once, then distribute the resulting `.env` to every node
> (same secrets, same `CLUSTER_NODES`) **before** `apply`, or copy it to
> `/home/dockeruseragent/dnscluster/.env` immediately after the first `apply` if the
> target directory already existed from a previous attempt.

#### systemd-resolved — disable local DNS stub

WireGuard peer endpoints are **FQDNs** (`ns2.<domain>:51820`). `wg-quick` and
`wg-reresolve.sh` resolve them via the host resolver. On Debian/Ubuntu with
**systemd-resolved**, the default stub listener on `127.0.0.53` can return
inconsistent or locally overridden answers (e.g. a node's own hostname from
`/etc/hosts` as `127.0.1.1`, or different upstream results per host). That leads
to wrong WireGuard endpoints and missing handshakes.

`first-use apply` / `install.sh` therefore patches `/etc/systemd/resolved.conf`
(idempotent) when the file exists and has a `[Resolve]` section:

1. If `DNSStubListener=no` is already set → no change
2. If `#DNSStubListener=…` or `DNSStubListener=…` exists → replace with
   `DNSStubListener=no`
3. Otherwise → append `DNSStubListener=no` at the end of the file
4. Restart `systemd-resolved` when the unit is enabled

**After this change**, ensure `/etc/resolv.conf` does **not** still point at the
disabled stub. It should use the uplink file:

```bash
readlink -f /etc/resolv.conf
# expected: /run/systemd/resolve/resolv.conf
# not:      /run/systemd/resolve/stub-resolv.conf

# if needed:
sudo ln -sfn /run/systemd/resolve/resolv.conf /etc/resolv.conf
```

**Verify mesh DNS is consistent on every node** (same public answer everywhere):

```bash
DOMAIN=example.net   # your NODE_FQDN_DOMAIN
for n in ns1 ns2 ns3 ns4; do
  printf "%s A:    " "$n"; dig +short "${n}.${DOMAIN}" A
  printf "%s AAAA: " "$n"; dig +short "${n}.${DOMAIN}" AAAA
done
```

If nodes disagree on a peer's IP, fix the **authoritative DNS zone** first, then:

```bash
sudo /usr/local/sbin/wg-reresolve.sh
sudo wg show wg0
```

**Already deployed hosts** (without re-running the full installer):

```bash
sudo ./scripts/first-use.sh apply --node ns1
# or: sudo ./scripts/install.sh --node ns1
```

Or manually edit `/etc/systemd/resolved.conf`, restart `systemd-resolved`, and fix
`/etc/resolv.conf` as above.

#### Option B (manual): run `install.sh` directly

On each node:

Upload and decompress the project.

```bash
cd /tmp/dnscluster
sudo ./scripts/install.sh --node ns1
sudo ./scripts/install.sh --node ns2
sudo ./scripts/install.sh --node ns3 --with-firewall
sudo ./scripts/install.sh --node ns4
```

`install.sh` does the full host provisioning (same `.env` behaviour as `apply` — see
[`.env`: two locations](#env-two-locations--what-init-writes-vs-what-the-host-uses)):

- packages + system-wide Docker
- Service user `dockeruseragent` (stack ends up in
`/home/dockeruseragent/dnscluster/`)
- `systemd-resolved`: `DNSStubListener=no` in `/etc/systemd/resolved.conf` when
`[Resolve]` exists (see [systemd-resolved](#systemd-resolved--disable-local-dns-stub))
- SSH sync user `ns-cluster-sync` (for inter-node operations)
- runs `node-init.sh` → `.env` gets node-specific computed values
- runs `wireguard-render.sh` → builds `/etc/wireguard/wg0.conf`
- enables systemd timer `wg-reresolve.timer` (DNS re-resolve every 5 minutes)
- enables `wg-quick@wg0` (can only come up cleanly once all peer keys are distributed)

At the end, the installer prints this node's **SSH sync public key** — you will need it next.

### Step 2 — authorize SSH sync keys

On EACH node, add the other nodes' sync public keys to
`/home/ns-cluster-sync/.ssh/authorized_keys`:

```bash
sudo nano /home/ns-cluster-sync/.ssh/authorized_keys
# One line per peer (optionally with 'restrict'):
restrict ssh-ed25519 AAAA... cluster-sync@nsX
```

Note: this repo currently does **not** use a forced-command script; `cluster-sync.sh`
executes remote commands directly via SSH (with the `sudo` whitelist created by `install.sh`).
This is not recommended and untested.

Please exchange the keys of each ns-cluster-sync user on each node.
You will find the ns-cluster-sync user public key in the .ssh folder of the dockeruseragent user.

### Step 3 — distribute WireGuard public keys

Prerequisite: `CLUSTER_NODES` in `/home/dockeruseragent/dnscluster/.env` must list
**all** mesh nodes (not only the local node name). See
[`.env`: two locations](#env-two-locations--what-init-writes-vs-what-the-host-uses)
if `wireguard-render.sh` produces an empty peer section.

First time manually (SSH sync only works once everything is set up):

On ns1:

```bash
cat /home/dockeruseragent/dnscluster/wireguard/keys/publickey
# -> copy this value to ns2, ns3, and ns4 as
#    /home/dockeruseragent/dnscluster/wireguard/keys/publickey.ns1
#    then on each of those nodes:
sudo /home/dockeruseragent/dnscluster/scripts/wireguard-render.sh
```

Repeat for ns2, ns3 and ns4.

Once all peer keys are present on all nodes:

```bash
sudo systemctl restart wg-quick@wg0
sudo wg show wg0          # all peers should show a recent handshake
ping -c 2 10.100.0.2      # from ns1 to ns2
```

**Tip (more convenient once SSH sync keys are authorized):**
On each node, as `dockeruseragent`, run once:

```bash
cd ~/dnscluster
./scripts/cluster-sync.sh distribute-pubkey
```

This pushes your WG public key to all peers and triggers `wireguard-render.sh` on them.

### Step 4 — start the stack (on each node)

```bash
sudo -iu dockeruseragent
cd ~/dnscluster
nano .env                          # set passwords!
                                   # identical on all nodes
./scripts/bootstrap.sh             # pgbouncer hashes
docker compose build patroni
docker compose up -d
docker compose ps
```

### Step 5 — initialize databases (ONCE, on the current leader only)

```bash
sudo -iu dockeruseragent
cd ~/dnscluster
sed -i "s/CHANGE_ME_pdns/$(grep '^PDNS_DB_PASSWORD=' .env | cut -d= -f2)/" \
    scripts/init-databases.sql

# Patroni must be healthy (otherwise: connection refused).
docker compose exec -T patroni psql -U postgres -h 127.0.0.1 -f - < scripts/init-databases.sql

# If PowerDNS-Admin shows "password authentication failed for user pdns": run on the **leader**
# (Patroni primary) — not on a replica:
bash scripts/sync-pdns-postgres-password.sh
```

### Step 6 — smoke tests

```bash
curl -s http://10.100.0.1:8008/cluster | jq
dig @10.100.0.1 example.com

# Web UIs (Caddy fetches the LE cert on first access):
firefox https://pdns-admin.ns1.example.net
firefox https://grafana.ns1.example.net    # admin / <GRAFANA_ADMIN_PASSWORD>
firefox https://ns1.example.net            # PowerDNS Web/API (HTTPS via Caddy)

# Check certificate status:
docker compose logs caddy | grep -E "obtained|certificate"
```

> **First certificate issuance:** Caddy needs ~30s. If something goes wrong (e.g. DNS
> doesn't resolve, port 80 isn't reachable), `docker compose logs caddy` shows the ACME errors.
> To test without risking Let's Encrypt rate limits, set in `.env`:
> `LE_ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory`
> then run `docker compose up -d caddy` again.

## IP change workflow

**Example: a node gets a new IPv4.**

Because WireGuard uses FQDN endpoints, the change can be handled with minimal effort:

### Option A — planned change (with DNS lead time)

```bash
# 1. (before the change) reduce DNS TTL for ns1.<your-cluster-domain> to 60s
# 2. (change day) once the new IP is active, update A/AAAA
# 3. wg-reresolve will pick up the new IP within max. 5 minutes
#    -> tunnel endpoint is updated via 'wg set ... endpoint ...' (no drop)
# 4. Optional: push immediately instead of waiting up to 5 minutes:
sudo -iu dockeruseragent
cd ~/dnscluster
./scripts/cluster-sync.sh reresolve all
```

### Option B — manual override (DNS not updated yet)

```bash
# On any node:
sudo -iu dockeruseragent
cd ~/dnscluster

# Updates .env on all nodes (informational; WG uses FQDNs!)
./scripts/cluster-sync.sh update-public-ip ns1 v4 198.51.100.42

# If DNS isn't updated yet, you can force WireGuard directly:
sudo wg set wg0 peer <ns1-pubkey> endpoint 198.51.100.42:51820
# The next reresolve run will overwrite this with the DNS value again.
```

### Option C — emergency (public IP disappears)

The WireGuard tunnel will stay idle until DNS resolves again. Once the new IP
is present in DNS, the cluster should recover within the next 5-minute reresolve run.

## Useful commands

```bash
# Cluster status (overview across all nodes)
sudo -iu dockeruseragent
cd ~/dnscluster
./scripts/cluster-sync.sh status

# Manual WG re-resolve on all nodes
./scripts/cluster-sync.sh reresolve all

# Test failover (on a node):
docker compose stop patroni
# verify on another node:
curl -s http://10.100.0.2:8008/cluster | jq '.members[] | {name, role}'

# Switch back to ns1 (example):
curl -u patroni:<PATRONI_REST_PASSWORD> -X POST \
     -H "Content-Type: application/json" \
     -d '{"leader":"ns2","candidate":"ns1"}' \
     http://10.100.0.2:8008/switchover
```

## Known pitfalls

- **`.env` not propagated by `apply`:** `first-use init` updates the repo `.env`, but
`install.sh` keeps an existing `/home/dockeruseragent/dnscluster/.env` on reinstall.
Always check `CLUSTER_NODES` on the **host path** after `apply`, not only in your upload
directory.
- **`CLUSTER_NODES` too narrow:** if only the local node is listed (e.g. `CLUSTER_NODES=ns1`),
`wireguard-render.sh` skips all remote peers. `apply --node ns1` still succeeds silently.
Symptoms: empty `# >>> PEER_BLOCKS_BEGIN >>>` section in `/etc/wireguard/wg0.conf`, no peers in
`wg show wg0`, ping errors `Required key not available`.
- **systemd-resolved stub / inconsistent mesh DNS:** with the default `127.0.0.53` stub,
`dig ns3.<domain>` can return different IPs on different nodes, or `127.0.1.1` for the local
hostname. WireGuard then targets the wrong endpoint (`wg show wg0` → peer without
`latest handshake`). `apply`/`install.sh` sets `DNSStubListener=no`; also check
`/etc/resolv.conf` points to `/run/systemd/resolve/resolv.conf` and that authoritative
DNS records for all `nsX.<domain>` names are correct and identical worldwide.
- **etcd quorum:** if too many nodes are down, Patroni will refuse writes — by design.
- **PgBouncer transaction pooling:** no prepared statements / sessions across transactions.
For `psql`, connect directly via HAProxy on `127.0.0.1:5000`/`5001`.
- **PowerDNS-Admin first login:** the first registered user becomes admin.
- **PowerDNS default SOA:** `powerdns/pdns.conf` contains a static `default-soa-content` example value.
If you rely on it, change it to match your domain (many setups set SOA per zone instead).
- **WireGuard MTU:** if your provider MTU < 1500, set `MTU = 1280` in
`wireguard/wg0.conf.tpl`, then run `wireguard-render.sh`.
- **Reresolve timer:** every 5 minutes by default. For critical changes,
trigger upfront via `cluster-sync.sh reresolve all`.
- **Let's Encrypt rate limits:** the production endpoint limits certificate issuance.
While experimenting, set `LE_ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory`
in `.env`.
- **Caddy requires port 80 reachable from the internet** (HTTP-01 challenge).
If renewals fail later, it's usually the firewall.
- **IP changes and Caddy:** when the public IP changes, you must also update DNS
records for `grafana.nsX...` and `pdns-admin.nsX...`.
WireGuard updates automatically via mesh FQDNs, but the web UI FQDNs are separate.
Tip: a wildcard CNAME (see above) solves this in one go.

## File overview

```
.
├── .env.example                   # universal template
├── docker-compose.yml             # universal, values from .env
├── patroni/patroni.yml.tpl        # universal
├── prometheus/prometheus.yml.tpl  # universal, rendered at container start
├── caddy/Caddyfile                # HTTPS reverse proxy + automatic Let's Encrypt
├── powerdns/pdns.conf
├── powerdns-admin/config.py
├── haproxy/haproxy.cfg
├── pgbouncer/pgbouncer.ini
├── wireguard/wg0.conf.tpl         # rendered to /etc/wireguard/wg0.conf
└── scripts/
    ├── install.sh                 # host installer (--node <node>)
    ├── node-init.sh               # updates .env with computed node values
    ├── bootstrap.sh               # pgbouncer userlist
    ├── wireguard-render.sh        # renders /etc/wireguard/wg0.conf
    ├── wg-reresolve.sh            # triggered by systemd timer
    ├── cluster-sync.sh            # inter-node operations via SSH
    ├── init-databases.sql         # run once on the leader
    └── systemd/
        ├── wg-reresolve.service
        └── wg-reresolve.timer
```

## Adding more nodes (ns5, ns6, …)

Current status: the stack is extensible via `CLUSTER_NODES` + `NODE_<NODE>_*`:

- Scripts iterate over `CLUSTER_NODES` (WireGuard, sync, reresolve, reinit).
- HAProxy and Prometheus are rendered at runtime from `.env` (no fixed `ns1..ns4` blocks).

If you really want to expand beyond 4 nodes, there are two clean approaches:

### Option A — keep a 4-node quorum, add extra DNS edge slaves outside

If your goal is more anycast sites / more DNS edge nodes, this is usually the best option:

- Patroni/etcd stays at 4 nodes (stable quorum, less complexity).
- Additional PowerDNS instances run as *separate* slaves and transfer zones via AXFR/NOTIFY.

Note: this repo is prepared for this (AXFR is enabled; `allow-axfr-ips` is currently limited to `10.100.0.0/24,127.0.0.1`). For external slaves you must expand `allow-axfr-ips` and optionally set `also-notify`.

### Option B — expand the core cluster: add ns5 to the stack (requires etcd/Patroni ops)

This is doable, but it's not just a Docker Compose step: you must expand topology + etcd/Patroni cleanly.

**1) Extend topology/variables (cluster-wide identical)**
Add to `.env`:

```bash
CLUSTER_NODES=ns1,ns2,ns3,ns4,ns5
NODE_NS5_WG_IP=10.100.0.5
NODE_NS5_WG_AF=auto
NODE_NS5_SITE=<label-optional>
PATRONI_FAILOVER_PRIORITY_NS5=<number>
PATRONI_NOFAILOVER_NS5=false
```

Then, on each existing node:

```bash
./scripts/node-init.sh <your-node>
sudo ./scripts/wireguard-render.sh
sudo /usr/local/sbin/wg-reresolve.sh
```

**2) WireGuard & SSH sync**

- Create DNS for `ns5.<domain>` (A/AAAA) and optionally `grafana.ns5...`/`pdns-admin.ns5...`
- Provision ns5 as usual:
  - `./scripts/first-use.sh init` must have run already (or `.env` is already present in the repo)
  - `sudo ./scripts/first-use.sh apply --node ns5`
- Then distribute WG public keys (as above, ideally via `cluster-sync.sh distribute-pubkey`).

**3) Extend the etcd cluster**
This repo uses `ETCD_INITIAL_CLUSTER` for bootstrap. A running etcd cluster is typically extended via `etcdctl member add`.

Example (from an existing member with access to etcd):

```bash
docker compose exec -T etcd etcdctl member list
docker compose exec -T etcd etcdctl member add ns5 --peer-urls=http://10.100.0.5:2380
```

Afterwards, the effective etcd cluster parameters must be consistent across nodes (member list vs. `ETCD_INITIAL_CLUSTER`). Plan a short maintenance window, because partially applied configs can lead to timeouts.

**4) Add the Patroni replica**
Once etcd is stable, Patroni can add the new member as a replica. Depending on the data state, a reinit may be appropriate (see `scripts/patroni-reinit-replica.sh`).

**5) Monitoring/Grafana**

- Prometheus targets are generated automatically from `CLUSTER_NODES`.
- Grafana dashboards are generic; the important part is that Prometheus scrapes the new targets.

Note: the node list is already dynamic (`CLUSTER_NODES`), so expansion is not a refactor anymore, but an operations/migration step (WireGuard keys + etcd member + Patroni).
