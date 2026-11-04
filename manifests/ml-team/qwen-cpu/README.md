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

# Which cluster did the scheduler pick? (inference-cluster-1 — the
# fleet's only registered cluster since 2026-11-04)
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
- To spread the model across more clusters, register another
  InferenceCluster whose class passes the CEL selector in
  model-deployment.yaml, then raise `replicas` — one replica lands per
  cluster (each node publishes a single dra.cpu device). The fleet ran
  this way on a second cluster until 2026-11-04, when it was retired:
  its 8G VM couldn't hold vLLM plus the control plane without chronic
  leader-election crash loops, and the Claude failover on `ml-team/chat`
  covers a single-replica fleet anyway.
