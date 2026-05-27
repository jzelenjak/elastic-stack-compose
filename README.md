# Elastic Stack

This repository contains the Elastic Stack configuration (Elasticsearch, Logstash, Kibana, Beats) as a starting point to learn the stack. 



## Setup

The [compose.yaml](./compose.yaml) file contains the configuration for Elasticsearch, Kibana, Logstash, and Beats services.
The configuration was inspired from the [official reference setup](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-compose)
and a [setup tutorial](https://www.elastic.co/blog/getting-started-with-the-elastic-stack-and-docker-compose) and has been further adapted.

By default, the setup creates a single-node Elasticsearch cluster.
If this is your intention, then you only need the main `compose.yaml` file and you can forget about other Compose files.

In order to create a multi-node Elasticsearch cluster, you also need to use other Compose override files:
[compose.multi-node.yaml](./compose.multi-node.yaml) and [compose.multi-node.bootstrap.yaml](./compose.multi-node.bootstrap.yaml).
The second file (`compose.multi-node.bootstrap.yaml`) must only be used when first starting a new multi-node Elasticsearch cluster.
For subsequent restarts or normal operations, use only `compose.multi-node.yaml` without `compose.multi-node.bootstrap.yaml`.

Pull the Docker images for Elasticsearch, Kibana, Logstash, and Beats:
```bash
docker compose pull
```
(All images are defined in the main `compose.yaml` file.)

Make sure to set the environment variables (such as passwords and Kibana encryption keys) in the `.env` file. Use `.env.example` as a reference.
To generate Kibana encryption keys, you can use the `generate-kibana-keys` service, e.g.:
```bash
docker compose --profile kibana-keys run --rm generate-kibana-keys
```

For additional production-relevant settings, refer to the [Elastic documentation](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-prod).
Note that if you run Docker in [rootless mode](https://docs.docker.com/engine/security/rootless/), you need to comment out the memory lock settings for Elasticsearch nodes in the Compose files.



## Certificates

There are two options to use TLS certificates with the current Elastic Stack setup: using `setup-certs` service or using external certificates.


### setup-certs service

The Compose file defines a `setup-certs` service which generates certificate authority (CA) and entity certificates using the `elasticsearch-certutil` tool
(see [Elastic documentation](https://www.elastic.co/docs/reference/elasticsearch/command-line-tools/certutil) for more information about the tool).
The actual certificate generation is performed by the [setup_certs.sh](./certs/setup_certs.sh) script in the [certs/](./certs/) directory.

There are two modes to generate entity certificates with the `setup_certs.sh` script: "properties" (default) and "instances".

The "properties" mode (default) uses a `.properties` file in each entity directory for which a certificate needs to be generated.
The certificate files (certificate with `.crt` extension and private key with `.key` extension) are created in the same directory as the properties file.
Multiple `.properties` files can be defined in the same directory to create certificates for different roles of the same entity (e.g., HTTP vs transport, client vs server etc.).

The properties files must have the following format (consistent with the options for `elasticsearch-certutil`):
```
NAME=<service_name_or_dn>
FILENAME=<cert_file_name_without_extension_and_slashes>
DNS=<comma_separated_hostnames>
IP=<comma_separated_ip_addresses>
```
The `NAME` property is required, while other properties are optional (but recommended).
If `FILENAME` is not specified, then `NAME` is used as the certificate file name.
This might be undesired if `NAME` is something other than service name (e.g., DN), so it is better to explicitly define the `FILENAME` property.
Note that properties with empty values (e.g., `FILENAME=`) behave like having missing values, so there is no point in specifying empty properties.

The [certs/entities](./certs/entities/) directory contains the properties files for the current Compose setup (e.g., see [es01](./certs/entities/es01/)).
Feel free to change these files, add new properties files, or delete the existing properties files if you do not need them. 

The advantage of "properties" mode is that it is flexible, gives more control over directory structure, and is better for idempotence, since it checks existing certificate files.
The disadvantage is that a separate properties file is needed for each entity or entity role.

The "instances" mode uses a single `instances.yml` file that defines all entities for which certificates need to be created.
This file is then used by `elasticsearch-certutil` to generate all certificates for the specified entities. 

The [certs/](./certs/) directory contains the instances files for single-node setup ([instances.yml](./certs/instances.yml)) and multi-node setup ([instances-multi.yml](./certs/instances-multi.yml)).
For more information about the file format, see [elasticsearch-certutil documentation](https://www.elastic.co/docs/reference/elasticsearch/command-line-tools/certutil#certutil-silent).

The advantage of "instances" mode is that it uses a single YAML file with all entities (entity roles) and invalid formats are handled by `elasticsearch-certutil`.
The disadvantage is that there is less control over directory structure (e.g., certificates for different roles of the same entity will be in different directories).
Furthermore, certificate files are always generated, since existing certificate files cannot be reliably detected based on the YAML file.
Nevertheless, existing certificate files are not overwritten even if their name remains the same.

Note that CA certificate generation does not depend on the chosen mode. The mode only affects entity (leaf) certificate creation.

To change the certificate generation mode, set the environment variable `MODE` to "instances" (or "properties") in the `compose.yaml` file.

The `setup_certs.sh` script also allows setting some certificate parameters, such as key size or lifetime, by defining the corresponding environment variables.

To generate certificates using the `setup-certs` service, run:
```bash
# Single-node cluster or when using properties mode (regardless of single- vs multi-node setup)
docker compose --profile certs run --rm setup-certs
# Multi-node cluster (important when using instances.yml file)
docker compose --profile certs -f compose.yaml -f compose.multi-node.yaml run --rm setup-certs
# Explicitly start the service (specify the compose files with -f if needed)
docker compose up setup-certs
```
If you need to regenerate certificates, simply delete the old certificate files in the corresponding `certs/entities/` directory and rerun the `setup-certs` service.


### External certificates

To use external certificates, you need to copy the corresponding certificate files (`.key` and `.crt`) to the [certs/entities/](./certs/entities/) directory.

The certificate paths must match the paths specified in the Compose files, so that bind mounts are done correctly.
For example, you can have `certs/entities/es01/es01.crt` and `certs/entities/es01/es01.key` for the `es01` service.

For CA, you only need a `ca.crt` certificate file in the `certs/entities/ca_pub/` directory, which is then used by the services for verification.
You do not need a `ca.key` file, since it is only used for local certificate generation using `setup-certs` service (as described above).
Feel free to modify the paths in the Compose files to match your setup.

If using external certificates, you can ignore all setup files in the `certs/` directory.
You can also safely delete the `.properties` files if they bother you.



## Usage

First, make sure you have all the required certificates in the `certs/entities/` directory (see the above section).

If you want to perform certificate generation when starting other services, you could add `--profile certs` to the Compose command (e.g., `docker compose --profile certs up`).
Note, however, that this is not recommended with the current setup, since Elasticsearch service does not depend on the `setup-certs` service to complete.
Therefore, to ensure a proper [startup order](https://docs.docker.com/compose/how-tos/startup-order/), you would need to add a `depends_on` section for Elasticsearch service(s),
specifying `setup-certs` with `condition: service_completed_successfully`.

Before starting the stack, it is recommended to verify the Compose configuration by running:
```bash
# Single-node cluster
docker compose config
# Multi-node cluster
docker compose -f compose.yaml -f compose.multi-node.yaml config
```


### Single-node cluster

For single-node setup, you can use standard Docker Compose commands to deploy the stack, e.g.:
```bash
# Start the core services
docker compose up
# Start Elasticsearch and Kibana
docker compose up es01 kibana
```


### Multi-node cluster

For multi-node setup, you need to specify the override Compose files with the `-f` option:
```bash
# When starting a new multi-node Elasticsearch cluster
docker compose -f compose.yaml -f compose.multi-node.yaml -f compose.multi-node.bootstrap.yaml up
# For further operations on a multi-node Elasticsearch cluster
docker compose -f compose.yaml -f compose.multi-node.yaml up
```

For convenience, you can also use a wrapper script [compose-cmd.sh](./compose-cmd.sh), specifying the mode:
```bash
./compose-cmd.sh up                      # Runs `docker compose -f compose.yaml up`
./compose-cmd.sh single up -d            # Runs `docker compose -f compose.yaml up -d`
./compose-cmd.sh multi config            # Runs `docker compose -f compose.yaml -f compose.multi-node.yaml config`
./compose-cmd.sh multi-bootstrap config  # Runs `docker compose -f compose.yaml -f compose.multi-node.yaml -f compose.multi-node.bootstrap.yaml config`
```
Note: Use `multi-bootstrap` only when creating a new multi-node Elasticsearch cluster. Once the cluster has formed, use `multi` instead.
You can also use [compose-cmd-strict.sh](./compose-cmd-strict.sh), which is a slightly stricter version of `compose-cmd.sh`
that checks existing Elasticsearch data volumes before allowing Compose startup commands with `multi` or `multi-bootstrap`.


### Logstash and Beats

Logstash and Beats are not the core services. Therefore, they have explicitly defined [profiles](https://docs.docker.com/compose/how-tos/profiles/).
You can either start them later, once the core services (Elasticsearch and Kibana) are running, e.g.:
```bash
docker compose up logstash
docker compose up filebeat heartbeat
```
or you can specify the profile(s) when starting the stack, e.g.:
```bash
# Start Elasticsearch, Kibana, and Logstash
docker compose --profile logstash up
# Start Elasticsearch, Kibana, and Beats
docker compose --profile beats up
# Start Elasticsearch, Kibana, Logstash, and Beats
docker compose --profile ingest up
# Start all services
docker compose --profile "*" up
```
Note: to stop and/or remove the non-core services, you also need to specify the profile, e.g.:
```bash
# Stop Elasticsearch, Kibana, and Logstash
docker compose --profile logstash stop
# Remove all services
docker compose --profile "*" down
```


### Further usage

To access Kibana, enter `https://localhost:5601` in your browser.
Note that including the scheme `https://` is necessary, since Kibana is configured to use HTTPS.

To query Elasticsearch, run:
```bash
curl --cacert certs/entities/ca_pub/ca.crt -u "elastic:$ELASTIC_PASSWORD" -XGET 'https://localhost:9200?pretty'
```
(You can create a symlink for `ca.crt` in the repository root directory to make the command slightly shorter, e.g., `ln -s certs/entities/ca_pub/ca.crt ca.crt`)

Note that `es01` is the only node that exposes the HTTP API to the host.

To save some typing, you can use `curl.py` and `curl.sh` wrapper scripts in the [utils](./utils/) directory, which predefine some `curl` arguments, e.g.:
```bash
./utils/curl.py GET 'https://localhost:9200/{index}/_search?pretty' '{"query": {"match": {"field": "value"}}}'
./utils/curl.py GET '/{index}/_search?pretty' '{"query": {"match": {"field": "value"}}}'
./utils/curl.sh -XPOST 'https://localhost:9200/_bulk?pretty' --data-binary @documents.ndjson
```
(You can also create a symlink in the repository root directory for easier invocation, e.g. `ln -s utils/curl.py curl.py`)

To parse or highlight the output, you can use `jq` command-line JSON processor (e.g. `... | jq` or `... | jq -r '.hits.hits.[]._id'`).


### Remove certificate warnings

If you want to remove certificate warnings when accessing Kibana via the browser, add the previously generated CA certificate (`./certs/entities/ca_pub/ca.crt`) to the trust store.
For example, in Firefox, you can go to **Settings > Privacy & Security** (or `about:preferences#privacy`), find the section **Certificates**, choose **Manage certificates > Authorities**, and import the certificate.
Alternatively, you can use the `certutil` tool, e.g.:
```bash
certutil -d ~/.mozilla/firefox/{your_profile}/ -A -i certs/entities/ca_pub/ca.crt -n "Elastic Certificate Tool Autogenerated CA" -t C,,
```
See [this wiki page](https://wiki.archlinux.org/title/User:Grawity/Adding_a_trusted_CA_certificate) for more information.
