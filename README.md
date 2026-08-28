# Minikube Workloads

This repository contains a small Helmfile-based Minikube workload stack for local Kubernetes development. It installs ingress, SeaweedFS S3-compatible storage, and the Mountpoint for Amazon S3 CSI driver wired to the local SeaweedFS gateway.

## Workloads

Helmfile currently manages these releases:

- `traefik` installs chart `41.2.0` with Traefik `v3.7.10` as the Kubernetes Ingress controller, including its CRDs, a local default TLS certificate, and a permanent HTTP-to-HTTPS redirect.
- `seaweedfs` installs SeaweedFS with persistent storage, a standalone S3 gateway, and filer UI exposed through the `traefik` ingress class.
- `aws-mountpoint-s3-csi-driver` installs the Mountpoint for Amazon S3 CSI driver and creates its `kube-system/seaweedfs-s3-secret` credential Secret from the same SeaweedFS S3 credentials already configured in `.env`.

## Layout

- `helmfile.yaml`: single deployment entrypoint
- `environments/minikube/values.yaml`: shared Minikube defaults, including `seaweedfs.s3Host`, `seaweedfs.filerHost`, `seaweedfs.volumeSize`, `seaweedfs.filerSize`, and `seaweedfs.s3Buckets`
- `environments/minikube/traefik-values.yaml.gotmpl`: Traefik chart values and local TLS resources rendered by Helmfile
- `environments/minikube/seaweedfs-values.yaml.gotmpl`: SeaweedFS chart values rendered by Helmfile
- `environments/minikube/aws-mountpoint-s3-csi-driver-wrapper-values.yaml.gotmpl`: Helmfile-rendered values for the CSI wrapper chart
- `charts/aws-mountpoint-s3-csi-driver-wrapper`: local wrapper chart that creates the CSI driver Secret in `kube-system` and embeds the upstream CSI chart as a dependency
- `.env`: local-only SeaweedFS S3 credentials
- `.env.example`: template for the local env file
- `.certs/traefik`: ignored local CA and server certificate files
- `traefik-generate-certificates.sh`: creates or validates the local CA and localhost server certificate
- `traefik-apply-crds.sh`: server-side applies the CRDs from the pinned Traefik chart before a Helmfile apply

## Prerequisites

- `helm`
- `helmfile`
- `kubectl`
- `minikube`
- `openssl`

Install `helmfile` from the official Helmfile release channel for your OS if it is not already present.

The upstream Mountpoint S3 CSI chart archive is not committed. Build the wrapper chart dependency after cloning:

```bash
helm repo add aws-mountpoint-s3-csi-driver https://awslabs.github.io/mountpoint-s3-csi-driver
helm dependency build charts/aws-mountpoint-s3-csi-driver-wrapper
```

## Prepare Minikube

Start Minikube if needed:

```bash
minikube start --kubernetes-version=1.36.4 --cpus=8 --memory=12g --cni=calico
```

Confirm the cluster context:

```bash
kubectl config current-context
```

Run a local tunnel so the Traefik `LoadBalancer` service can accept traffic on standard HTTP/HTTPS ports:

```bash
minikube tunnel
```

Keep the tunnel running in a separate terminal while you use the deployment.

## Configure Local Credentials

Create the local env file from the template and update the S3 credentials:

```bash
cp .env.example .env
sed -n '1,20p' .env
```

The real `.env` file is ignored by git.
These same credentials are used for both the SeaweedFS S3 gateway and the `kube-system/seaweedfs-s3-secret` Secret created by the Mountpoint S3 CSI driver wrapper release.
Do not commit real `.env` values; Helmfile renders them into Kubernetes Secrets during deployment.

Tracked non-secret settings live in:

- `environments/minikube/traefik-values.yaml.gotmpl`
- `environments/minikube/seaweedfs-values.yaml.gotmpl`
- `environments/minikube/values.yaml`

## Configure Local TLS

Generate the local CA and server certificate before running any Helmfile diff, template, or apply command:

```bash
./traefik-generate-certificates.sh
```

The script is idempotent. It validates existing certificates instead of replacing them. Use `./traefik-generate-certificates.sh --renew-server` to create a new server-certificate version while preserving the CA. Server certificates are valid for 397 days to satisfy macOS TLS policy. The script switches the `current` symlink only after the complete key, certificate, and chain pass validation, and retains the previous version for rollback.

Generated files live under the ignored `.certs/traefik` directory. The CA private key and current server private key use mode `0600`. The server certificate contains one SAN:

- `DNS:*.minikube.localhost`

Helmfile publishes only these resources to Kubernetes:

- `traefik/localhost-wildcard-tls`: a `kubernetes.io/tls` Secret containing the server key and the server-plus-CA certificate chain
- `traefik/localhost-ca`: a ConfigMap containing only the public CA certificate under `ca.crt`
- `traefik/default`: the global Traefik `TLSStore` that selects `localhost-wildcard-tls`

The CA private key never enters a rendered Helm value or Kubernetes resource. Install `.certs/traefik/ca-current/ca.crt` in your local trust store if browsers and other clients should trust the development certificate without an explicit CA option.

## Deploy

Helper wrappers load `.env` automatically and accept an optional Helmfile environment name. They default to `default`, which uses the same values as `minikube`. They require the local TLS files created above.

```bash
./helmfile-diff.sh
./helmfile-apply.sh
./helmfile-destroy.sh
./helmfile-diff.sh minikube
```

