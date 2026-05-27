#!/bin/bash
# Setup script that generates CA and entity certificates.
# Entity certificates can be generated using two modes: 
# - "properties": (default) uses .properties file in each entity directory
#   - Advantages: flexible and better for idempotence (checks existing certificate files)
#   - Disadvantages: requires a separate properties file for each entity (or entity role)
# - "instances": uses instances.yml in the current directory
#   - Advantages: only one instances.yml file is needed (batch mode)
#   - Disadvantages: cannot easily check which certificates already exist
# For information about elasticsearch-certutil, see the documentation:
# - https://www.elastic.co/docs/reference/elasticsearch/command-line-tools/certutil
# - https://github.com/elastic/elasticsearch/blob/main/x-pack/plugin/security/cli/src/main/java/org/elasticsearch/xpack/security/cli/CertificateTool.java

set -euo pipefail
IFS=$'\n\t'

#############
# Variables #
#############

# Main directories
HOME_DIR="/usr/share/elasticsearch"
CONF_DIR="${HOME_DIR}/config"
CERT_DIR="${CONF_DIR}/certs"

# CA files and directories
CA_CERT_DIR="${CERT_DIR}/ca"
CA_CERT_KEY_NAME="ca.key"
CA_CERT_FILE_NAME="ca.crt"
CA_CERT_KEY="${CA_CERT_DIR}/${CA_CERT_KEY_NAME}"
CA_CERT_FILE="${CA_CERT_DIR}/${CA_CERT_FILE_NAME}"
CA_PUB_CERT_DIR="${CERT_DIR}/ca_pub"
CA_PUB_CERT_FILE="${CA_PUB_CERT_DIR}/${CA_CERT_FILE_NAME}"

# Configurable CA certificate parameters
CA_KEY_SIZE="${CA_KEY_SIZE:-4096}"
CA_LIFETIME_DAYS="${CA_LIFETIME_DAYS:-1095}"  # 3 years
CA_KEY_USAGE="${CA_KEY_USAGE:-keyCertSign,cRLSign}"
CA_DN="${CA_DN:-}"  # Format must be 'CN=...' (empty value results in the default name)

# Configurable leaf certificate parameters
LEAF_KEY_SIZE="${LEAF_KEY_SIZE:-4096}"
LEAF_LIFETIME_DAYS="${LEAF_LIFETIME_DAYS:-730}"  # 2 years

# Entity certificate generation modes: use properties files (default) or use single instances.yml file
MODE="${MODE:-properties}"
ALLOWED_MODES=("properties" "instances")
# Settings for each mode
ALLOWED_PROPERTIES=("NAME" "FILENAME" "IP" "DNS")
PROPERTIES_FILE_EXTENSION="properties"
INSTANCES_FILE="${CONF_DIR}/instances.yml"

# Script base name (used for logging errors and warnings)
script="${0##*/}"


#############
# Functions #
#############

# Checks if target value is in array
arr_contains() {
    local target="${1:-}"
    shift
    for el in "$@"; do
        [ "$el" = "$target" ] && return 0
    done
    return 1
}

# Prints array elements (comma-separated)
print_arr() {
  local IFS=","
  echo "$*" | sed 's/,/, /g'
}

# Sets properties defined in provided file as environment variables
set_properties_from_file() {
  local file="${1:-}"
  [ -f "$file" ] || { echo "${script}: ${file}: no such file" >&2; return 1; }

  local key value
  while IFS="=" read -r key value; do
    # Remove leading and trailing spaces
    key="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$key")"
    value="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$value")"

    # Skip empty lines and comments
    { [ -z "$key" ] || grep -q '^#' <<< "$key"; } && continue
    # Terminate if line has invalid format or unknown entry (allowed properties might have empty values, e.g. 'FILENAME=')
    [ -z "$value" ] && ! arr_contains "$key" "${ALLOWED_PROPERTIES[@]}" && { echo "${script}: ${file}: invalid entry '$key'. Use 'KEY=VALUE' format" >&2; exit 1; }
    # Terminate if line defines invalid property
    arr_contains "$key" "${ALLOWED_PROPERTIES[@]}" || { echo "${script}: ${file}: unknown property '$key'. Allowed properties are: $(print_arr "${ALLOWED_PROPERTIES[@]}")" >&2; return 1; }

    # Remove leading and trailing quotes
    value="$(sed -e 's/^["'\'']//' -e 's/["'\'']$//' <<< "$value")"

    export "${key}=${value}"
  done < "$file"
}


