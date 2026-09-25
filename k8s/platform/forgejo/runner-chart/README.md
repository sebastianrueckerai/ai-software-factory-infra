---
title: "forgejo-runner"

description: "Deploy runner for an forgejo instance (default codeberg.org)"

---

# forgejo-runner

![Version: 0.7.5](https://img.shields.io/badge/Version-0.7.5-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 12.7.3](https://img.shields.io/badge/AppVersion-12.7.3-informational?style=flat-square)

Deploy runner for an forgejo instance (default codeberg.org)

## Usage

Helm must be installed and setup to your kubernetes cluster to use the charts.
Refer to Helm's [documentation](https://helm.sh/docs) to get started.
Once Helm has been set up correctly, fetch the charts as follows:

```bash
helm pull oci://code.forgejo.org/forgejo-helm/forgejo/forgejo-runner
```

You can install a chart release using the following command:

```bash
helm install forgejo-runner-release oci://code.forgejo.org/forgejo-helm/forgejo-runner --values values.yaml
```

To uninstall a chart release use `helm`'s delete command:

```bash
helm uninstall forgejo-runner-release
```

### Accessing docker socket inside job containers

To access the docker socket inside the job containers, the following example values may be used (see `values-dind-bypass.yaml`):

``` yaml {filename="values.yaml"}
runner:
  config:
    create: true
    existingSecret: ""
    file:
      log:
        level: "info"
      runner:
        file: ".runner"
        capacity: 1
        envs:
          A_TEST_ENV_NAME_1: null
          A_TEST_ENV_NAME_2: null
          DOCKER_HOST: tcp://127.0.0.1:2376
          DOCKER_TLS_VERIFY: 1
          DOCKER_CERT_PATH: /certs/client
      container:
        network: host
        enable_ipv6: false
        privileged: false
        options: -v /certs/client:/certs/client
        valid_volumes:
          - /certs/client

```

## Manipulating the docker configuration
For some setups, for example using IPv6 only, you might need to adjust the docker configuration in `/etc/docker/daemon.json`.

This can be done using volumes and configmaps:

First, create a configmap with the docker configuration in your namespace:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: etc-docker
data:
  daemon.json: |
    {
      "ipv6": true,
      "fixed-cidr-v6": "2001:db8:1::/64"
    }
```

Then, adjust the values.yaml for this chart to actually mount the config:

```yaml
volumes:
- configMap:
    name: etc-docker
  name: etc-docker
volumeMounts:
- mountPath: /etc/docker
  name: etc-docker
```

Using this example, the docker in docker container executing your jobs now has IPv6 enabled with the fixed CIDR of `2001:db8:1::/64`.

## Values

### Docker in Docker

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| dind.image.pullPolicy | string | `"IfNotPresent"` | This sets the pull policy for images. (could be overwritten by global.image.pullPolicy) |
| dind.image.registry | string | `"docker.io"` | image registry (could be overwritten by global.image.registry) |
| dind.image.repository | string | `"library/docker"` | image repository |
| dind.image.tag | string | `"29.3.1-dind"` | image tag |
| dind.resources | object | `{}` | We usually recommend not to specify default resources and to leave this as a conscious choice for the user. This also increases chances charts run on environments with little resources, such as Minikube. If you do want to specify resources, uncomment the following lines, adjust them as necessary, and remove the curly braces after 'resources:'. limits:   cpu: 100m   memory: 128Mi requests:   cpu: 100m   memory: 128Mi |

### Configuration yaml of runner (see: https://code.forgejo.org/forgejo/runner/src/branch/main/internal/pkg/config/config.example.yaml)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| runner.config.file.cache.dir | string | `""` | The directory to store the cache data. If it's empty, the cache data will be stored in $HOME/.cache/actcache. |
| runner.config.file.cache.enabled | bool | `true` | Enable cache server to use actions/cache. |
| runner.config.file.cache.external_server | string | `""` | The external cache server URL. Valid only when enable is true. If it's specified, act_runner will use this URL as the ACTIONS_CACHE_URL rather than start a server by itself. The URL should generally end with "/". |
| runner.config.file.cache.host | string | `""` | The host of the cache server. It's not for the address to listen, but the address to connect from job containers. So 0.0.0.0 is a bad choice, leave it empty to detect automatically. |
| runner.config.file.cache.port | int | `0` | The port of the cache server. 0 means to use a random available port. |
| runner.config.file.container.docker_host | string | `"-"` | overrides the docker client host with the specified one. If "-", an available docker host will automatically be found. If empty, an available docker host will automatically be found and mounted in the job container (e.g. /var/run/docker.sock). Otherwise the specified docker host will be used and an error will be returned if it doesn't work. |
| runner.config.file.container.enable_ipv6 | bool | `false` | Whether to create networks with IPv6 enabled. Requires the Docker daemon to be set up accordingly. Only takes effect if "network" is set to "". |
| runner.config.file.container.force_pull | bool | `false` | Pull docker image(s) even if already present |
| runner.config.file.container.network | string | `""` | Specifies the network to which the container will connect. Could be host, bridge or the name of a custom network. If it's empty, create a network automatically. |
| runner.config.file.container.options | string | `nil` | And other options to be used when the container is started (eg, `--add-host=my.forgejo.url:host-gateway`). |
| runner.config.file.container.privileged | bool | `false` | And other options to be used when the container is started (eg, `--add-host=my.forgejo.url:host-gateway`). |
| runner.config.file.container.valid_volumes | list | `[]` | Volumes (including bind mounts) can be mounted to containers. Glob syntax is supported, see https://github.com/gobwas/glob You can specify multiple volumes. If the sequence is empty, no volumes can be mounted. For example, if you only allow containers to mount the `data` volume and all the json files in `/src`, you should change the config to: valid_volumes:   - data   - /src/*.json If you want to allow any volume, please use the following configuration: valid_volumes:   - '**' |
| runner.config.file.container.workdir_parent | string | `nil` | The parent directory of a job's working directory. If it's empty, /workspace will be used. |
| runner.config.file.host.workdir_parent | string | `nil` | The parent directory of a job's working directory. If it's empty, $HOME/.cache/act/ will be used. |
| runner.config.file.log.job_level | string | `"info"` | The level of logging for jobs, can be trace, debug, info, earn, error, fatal |
| runner.config.file.log.level | string | `"info"` | The level of logging, can be trace, debug, info, warn, error, fatal |
| runner.config.file.runner.capacity | int | `1` | Execute how many tasks concurrently at the same time. |
| runner.config.file.runner.env_file | string | `".env"` | Extra environment variables to run jobs from a file. It will be ignored if it's empty or the file doesn't exist. |
| runner.config.file.runner.envs | object | `{"A_TEST_ENV_NAME_1":"a_test_env_value_1","A_TEST_ENV_NAME_2":"a_test_env_value_2"}` | Extra environment variables to run jobs. |
| runner.config.file.runner.fetch_interval | string | `"2s"` | The interval for fetching the job from the Forgejo instance. |
| runner.config.file.runner.fetch_timeout | string | `"5s"` | The timeout for fetching the job from the Forgejo instance. |
| runner.config.file.runner.file | string | `".runner"` | Runner config which contains id and token of this runner (autogenerate with create) |
| runner.config.file.runner.insecure | bool | `false` | Whether skip verifying the TLS certificate of the Forgejo instance. |
| runner.config.file.runner.labels | list | `[]` | The labels of a runner are used to determine which jobs the runner can run, and how to run them. Like: ["macos-arm64:host", "ubuntu-latest:docker://node:16-bullseye", "ubuntu-22.04:docker://node:16-bullseye"] If it's empty when registering, it will ask for inputting labels. If it's empty when execute `deamon`, will use labels in `.runner` file. |
| runner.config.file.runner.timeout | string | `"3h"` | The timeout for a job to be finished. Please note that the Forgejo instance also has a timeout (3h by default) for the job. So the job could be stopped by the Forgejo instance if it's timeout is shorter than this. |

### Other Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| autoscaling.behavior | object | `{}` | behavior of HPA Example:  scaleDown:    stabilizationWindowSeconds: 300    policies:      - type: Pods        value: 1        periodSeconds: 60  scaleUp:    stabilizationWindowSeconds: 0    policies:      - type: Pods        value: 1        periodSeconds: 60 |
| autoscaling.enabled | bool | `false` |  |
| autoscaling.maxReplicas | int | `100` |  |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| dnsConfig | object | `{}` | Optional Kubernetes dnsConfig for the pods. When empty, no dnsConfig is rendered. Example: dnsConfig:   nameservers:     - 1.1.1.1   searches:     - example.com   options:     - name: ndots       value: "2" |
| extraEnvVars | list | `[]` | Additional environment variables to be set on runner container Example: extraEnvVars:   - name: FOO     value: "bar"  |
| fullnameOverride | string | `""` |  |
| global.image.pullPolicy | string | `nil` | if set it will overwrite all pullPolicy |
| global.image.registry | string | `nil` | if set it will overwrite all registry entries |
| image.pullPolicy | string | `"IfNotPresent"` | This sets the pull policy for images. (could be overwritten by global.image.pullPolicy) |
| image.registry | string | `"code.forgejo.org"` | image registry (could be overwritten by global.image.registry) |
| image.repository | string | `"forgejo/runner"` | image repository |
| image.tag | string | `""` | image tag - Overrides the image tag whose default is the chart appVersion. |
| imagePullSecrets | list | `[]` |  |
| kubectl.image.pullPolicy | string | `"IfNotPresent"` |  |
| kubectl.image.registry | string | `"docker.io"` |  |
| kubectl.image.repository | string | `"alpine/kubectl"` |  |
| kubectl.image.tag | string | `"1.35.3"` |  |
| nameOverride | string | `""` |  |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` |  |
| podLabels | object | `{}` |  |
| podSecurityContext | object | `{}` |  |
| priorityClassName | string | `""` | priorityClassName : k8s scheduler priority class name for the runner |
| replicaCount | int | `1` | replicas |
| resources | object | `{}` | We usually recommend not to specify default resources and to leave this as a conscious choice for the user. This also increases chances charts run on environments with little resources, such as Minikube. If you do want to specify resources, uncomment the following lines, adjust them as necessary, and remove the curly braces after 'resources:'. limits:   cpu: 100m   memory: 128Mi requests:   cpu: 100m   memory: 128Mi |
| runner.config.create | bool | `true` |  |
| runner.config.existingInitSecret | string | `""` | Secret with Environment variables CONFIG_NAME, CONFIG_INSTANCE and CONFIG_TOKEN that should be used on initial runner configuration. If set instance, name, and token are ignored. |
| runner.config.existingSecret | string | `""` | use existingSecret instatt |
| runner.config.instance | string | `"https://codeberg.org"` |  |
| runner.config.name | string | `nil` |  |
| runner.config.token | string | `nil` |  |
| securityContext.privileged | bool | `true` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automount | bool | `true` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| tolerations | list | `[]` |  |
| volumeMounts | list | `[]` |  |
| volumes | list | `[]` |  |

Autogenerated from chart metadata using [helm-docs](https://github.com/norwoodj/helm-docs)
