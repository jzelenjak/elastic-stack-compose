#!/bin/bash
# Setup script that creates users in Elasticsearch.

set -euo pipefail
IFS=$'\n\t'

ES_HOST="${ES_HOST:-https://es01:9200}"
ES_HOME_DIR="/usr/share/elasticsearch"
CA_CERT="${ES_HOME_DIR}/config/certs/ca/ca.crt"

ELASTIC_USER="${ELASTIC_USER:-elastic}"
KIBANA_USER="${KIBANA_USER:-kibana_system}"
LOGSTASH_USER="${LOGSTASH_USER:-logstash_internal}"
BEATS_USER="${BEATS_USER:-beats_internal}"

# Wrapper functions around curl
send_request() {
  local method="$1"
  local path="$2"
  shift 2

  curl -sS --fail-with-body -X "${method}" --cacert "$CA_CERT" \
    -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" "$@" "${ES_HOST%/}/${path#/}"
  echo
}

send_request_with_body() {
  send_request "$1" "$2" -H "Content-Type: application/json" --data-binary "$3"
}

# NOTE: This is a workaround as jq is not installed in the official Elasticsearch image.
# The script assumes that environment variables do not have weird control characters.
# If control characters are necessary to support, consider installing jq, e.g.:
#  microdnf install jq -y && microdnf clean all
# Then you can use jq for better argument handling, e.g.:
#  body="$(jq -n --arg password "$KIBANA_PASSWORD" '{password: $password}')"
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Helper function to create a user in Elasticsearch
# Built-in users: https://www.elastic.co/docs/deploy-manage/users-roles/cluster-or-deployment-auth/built-in-users
create_user() {
  local user="$1"                       # string
  local password="$(json_escape "$2")"  # string
  local roles="$3"                      # json array string
  local full_name="$(json_escape "$4")" # string

  echo "Setting $user user"
  local body="$(printf '{"password":"%s","roles":%s,"full_name":"%s"}' "$password" "$roles" "$full_name")"
  send_request_with_body "PUT" "_security/user/$user" "$body"
}

# Helper function to create a role in Elasticsearch
# Note that only one indices block is (currently) supported
# Elasticsearch privileges: https://www.elastic.co/docs/reference/elasticsearch/security-privileges
# Built-in roles: https://www.elastic.co/docs/reference/elasticsearch/roles
create_role() {
  local role="$1"                 # string
  local cluster_privileges="$2"   # json array string
  local index_patterns="$3"       # json array string
  local index_privileges="$4"     # json array string

  echo "Setting ${role} role"
  local body="$(printf '{"cluster":%s,"indices":[{"names":%s,"privileges":%s}]}' "$cluster_privileges" "$index_patterns" "$index_privileges")"
  send_request_with_body "PUT" "_security/role/$role" "$body"
}


# Check if the environment variables are set and non-empty (using indirect variable reference)
vars=(ELASTIC_USER ELASTIC_PASSWORD KIBANA_USER KIBANA_PASSWORD LOGSTASH_USER LOGSTASH_PASSWORD BEATS_USER BEATS_PASSWORD)
for var in "${vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "Set the $var environment variable to a non-empty value in the .env file"
    exit 1
  fi
done

echo "Waiting for Elasticsearch availability"
available=false
for i in $(seq 1 30); do
  send_request GET / >/dev/null && available=true && break
  sleep 5;
done
[ "$available" = true ] || { echo "Cannot connect to Elasticsearch" >&2; exit 1; }

echo "Setting ${KIBANA_USER} password"
body="$(printf '{"password":"%s"}' "$(json_escape "$KIBANA_PASSWORD")")"
send_request_with_body "PUT" "_security/user/${KIBANA_USER}/_password" "$body"

# Create logstash_writer role and Logstash internal user
# Logstash basic authentication: https://www.elastic.co/docs/reference/logstash/secure-connection#ls-http-auth-basic
create_role "logstash_writer" '["monitor","manage_index_templates"]' '["logs-*","logstash-*"]' '["read","create","create_index","index","write","auto_configure"]'
create_user "$LOGSTASH_USER" "$LOGSTASH_PASSWORD" '["logstash_writer"]' "Internal Logstash User"

# Create beats_writer role and Beats internal user
create_role "beats_writer" '["monitor","read_ilm","manage_ilm","manage_index_templates","manage_ingest_pipelines"]' \
  '["logs-*","metrics-*","filebeat-*","heartbeat-*","metricbeat-*","synthetics-*"]' \
  '["read","create","create_index","index","write","auto_configure","manage","manage_ilm"]'
create_user "$BEATS_USER" "$BEATS_PASSWORD" '["beats_writer"]' "Internal Beats User"

echo "Setting snapshot directory permissions"
chown 1000:0 /usr/share/elasticsearch/snapshots
chmod 775 /usr/share/elasticsearch/snapshots

echo "All done!"