############
#   Main   #
############

# Check if script is running in correct directory
[ "$PWD" = "$HOME_DIR" ] || { echo "${script}: incorrect PWD: must be $HOME_DIR not $PWD" >&2; exit 1; }
# Check if specified mode is allowed
arr_contains "$MODE" "${ALLOWED_MODES[@]}" || { echo "${script}: unknown mode: '$MODE'. Allowed modes are: $(print_arr "${ALLOWED_MODES[@]}")" >&2; exit 1; }

# Create certs directory if missing
[ ! -d "$CERT_DIR" ] && mkdir --mode 750 "$CERT_DIR"


############
#    CA    #
############

# Create CA certificate files (key and certificate) if missing
if [ ! -f "$CA_CERT_FILE" ] || [ ! -f "$CA_CERT_KEY" ]; then
  # Terminate if only one file exists
  [ -f "$CA_CERT_FILE" ] && { echo "${script}: $CA_CERT_FILE exists but $CA_CERT_KEY does not" >&2; exit 1; }
  [ -f "$CA_CERT_KEY" ] && { echo "${script}: $CA_CERT_KEY exists but $CA_CERT_FILE does not" >&2; exit 1; }

  # Create CA certs directory if missing
  [ ! -d "$CA_CERT_DIR" ] && mkdir --mode 750 "$CA_CERT_DIR"

  echo "Creating CA"
  out_zip_file="${CERT_DIR}/ca.zip"
  [ -f "$out_zip_file" ] && rm -rf "$out_zip_file"
  elasticsearch-certutil ca --silent --pem --keysize "$CA_KEY_SIZE" --days "$CA_LIFETIME_DAYS" --keyusage "$CA_KEY_USAGE" --ca-dn "$CA_DN" --out "${CERT_DIR}/ca.zip"
  unzip "$out_zip_file" -d "$CERT_DIR" && rm -rf "$out_zip_file"
else
  echo "CA already exists -- skipping"
fi

echo "Copying CA cert file"
# Create public CA certs directory if missing and copy public CA certificate
[ -d "$CA_PUB_CERT_DIR" ] || mkdir "$CA_PUB_CERT_DIR"
[ -f "$CA_PUB_CERT_FILE" ] && rm -rf "$CA_PUB_CERT_FILE"
cp "${CA_CERT_FILE}" "$CA_PUB_CERT_FILE"


############
# Entities #
############

# Running in "instances" mode (i.e. using instances.yml)
if [ "$MODE" = "instances" ]; then
  # Check if instances.yml file exists
  [ -f "$INSTANCES_FILE" ] || { echo "${script}: running in 'instances' mode but $INSTANCES_FILE is missing" >&2; exit 1; }

  # Generate certificate files based on instances.yml
  echo "Creating entity certificates based on $INSTANCES_FILE"
  out_zip_file="${CERT_DIR}/certs.zip"
  [ -f "$out_zip_file" ] && rm -rf "$out_zip_file"
  elasticsearch-certutil cert --silent --pem --ca-cert "$CA_CERT_FILE" --ca-key "$CA_CERT_KEY" --keysize "$LEAF_KEY_SIZE" \
    --days "$LEAF_LIFETIME_DAYS" --in "$INSTANCES_FILE" --out "$out_zip_file"

  # Extract generated certificate files but do not overwrite existing files
  unzip -n -d "$CERT_DIR" "$out_zip_file" && rm -rf "$out_zip_file"
