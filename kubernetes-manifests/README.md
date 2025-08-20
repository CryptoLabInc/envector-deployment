# enVector Self-Hosted Helm Chart Deployment Guide

## Prerequisites
- External PostgreSQL database and storage must be running and accessible.
- If using a private registry, create the imagePullSecret (regcred):
  ```sh
  kubectl create secret docker-registry regcred \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username=<YOUR_USERNAME> \
    --docker-password=<YOUR_PASSWORD> \
    --docker-email=<YOUR_EMAIL>
  ```

## Installation
```sh
helm install envector ./helm
```

- Edit `values.yaml` to match your environment (DB/Storage address, image, port, etc).
- Each service uses readinessProbe and initContainer to automatically wait for dependencies to be ready.

## Uninstallation
```sh
helm uninstall envector
```

## Check Status & View Logs
```sh
kubectl get pods
kubectl logs <pod-name>
```

## Notes
- es2b waits for external DB/Storage to be reachable before starting.
- es2c waits for es2s to be ready before starting.
- es2e waits for es2b, es2s, and es2c to be ready before starting.
