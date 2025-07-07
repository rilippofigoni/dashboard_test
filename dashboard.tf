locals {
  dashboard = {
    enabled = ! module.env.env_is_dev ? true : var.dev_environment.enable_dashboard
  }
  analytics_postgresqlha_enabled = local.dashboard.enabled && true // TODO: remove once migrated to MongoDB

  grafana = {
    // Using this variable will ensure that the Grafana host is up:
    host = local.dashboard.enabled ? rancher2_app.grafana[0].answers["ingress.hosts[0]"] : ""
  }
  grafana_use_aqt_smtp = module.env.env_is_prod || module.env.env_is_staging

  grafana_plugin_path                       = "/var/lib/grafana/plugins"
  grafana_mongodb_plugin_version            = "4cefb885162ba574c21e4959a18877bdaf1a1add"
  grafana_mongodb_plugin_url                = "https://codeload.github.com/JamesOsgood/mongodb-grafana/zip/${local.grafana_mongodb_plugin_version} -O mongodb-grafana.zip"
  grafana_mongodb_plugin_dirname            = "mongodb-grafana"
  grafana_mongodb_plugin_download_and_unzip = "wget ${local.grafana_mongodb_plugin_url} -O mongodb-grafana.zip && unzip -o mongodb-grafana.zip && rm mongodb-grafana.zip && rm -rf ${local.grafana_mongodb_plugin_dirname} && mv mongodb-grafana-${local.grafana_mongodb_plugin_version} ${local.grafana_mongodb_plugin_dirname}"

  // Internal use only:
  grafana_host_no_dependencies = "${module.global_consts.prod_grafana_subdomain}${module.env.env_is_staging ? "-staging" : ""}.${local.env_specific_domain}"
  // Note: Empty newline is intentional as it would otherwise mess up formatting where its inserted
  grafana_tls = <<EOT

    - secretName: grafana-letsencrypt-tls
      hosts:
        - ${local.grafana_host_no_dependencies}
EOT
}

resource "rancher2_project" "dashboard" {
  count            = local.dashboard.enabled ? 1 : 0
  name             = local.dashboard_env_specific_project_name
  cluster_id       = local.rancher_cluster_id
  wait_for_cluster = true
}

resource "rancher2_namespace" "dashboard" {
  count      = local.dashboard.enabled ? 1 : 0
  name       = local.dashboard_env_specific_namespace
  project_id = rancher2_project.dashboard[0].id
}

resource "rancher2_secret" "grafana_admin" {
  count       = local.dashboard.enabled ? 1 : 0
  name        = "grafana-admin"
  description = "Grafana Admin Credentials"
  project_id  = rancher2_project.dashboard[0].id
  data = {
    admin-user     = base64encode(module.secrets.secret["grafana_admin_username"])
    admin-password = base64encode(module.secrets.secret["grafana_admin_password"])
  }
}

resource "rancher2_secret" "grafana_smtp" {
  count       = local.dashboard.enabled ? 1 : 0
  name        = "grafana-smtp"
  description = "Grafana SMTP Credentials"
  project_id  = rancher2_project.dashboard[0].id
  data = {
    user     = base64encode(local.grafana_use_aqt_smtp ? module.secrets.secret["grafana_smtp_username"] : "")
    password = base64encode(local.grafana_use_aqt_smtp ? module.secrets.secret["grafana_smtp_password"] : "")
  }
}

module "grafana_persistent_volume_claim" {
  volume_count = local.dashboard.enabled ? 1 : 0
  source       = "../../modules/persistent-volume-claim"

  name                    = "grafana"
  name_force_count_suffix = false
  disk_name_suffix        = module.env.env_suffix_nonprod
  namespace               = local.dashboard.enabled ? rancher2_namespace.dashboard[0].name : ""
  size_gb                 = 10
  is_on_google_cloud      = module.env.env_is_on_google_cloud
  google_zone             = module.global_consts.google_zone
  do_backups              = module.env.env_is_prod
  backup_schedule         = module.global_consts.daily_disk_backup_schedule_name
}