fi

# Running in "properties" mode (i.e. using properties file for each entity)
if [ "$MODE" = "properties" ]; then
  while IFS= read -d $'\0' -r dir ; do 
    while IFS= read -d $'\0' -r properties_file ; do 
      # Unset any previously set properties
      unset "${ALLOWED_PROPERTIES[@]}"

      # Get base directory name where properties file is found
      dir="${dir%/}"
      dir_name="${dir##*/}"
      echo "Found ${dir_name}/$(basename "$properties_file")"

      # Extract properties defined in file
      set_properties_from_file "$properties_file"

      # Verify defined properties
      [ -z "${NAME:-}" ] && { echo "${script}: $properties_file must have non-empty NAME property" >&2; exit 1; }
      [ -z "${IP:=}" ] && echo "${script}: warning: $properties_file is missing IP property" >&2
      [ -z "${DNS:=}" ] && echo "${script}: warning: $properties_file is missing DNS property" >&2
      [ -n "${FILENAME:-}" ] && [ "$FILENAME" != "${FILENAME##*/}" ] && { echo "${script}: FILENAME cannot contain slashes" >&2; exit 1; }

      # Check if target certificate files already exist (either both or no files must exist)
      [ -n "${FILENAME:-}" ] && target_name="$FILENAME" || target_name="$NAME"
      target_prefix="${dir}/${target_name}"
      [ -f "${target_prefix}.crt" ] && [ -f "${target_prefix}.key" ] && { echo "$target_name already exists in $dir --skipping"; continue; }
      [ -f "${target_prefix}.crt" ] && { echo "${script}: ${target_prefix}.crt exists but ${target_prefix}.key does not" >&2; exit 1; }
      [ -f "${target_prefix}.key" ] && { echo "${script}: ${target_prefix}.key exists but ${target_prefix}.crt does not" >&2; exit 1; }

      # Generate entity certificate files based on properties file
      out_zip_file="${dir}/$(basename --suffix=".${PROPERTIES_FILE_EXTENSION}" "$properties_file").zip"
      [ -f "$out_zip_file" ] && rm -rf "$out_zip_file"
      elasticsearch-certutil cert --silent --pem --ca-cert "$CA_CERT_FILE" --ca-key "$CA_CERT_KEY" --keysize "$LEAF_KEY_SIZE" \
        --days "$LEAF_LIFETIME_DAYS" --name "$NAME" --ip "$IP" --dns "$DNS" --out "$out_zip_file"

      # Extract generated certificate files into temporary directory
      in_cert_dir="$(mktemp -d)"
      unzip -q -d "$in_cert_dir" "$out_zip_file" && rm -rf "$out_zip_file"

      # Move generated certificate files into target directory using correct target name
      while IFS= read -d $'\0' -r in_cert_file ; do 
        extension="${in_cert_file##*.}"
        out_cert_file="${target_prefix}.${extension}"
        mv --no-clobber "$in_cert_file" "$out_cert_file"
      done < <(find "$in_cert_dir" -type f \( -name '*.crt' -o -name '*.key' \) -print0)
      rm -rf "$in_cert_dir"

      echo "Generated certificate files for $target_name into $dir"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -name "*.${PROPERTIES_FILE_EXTENSION}" -print0)
  done < <(find "$CERT_DIR" -mindepth 1 -maxdepth 1 -type d ! -name 'ca' -print0 | sort -z)
fi

echo "Setting file permissions"
find "$CERT_DIR" -type d -exec chmod 750 \{\} \;
find "$CERT_DIR" -type f -exec chmod 640 \{\} \;
chmod 644 "${CA_PUB_CERT_DIR}/${CA_CERT_FILE_NAME}"
chmod 755 "$CA_PUB_CERT_DIR"

echo "All done!"
