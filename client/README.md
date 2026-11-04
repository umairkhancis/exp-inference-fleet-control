# Client view

What a consumer of the inference platform sees: **one OpenAI-compatible
URL and one model name — `ml-team/chat`**. Nothing here knows about
clusters, replicas, vLLM, or the Claude failover; whether the answer comes
from Qwen on the fleet or from Anthropic is invisible except by asking the
model who it is.

## 1. Bridge the gateway to localhost (once, keep running)

The gateway's LoadBalancer address (192.168.49.100) only exists inside the
multipass VM's docker network. From the mac, bridge it with a
port-forward:

```sh
./client/gateway-tunnel.sh            # inference-cluster-1 -> localhost:8080
./client/gateway-tunnel.sh inference-cluster-2 8081   # the other front door
```

A real deployment would publish the gateway address directly; the tunnel
is only PoC plumbing, not part of the client view.

## 2. Call it

Two independent clients, no shared code — pick whichever matches how
your consumers work:

```sh
# Raw curl against the API; prints the JSON response as-is:
./client/chat.sh "What is the capital of France?"
./client/chat.sh "What is the capital of France?" | jq -r .model

# Sample Python app (stdlib only, no SDK, no API key):
python3 client/chat.py "What is the capital of France?"
python3 client/chat.py --who   # ask the model to identify itself
```

Both default to `http://localhost:8080` and `ml-team/chat`; override with
`GATEWAY_URL` / `MODEL` (curl) or `--url` / `--model` (python).

## What to look for

- `model` in the response says who actually served it:
  `ml-team/qwen-cpu-demo` (fleet) vs `claude-haiku-5-5` (failover) — the
  client never asked for either.
- Kill the fleet tier (delete the engine pods) and the same commands keep
  working, answered by Claude; bring it back and traffic returns.