// The purpose of this random_id is to visualize any config changes during terraform plan/apply
resource "random_id" "grafana_values_yaml" {
  count = local.dashboard.enabled ? 1 : 0
  keepers = {

    values_yaml = chomp(<<EOT
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: PostgreSQL
      type: postgres
      url: ${local.analytics_pgpool_host}
      database: ${module.global_consts.aqt_simulator_db_name}
      user: ${module.secrets.secret["postgres_username"]}
      secureJsonData:
        password: ${module.secrets.secret["postgres_password"]}
      jsonData:
        sslmode: "disable"
      isDefault: false
    - name: Prometheus-Rancher
      type: prometheus
      access: proxy
      url: http://rancher-monitoring-prometheus.cattle-monitoring-system.svc.cluster.local:9090
    - name: MongoDB
      type: grafana-mongodb-datasource
      access: proxy
      url: http://localhost:3333
      jsonData:
        mongodb_url: "${local.aqt_simulator_mongodb_url}"
        mongodb_db: ${module.global_consts.aqt_simulator_db_name}
      isDefault: false

deploymentStrategy:
  # Need to use recreate strategy as otherwise persistent volume bind doesn't succeed
  type: Recreate

ingress:
  enabled: true
  annotations:
    kubernetes.io/ingress.class: ${local.nginx_ingress_controller_class}
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/whitelist-source-range: ${module.secrets.secret["aqt_sites_ip_address_cidrs"]}
    cert-manager.io/cluster-issuer: "${local.cert_manager_name}"
    acme.cert-manager.io/http01-ingress-class: "${local.nginx_ingress_controller_class}"
  # Do *not* use TLS on dev environment since "grafana" provider doesn't support self-signed certs
  tls: ${module.env.env_is_dev ? "[]" : local.grafana_tls}

grafana.ini:
  server:
    root_url: ${module.env.env_is_dev ? "http" : "https"}://${local.grafana_host_no_dependencies}
  smtp:
    enabled: ${local.grafana_use_aqt_smtp ? "true" : "false"}
    host: smtp.world4you.com:587
    from_address: ${local.grafana_use_aqt_smtp ? module.secrets.secret["grafana_smtp_username"] : ""}
    from_name: AQT Grafana${title(module.env.env_suffix_with_space_nonprod)}

extraInitContainers:
  - name: init-plugin-downloader
    image: busybox:1.31.1
    command:
      - sh
    args:
      - -c
      - "mkdir -p ${local.grafana_plugin_path} && cd ${local.grafana_plugin_path} && ${local.grafana_mongodb_plugin_download_and_unzip}"
    volumeMounts:
    - mountPath: /var/lib/grafana
      name: storage

extraContainers: |
  - name: mongodb-proxy
    image: node:13.12.0
    securityContext:
      runAsUser: 0
      runAsGroup: 0
      fsGroup: 0
    command:
      - sh
    args:
      - -c
      - "${local.grafana_mongodb_plugin_download_and_unzip} && cd ${local.grafana_mongodb_plugin_dirname} && npm install && npm run server"
    ports:
      - name: proxy
        containerPort: 3333
EOT
    )
  }

  byte_length = 8
}

resource "rancher2_app" "grafana" {
  count       = local.dashboard.enabled ? 1 : 0
  name        = "grafana"
  description = "Grafana"

  template_name    = "grafana"
  template_version = "5.0.1"

  catalog_name = local.helm_stable_catalog_name

  project_id       = rancher2_namespace.dashboard[0].project_id
  target_namespace = rancher2_namespace.dashboard[0].name

  answers = {
    "replicas"                  = 1
    "persistence.enabled"       = true
    "persistence.existingClaim" = module.grafana_persistent_volume_claim.claim_name
    "admin.existingSecret"      = rancher2_secret.grafana_admin[0].name
    "smtp.existingSecret"       = rancher2_secret.grafana_smtp[0].name
    "plugins[0]"                = "grafana-kubernetes-app"
    "ingress.hosts[0]"          = local.grafana_host_no_dependencies
  }
  values_yaml = local.dashboard.enabled ? base64encode(random_id.grafana_values_yaml[0].keepers.values_yaml) : ""
}

resource "grafana_alert_notification" "email" {
  count      = local.dashboard.enabled ? 1 : 0
  name       = "admin-email"
  type       = "email"
  is_default = false

  settings = {
    "addresses" = module.global_consts.admin_email
  }
}

resource "grafana_alert_notification" "mattermost" {
  count      = local.dashboard.enabled ? 1 : 0
  name       = "mattermost-alerts-channel"
  type       = "slack"
  is_default = true

  settings = {
    "url" = module.secrets.secret["mattermost_alerts_webhook_url"]
  }
}

module "postgresqlha_persistent_volume_claim" {
  volume_count = local.analytics_postgresqlha_enabled ? 1 : 0
  source       = "../../modules/persistent-volume-claim"

  name                    = "data-${module.global_consts.analytics_postgresqlha_installation_name}-postgresql-ha-postgresql"
  name_force_count_suffix = true
  disk_name_suffix        = module.env.env_suffix_nonprod
  namespace               = local.dashboard.enabled ? rancher2_namespace.dashboard[0].name : ""
  size_gb                 = 8
  is_on_google_cloud      = module.env.env_is_on_google_cloud
  google_zone             = module.global_consts.google_zone
  do_backups              = module.env.env_is_prod
  backup_schedule         = module.global_consts.bihourly_disk_backup_schedule_name
}

resource "rancher2_app" "analytics_postgresqlha" {
  count       = local.analytics_postgresqlha_enabled ? 1 : 0
  name        = module.global_consts.analytics_postgresqlha_installation_name
  description = "PostgreSQL HA"

  template_name    = module.global_consts.analytics_postgresqlha_template_name
  template_version = "1.4.12"

  catalog_name = local.bitnami_catalog_name

  project_id       = rancher2_namespace.dashboard[0].project_id
  target_namespace = rancher2_namespace.dashboard[0].name

  // All allowed values see:
  //   https://hub.helm.sh/charts/bitnami/postgresql-ha
  //   https://github.com/bitnami/charts/tree/master/bitnami/postgresql-ha/#installing-the-chart
  answers = {
    "pgpool.replicaCount"              = 2
    "postgresql.replicaCount"          = module.postgresqlha_persistent_volume_claim.volume_count
    "postgresql.username"              = module.secrets.secret["postgres_username"]
    "postgresql.password"              = module.secrets.secret["postgres_password"]
    "postgresql.database"              = module.global_consts.aqt_simulator_db_name
    "postgresql.repmgrUsername"        = module.secrets.secret["postgres_repmgr_username"]
    "postgresql.repmgrPassword"        = module.secrets.secret["postgres_repmgr_password"]
    "pgpool.adminUsername"             = module.secrets.secret["pgpool_admin_username"]
    "pgpool.adminPassword"             = module.secrets.secret["pgpool_admin_password"]
    "pgpool.resources.requests.memory" = "200Mi"
  }
}
