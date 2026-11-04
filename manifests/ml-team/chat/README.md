# ml-team/chat — one model name, fleet first, Claude as failover

Phase 03: callers send OpenAI-style requests with `"model": "ml-team/chat"`
to the fleet gateway. While a qwen replica is healthy on
inference-cluster-1 it serves; when none is (still pulling, crashed,
scaled to zero), the same requests are served by Claude via Anthropic's
API. Callers never see which tier answered.

| File | What it is |
|---|---|
| `model-service.yaml` | The name `ml-team/chat`: tier 0 = qwen replicas, tier 1 = Claude |
| `model-endpoint-claude.yaml` | Hand-written external ModelEndpoint for Anthropic |

The fleet tier is backed by `../qwen-cpu/model-deployment.yaml` with
`replicas: 1`. (It ran with 2 — one per cluster — until inference-cluster-2
was retired on 2026-11-04; its 8G VM couldn't hold vLLM plus the control
plane, and the Claude tier makes a second replica optional.)

## Setup (control cluster)

```sh
# 1. API-key Secret (imperative, NOT committed; key name "apiKey" is the
#    ModelEndpoint default). Must live in the SAME namespace as the
#    ModelEndpoint:
kubectl --context modelplane -n ml-team create secret generic \
  anthropic-api-key --from-literal=apiKey="$ANTHROPIC_API_KEY"

# 2. Endpoint + service + the 2-replica deployment:
kubectl --context modelplane apply -f model-endpoint-claude.yaml
kubectl --context modelplane apply -f model-service.yaml
kubectl --context modelplane apply -f ../qwen-cpu/model-deployment.yaml
```

## Verify

```sh
# Where did the replicas land?
kubectl --context modelplane get modelreplicas -n ml-team \
  -o custom-columns=NAME:.metadata.name,CLUSTER:.status.clusterName

# Ask from inside a fleet VM (gateway IPs live on the VMs' docker network):
multipass exec inference-cluster-1 -- curl -s http://192.168.49.100/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"ml-team/chat","messages":[{"role":"user","content":"Which model are you?"}],"max_tokens":40}'
```

- **Fallback path**: with no qwen replica serving (e.g. engines still
  pulling images after first apply), the answer comes from Claude —
  same request, same model name.
- **Fleet path**: once replicas are Ready, the same request is answered
  locally by Qwen2.5-0.5B.

## Notes

- `ml-team/qwen-cpu` (the phase-02 service) still exists and routes only
  to the fleet, with no fallback — useful for telling the tiers apart
  while testing.
- The response's `model` field is rewritten per backend, so the only
  honest way to detect the serving tier from outside is asking the model
  itself, or reading the gateway's access logs.
