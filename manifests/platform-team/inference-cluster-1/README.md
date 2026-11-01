# inference-cluster-1

Bring-your-own inference cluster for the Modelplane PoC: a CPU-only minikube
cluster in a multipass VM, registered with the control cluster.

## Create the cluster

```sh
VM_NAME=inference-cluster-1 CONTEXT_NAME=inference-cluster-1 \
VM_CPUS=4 VM_MEMORY=6G VM_DISK=30G CLUSTER_CPUS=3 CLUSTER_MEMORY_MB=4096 \
./scripts/setup-control-cluster.sh
```

## BYO prerequisites (one-time, on inference-cluster-1)

```sh
# Pool labels (without them, Modelplane worker pods stay Pending and the
# CPU pool publishes no cores):
kubectl --context inference-cluster-1 label node minikube \
  modelplane.ai/pool=cpu-pool modelplane.ai/cpu=true

# A LoadBalancer implementation (the gateway needs external addresses):
multipass exec inference-cluster-1 -- sg docker -c \
  "minikube addons enable metallb"
# then apply the MetalLB address pool config (see metallb-config.yaml)
kubectl --context inference-cluster-1 apply -f metallb-config.yaml
```

## Register with the control cluster

```sh
# Kubeconfig secret: the server address must be reachable from pods on the
# control cluster, i.e. the multipass VM IP (which the setup script already
# writes into the host kubeconfig). It must live in modelplane-system —
# Modelplane's generated ProviderConfigs resolve the secretRef there.
kubectl config view --context inference-cluster-1 --minify --flatten \
  | kubectl --context modelplane create secret generic \
      inference-cluster-1-kubeconfig -n modelplane-system \
      --from-file=kubeconfig=/dev/stdin

kubectl --context modelplane apply -f inference-class.yaml
kubectl --context modelplane apply -f inference-cluster.yaml
kubectl --context modelplane wait --for=condition=Ready \
  ic/inference-cluster-1 --timeout=20m

kubectl --context modelplane apply -f inference-gateway.yaml
kubectl --context modelplane wait --for=condition=Ready ig/public --timeout=5m
kubectl --context modelplane get ig public -o jsonpath='{.status}'
```

## Notes

- The kubeconfig secret is created imperatively and is NOT committed (it
  contains cluster credentials).
- Gateway/LoadBalancer addresses come from the MetalLB pool inside the VM's
  docker network; they are reachable from inside the VM. Reaching them from
  the mac requires a port-forward or a route into the VM.
- The nodes are arm64 (Apple Silicon): model deployments must use arm64
  images (the docs' CPU recipe image `vllm/vllm-openai-cpu:*-x86_64` won't
  run here).
