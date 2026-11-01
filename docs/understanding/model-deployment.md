# Understanding `model-deployment.yaml` (in simple language)

This explains `manifests/ml-team/qwen-cpu/model-deployment.yaml`, the
manifest that actually runs an AI model on the fleet. First a glossary, then
the file, field by field, using only those terms.

Companion docs: [model-service.md](model-service.md) (exposing the model),
and the platform-team docs ([inference-class.md](inference-class.md),
[inference-cluster.md](inference-cluster.md),
[inference-gateway.md](inference-gateway.md)).

---

## Glossary

**Control cluster / inference cluster**
The "manager" cluster where you apply this manifest, and the "worker"
clusters that run the model. Modelplane decides *which* worker cluster gets
the pods — that choice is the whole point of this file's selector.

**ModelDeployment** (this file's kind)
The ml-team's declaration: "run this model, this many times, on hardware
that looks like this." The platform team declared what hardware exists
(InferenceClass); this is the workload side asking for some of it.

**Replica**
One complete, independent copy of the running model. Two replicas means two
full copies serving traffic, possibly on different clusters.

**Engine**
The inference server process that holds the model and answers requests. Ours
is **vLLM**, a popular open-source engine that speaks the OpenAI API.

**Member / role**
One engine can be split across several pods (for models too big for one
machine): a *Leader* plus *Workers*. Our model is tiny, so one member plays
the **Standalone** role — the whole engine in a single pod.

**Device claim (workload side)**
The platform side published devices (the CPU with its cores, via the
`dra.cpu` driver). The workload side *claims* one here: `nodeSelector.devices`
is the reservation request that DRA matches against what clusters published.

**CEL (Common Expression Language)**
A small expression language Kubernetes uses for rules. Here it filters
devices: "only devices whose published capacity satisfies this test." It is
evaluated against the **InferenceClass capacity** the platform team declared
— not against what's momentarily free.

**Scheduler**
The Modelplane component that compares the claim (what the model needs)
against every cluster's published capacity (what exists) and picks where
each replica runs.

**Served model name**
The name the engine registers itself under, which the gateway uses to route
requests to it. Modelplane injects the right value via the environment
variable `MODELPLANE_SERVED_MODEL_NAME` — you never hardcode it.

**Context length (`--max-model-len`)**
The maximum number of tokens (prompt + answer) one request can span. Longer
context needs more memory, so we cap it small.

**KV cache**
The engine's working memory for conversations in flight — it grows with
context length and concurrent requests. On CPU serving, its size is set by
the env var `VLLM_CPU_KVCACHE_SPACE` (in GiB of RAM).

**Requests / limits**
Plain Kubernetes CPU/memory sizing for the pod itself. Distinct from the
device claim: the claim decides *which cluster* qualifies; requests/limits
decide how much of the chosen *node* the pod gets.

---

## The file

In one sentence: *run 1 replica of Qwen2.5-0.5B under vLLM on CPU, and only
on a cluster whose hardware class publishes at least 3 CPU cores.*

## Field by field

### `metadata.name: qwen-cpu-demo` / `namespace: ml-team`

The deployment's name, in the ml-team's **namespace on the control
cluster**. The ModelService finds this deployment's replicas through a label
Modelplane stamps with exactly this name.

### `spec.replicas: 1`

How many **replicas** (full copies) of the model to run. Scaling the model
later means raising this number — each new replica is scheduled
independently, wherever the claim can be satisfied.

### `spec.template`

The blueprint each replica is stamped from (like a Deployment's pod
template, one level up).

### `engines[0].name: qwen`

This replica runs one **engine**, locally named `qwen`. (Advanced setups can
split work across several engines — e.g. separate prefill/decode — hence a
list.)

### `members[0].role: Standalone`

The engine is one **member**: a single pod, no Leader/Worker split. Right
for a 0.5B-parameter model.

### `members[0].nodeSelector.devices`

The **device claim** — the workload side of the DRA handshake:

- **`name: cpu`** — claim the device the InferenceClass listed under this
  name.
- **`count: 1`** — one such device (the classes model the whole CPU as a
  single device).
- **`selectors[0].cel`** — the capability filter:

  ```
  device.capacity["dra.cpu"].cpu.compareTo(quantity("3")) >= 0
  ```

  "The device's published `cpu` capacity must be ≥ 3 cores." In our fleet,
  `cpu-small-byo` publishes 3 and `cpu-micro-byo` publishes 2 — so the
  **scheduler** can only place this replica on **inference-cluster-1**.
  Lowering `"3"` to `"2"` would make both clusters eligible. This one line
  is the live demonstration that the two clusters' different capabilities
  actually steer scheduling.

### `template.spec.containers[0]` — the engine container

- **`image: vllm/vllm-openai-cpu:v0.32.0`** — vLLM's CPU build. The official
  recipe pins `v0.32.0-x86_64`, which cannot run on our arm64 (Apple
  Silicon) VMs; the plain `v0.32.0` tag is multi-arch and pulls the arm64
  variant automatically.
- **`--model=Qwen/Qwen2.5-0.5B-Instruct`** — the model to download from
  Hugging Face and serve (~1 GB of weights, fetched on first start).
- **`--served-model-name=$(MODELPLANE_SERVED_MODEL_NAME)`** — registers the
  engine under the **served model name** Modelplane injects, so the gateway
  can route to it.
- **`--max-model-len=2048`** — cap the **context length** to fit the small
  VM (the recipe used 4096 on a bigger node).
- **`--block-size=32`** — how the KV cache is chunked internally; 32 is the
  recipe's CPU-friendly value.
- **`env: VLLM_CPU_KVCACHE_SPACE: "1"`** — give the **KV cache** 1 GiB of
  RAM (recipe used 4 on an 8-vCPU cloud node).
- **`resources`** — **requests/limits**: 2 cores and 2 GiB requested, capped
  at 2 cores. Why not all 3 claimable cores? Same reason the recipe leaves
  one: the node's DaemonSets (gateway, monitoring, DRA driver) need CPU too,
  and a whole-node request would starve them.

---

## How it all connects

1. The platform team's **InferenceClass** published each cluster's CPU
   capacity (3 cores vs 2).
2. This **ModelDeployment**'s CEL claim demands ≥ 3, so the **scheduler**
   places the replica on inference-cluster-1, pulls the arm64 vLLM image,
   and downloads the model weights.
3. The engine starts, registers under its injected **served model name**,
   and the gateway learns where it lives.
4. The **ModelService** (next doc) gives callers a stable name —
   `ml-team/qwen-cpu` — that routes to every replica of this deployment.
