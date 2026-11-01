# inference-cluster-2

Second bring-your-own inference cluster: an identical multipass/minikube VM
to inference-cluster-1, with **one deliberate difference** — its
InferenceClass (`cpu-micro-byo`) publishes **2 claimable cores instead of 3**
(`cpu-small-byo`). This proves two fleet clusters can expose different
capabilities on identical infrastructure.

Its gateway is named `public-2` (gateway names are unique on the control
cluster).

## Bring it up (one command)

```sh
./scripts/add-inference-cluster.sh inference-cluster-2
```

The script does everything in inference-cluster-1's README: VM + minikube,
pool labels, MetalLB, kubeconfig Secret, class/cluster/gateway registration,
Ready waits, and a gateway smoke test.

## Prove the capability difference

```sh
kubectl --context modelplane get ic \
  -o custom-columns='CLUSTER:.metadata.name,CLASS:.spec.nodePools[0].className,CPU:.status.schedulablePools[0].devices[0].capacity.cpu.value'
```

Expected:

```
CLUSTER               CLASS           CPU
inference-cluster-1   cpu-small-byo   3
inference-cluster-2   cpu-micro-byo   2
```

## Notes

- Same caveats as inference-cluster-1: arm64 node (Apple Silicon), gateway
  endpoints are plain HTTP without auth and only reachable from inside the
  VM, kubeconfig Secret is created imperatively and never committed.
