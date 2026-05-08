# =============================================================================
# Patroni config - universal (values from .env)
# =============================================================================
scope: ${CLUSTER_NAME}
namespace: /service/
name: ${NODE_NAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${NODE_WG_IP}:8008
  authentication:
    username: patroni
    password: ${PATRONI_REST_PASSWORD}

etcd3:
  hosts:
    # Only the co-located etcd inside the Compose network. Do not include WG IPs here:
    # from the bridge network, NODE_WG_IP:2379 is often unreachable (timeout), and
    # remote etcd is unnecessary for the DCS client — etcd replicates internally;
    # each host should talk to its local member.
    - etcd:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    # Synchronous mode off: across long distances it becomes too slow.
    # If needed later, enable via synchronous_node_count.
    synchronous_mode: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_connections: 200
        max_worker_processes: 8
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 1024MB
        wal_log_hints: "on"
        archive_mode: "on"
        archive_command: "/bin/true"        # no WAL archive; use S3/restic if needed
        shared_buffers: 512MB
        effective_cache_size: 1536MB
        work_mem: 16MB
        maintenance_work_mem: 128MB
        random_page_cost: 1.1               # SSD
        # Logging
        log_min_duration_statement: 500
        log_checkpoints: "on"
        log_connections: "off"
        log_lock_waits: "on"

  initdb:
    - encoding: UTF8
    - data-checksums
    - locale: en_US.UTF-8

  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 trust
    - host all all ${WG_SUBNET} md5
    # Patroni also uses local replication connections (localhost) to read timeline/LSN.
    - host replication replicator 127.0.0.1/32 trust
    - host replication replicator ${WG_SUBNET} md5
    # Compose network \"cluster\" (must match docker-compose networks.cluster.ipam):
    # HAProxy/PgBouncer reach Postgres from 172.28.x source IPs, not via WireGuard.
    - host all all ${CLUSTER_BRIDGE_SUBNET} md5

  users:
    admin:
      password: ${POSTGRES_SUPERUSER_PASSWORD}
      options:
        - createrole
        - createdb

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${NODE_WG_IP}:5432
  data_dir: /var/lib/postgresql/data/pgdata
  bin_dir: /usr/lib/postgresql/16/bin
  pgpass: /tmp/pgpass0
  # Runtime pg_hba (Patroni rewrites pg_hba.conf); includes bridge for the Docker stack
  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 trust
    - host all all ${WG_SUBNET} md5
    - host replication replicator 127.0.0.1/32 trust
    - host replication replicator ${WG_SUBNET} md5
    - host all all ${CLUSTER_BRIDGE_SUBNET} md5
  authentication:
    superuser:
      username: postgres
      password: ${POSTGRES_SUPERUSER_PASSWORD}
    replication:
      username: replicator
      password: ${POSTGRES_REPLICATION_PASSWORD}
    rewind:
      username: rewind_user
      password: ${POSTGRES_REWIND_PASSWORD}
  parameters:
    unix_socket_directories: '/var/run/postgresql'

# Failover policy is controlled via .env (PATRONI_NOFAILOVER, PATRONI_FAILOVER_PRIORITY)
tags:
  nofailover: ${PATRONI_NOFAILOVER}
  noloadbalance: false
  clonefrom: false
  failover_priority: ${PATRONI_FAILOVER_PRIORITY}

log:
  level: INFO
  format: '%(asctime)s %(levelname)s: %(message)s'
