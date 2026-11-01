# qwen-cpu

Qwen2.5-0.5B-Instruct served by vLLM on CPU — the fleet's first model.
Adapted from the official `qwen2.5-0.5b-cpu` recipe for this PoC
(arm64-capable image, smaller sizing, and a capability selector that pins it
to the 3-core cluster).

## Deploy

```sh
kubectl --context modelplane apply -f ../namespace.yaml
kubectl --context modelplane apply -f model-deployment.yaml
kubectl --context modelplane apply -f model-service.yaml

# Watch until REPLICAS shows 1/1 (first start pulls the ~2GB engine image
# and downloads ~1GB of model weights, so allow several minutes):
kubectl --context modelplane get md -n ml-team --watch

# Which cluster did the scheduler pick? (must be inference-cluster-1 —
# the CEL selector demands >= 3 cores and cluster-2 only has 2)
kubectl --context modelplane get modelreplica -n ml-team
```

## Test

The gateway address only exists inside the VM, so test from there:

```sh
ADDRESS=$(kubectl --context modelplane get ig public -o jsonpath='{.status.endpoints.openAI}')
multipass exec inference-cluster-1 -- curl -s "$ADDRESS/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"ml-team/qwen-cpu","messages":[{"role":"user","content":"What is Kubernetes in one sentence?"}],"max_tokens":60}'
```

## Notes

- The model name callers use is `ml-team/qwen-cpu` (namespace/service).
- Expect modest speed: ~0.5B parameters on 2 CPU cores.
- To let the model also run on inference-cluster-2, lower the CEL quantity
  in model-deployment.yaml from "3" to "2" — then scale `replicas: 2` and
  watch the second replica land on the smaller cluster.