`./helmfile-apply.sh` server-side applies the CRDs bundled with Traefik chart `41.2.0` before applying the Helm releases. This handles both first installation and CRD schema updates because Helm does not upgrade CRDs from a chart's `crds/` directory. When changing the Traefik chart version, update the version in both `helmfile.yaml` and `traefik-apply-crds.sh`.

Helm releases are applied atomically, so a failed install or upgrade rolls back release-managed resources. Helm does not roll back or delete CRDs; Traefik CRDs remain until they are managed explicitly.
`./helmfile-diff.sh` and `./helmfile-apply.sh` expect the Helm diff plugin to be installed locally.

Equivalent raw Helmfile commands:

```bash
set -a
source .env
set +a

helmfile -e minikube diff --diff-args=--disable-validation
helmfile -e minikube template
./traefik-apply-crds.sh
helmfile -e minikube apply
helmfile -e minikube destroy
```

Rendered Helmfile output contains Kubernetes Secret data, including the Traefik server private key and SeaweedFS credentials. Do not publish template or diff output in CI logs or shared artifacts. If output must be saved, write it to a private location with restricted permissions and remove it when the check is complete.

Common examples:

```bash
./helmfile-diff.sh minikube
./helmfile-apply.sh minikube
./helmfile-destroy.sh minikube
```

The `seaweedfs` release depends on `traefik`, and the Mountpoint S3 CSI driver depends on `seaweedfs`, so Helmfile installs them in the correct order.

### Replace an Existing ingress-nginx Installation

Fresh installations do not need a migration step; use the normal Helmfile apply workflow above.

For a cluster that already runs this stack with ingress-nginx, use a stop-then-start cutover. This creates a short routing outage while the controller changes:

```bash
./traefik-generate-certificates.sh
./traefik-apply-crds.sh
helm uninstall ingress-nginx -n ingress-nginx
./helmfile-apply.sh minikube
kubectl wait -n traefik --for=condition=Available deployment/traefik --timeout=10m
```

Helmfile does not uninstall a release after it is removed from `helmfile.yaml`, so the explicit `helm uninstall` command is required for an existing installation.

## Reach SeaweedFS

This scaffold uses these hostnames by default:

- S3 API: `seaweedfs-s3.minikube.localhost`
- Filer UI: `seaweedfs-filer.minikube.localhost`

After `minikube tunnel` is running, get the external address of the ingress controller:

```bash
kubectl get svc -n traefik traefik
```

Map both hostnames to the `EXTERNAL-IP` shown for that service in your local hosts file. Then open:

- `https://seaweedfs-filer.minikube.localhost/`
- `https://seaweedfs-s3.minikube.localhost`

Requests to the equivalent `http://` URLs receive a permanent redirect to HTTPS.

## Use SeaweedFS Through CSI

This repo installs the Mountpoint S3 CSI driver and creates the configured SeaweedFS S3 buckets.
The default bucket is `default-bucket`.
Each service that wants to mount SeaweedFS-backed S3 storage must create its own static PV/PVC outside this repo.
The wrapper chart creates a `seaweedfs-s3` `StorageClass` for static PV/PVC binding.

For this Minikube setup, services should:

- use `default-bucket`, or another bucket listed in `seaweedfs.s3Buckets`
- isolate themselves with a dedicated S3 prefix such as `service-a/`
- mount the in-cluster SeaweedFS S3 service directly, not the ingress hostname

Supported PV contract for this cluster:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: example-s3-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  storageClassName: seaweedfs-s3
  mountOptions:
    - endpoint-url http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333
    - force-path-style
    - region us-east-1
    - prefix service-a/
  csi:
    driver: s3.csi.aws.com
    volumeHandle: example-s3-pv
    volumeAttributes:
      bucketName: default-bucket
```

Notes:

- `prefix` must end with `/`
- `bucketName` must point at a bucket listed in `seaweedfs.s3Buckets`
- `allow-delete` is optional and should be added only by services that need delete semantics
- do not use `authenticationSource: pod` in this Minikube setup; the CSI driver uses the Secret `kube-system/seaweedfs-s3-secret`
- do not route CSI traffic through `seaweedfs-s3.minikube.localhost`; use the in-cluster service endpoint above

## Validate

Check the releases:

```bash
helmfile -e minikube list
kubectl get pods -n traefik
kubectl get ingressclass traefik
kubectl get crd tlsstores.traefik.io
kubectl get tlsstore -n traefik default
kubectl get secret -n traefik localhost-wildcard-tls
kubectl get configmap -n traefik localhost-ca
kubectl get pods -n seaweedfs
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver
kubectl get ingress -n seaweedfs -o wide
kubectl get pvc -n seaweedfs
kubectl get secret -n kube-system seaweedfs-s3-secret
```

After mapping the two hostnames to the Traefik service external address, verify both routes:

```bash
curl -I http://seaweedfs-filer.minikube.localhost/
curl -I http://seaweedfs-s3.minikube.localhost/
curl --cacert .certs/traefik/ca-current/ca.crt -i https://seaweedfs-filer.minikube.localhost/
curl --cacert .certs/traefik/ca-current/ca.crt -i https://seaweedfs-s3.minikube.localhost/
```

Both HTTP requests must return a permanent redirect to HTTPS. The S3 HTTPS endpoint can return an authentication response for an unsigned request. A SeaweedFS response confirms the route; a Traefik `404 page not found` response means the ingress did not match.
