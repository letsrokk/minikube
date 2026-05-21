# Minikube Workloads

This repository contains a small Helmfile-based Minikube workload stack for local Kubernetes development. It installs ingress, SeaweedFS S3-compatible storage, and the Mountpoint for Amazon S3 CSI driver wired to the local SeaweedFS gateway.

## Workloads

Helmfile currently manages these releases:

- `ingress-nginx` installs the NGINX Ingress Controller.
- `seaweedfs` installs SeaweedFS with persistent storage, a standalone S3 gateway, and filer UI exposed through the `nginx` ingress class.
- `aws-mountpoint-s3-csi-driver` installs the Mountpoint for Amazon S3 CSI driver and creates its `kube-system/seaweedfs-s3-secret` credential Secret from the same SeaweedFS S3 credentials already configured in `.env`.

## Layout

- `helmfile.yaml`: single deployment entrypoint
- `environments/minikube/values.yaml`: shared Minikube defaults, including `seaweedfs.s3Host`, `seaweedfs.filerHost`, `seaweedfs.volumeSize`, `seaweedfs.filerSize`, and `seaweedfs.s3Buckets`
- `environments/minikube/ingress-nginx-values.yaml`: ingress controller chart values
- `environments/minikube/seaweedfs-values.yaml.gotmpl`: SeaweedFS chart values rendered by Helmfile
- `environments/minikube/aws-mountpoint-s3-csi-driver-wrapper-values.yaml.gotmpl`: Helmfile-rendered values for the CSI wrapper chart
- `charts/aws-mountpoint-s3-csi-driver-wrapper`: local wrapper chart that creates the CSI driver Secret in `kube-system` and embeds the upstream CSI chart as a dependency
- `.env`: local-only SeaweedFS S3 credentials
- `.env.example`: template for the local env file

## Prerequisites

- `helm`
- `helmfile`
- `kubectl`
- `minikube`

Install `helmfile` from the official Helmfile release channel for your OS if it is not already present.

The upstream Mountpoint S3 CSI chart archive is not committed. Build the wrapper chart dependency after cloning:

```bash
helm dependency build charts/aws-mountpoint-s3-csi-driver-wrapper
```

## Prepare Minikube

Start Minikube if needed:

```bash
minikube start --kubernetes-version=1.35.4 --cpus=4 --memory=16g
```

Confirm the cluster context:

```bash
kubectl config current-context
```

Run a local tunnel so the `ingress-nginx` `LoadBalancer` service can accept traffic on standard HTTP/HTTPS ports:

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

- `environments/minikube/ingress-nginx-values.yaml`
- `environments/minikube/seaweedfs-values.yaml.gotmpl`
- `environments/minikube/values.yaml`

## Deploy

Helper wrappers load `.env` automatically and accept an optional Helmfile environment name. They default to `default`, which uses the same values as `minikube`.

```bash
./helmfile-diff.sh
./helmfile-apply.sh
./helmfile-destroy.sh
./helmfile-diff.sh minikube
```

Helm releases are applied atomically, so a failed install or upgrade is rolled back instead of leaving partial Helm state behind.
`./helmfile-diff.sh` and `./helmfile-apply.sh` expect the Helm diff plugin to be installed locally.

Equivalent raw Helmfile commands:

```bash
set -a
source .env
set +a

helmfile -e minikube diff
helmfile -e minikube template
helmfile -e minikube apply
helmfile -e minikube destroy
```

Common examples:

```bash
./helmfile-diff.sh minikube
./helmfile-apply.sh minikube
./helmfile-destroy.sh minikube
```

The `seaweedfs` release depends on `ingress-nginx`, and the Mountpoint S3 CSI driver depends on `seaweedfs`, so Helmfile installs them in the correct order.

## Reach SeaweedFS

This scaffold uses these hostnames by default:

- S3 API: `seaweedfs-s3.localhost`
- Filer UI: `seaweedfs-filer.localhost`

After `minikube tunnel` is running, get the external address of the ingress controller:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

Map both hostnames to the `EXTERNAL-IP` shown for that service in your local hosts file. Then open:

- `http://seaweedfs-filer.localhost/`
- `http://seaweedfs-s3.localhost`

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
- do not route CSI traffic through `seaweedfs-s3.localhost`; use the in-cluster service endpoint above

## Validate

Check the releases:

```bash
helmfile -e minikube list
kubectl get pods -n ingress-nginx
kubectl get pods -n seaweedfs
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver
kubectl get ingress -n seaweedfs
kubectl get pvc -n seaweedfs
kubectl get secret -n kube-system seaweedfs-s3-secret
```
