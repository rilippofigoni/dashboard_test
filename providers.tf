provider "grafana" {
  // Use http for local dev environment since provider doesn't support self-signed certs
  url  = "${module.env.env_is_dev ? "http://" : "https://"}${local.grafana.host}"
  auth = "${module.secrets.secret["grafana_admin_username"]}:${module.secrets.secret["grafana_admin_password"]}"
}