global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    site: ${NODE_SITE}
    node: ${NODE_NAME}

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  # ---------------------------------------------------------------------------
  # Lokale Targets (eigener Container-DNS)
  # ---------------------------------------------------------------------------
  - job_name: local
    static_configs:
      - targets:
          - 'node-exporter:9100'
          - 'postgres-exporter:9187'
          - 'pdns-exporter:9120'
          - 'patroni:8008'
          - 'etcd:2379'
        labels:
          node: ${NODE_NAME}

  # ---------------------------------------------------------------------------
  # Remote Targets (andere Nodes via WG-IP) - dynamisch per file_sd
  # ---------------------------------------------------------------------------
  - job_name: remote
    file_sd_configs:
      - files:
          - /etc/prometheus/targets.json
