# Understanding `model-service.yaml` (in simple language)

This explains `manifests/ml-team/qwen-cpu/model-service.yaml`, the manifest
that gives the deployed model a stable, callable name. Glossary first, then
the file field by field.

Companion doc: [model-deployment.md](model-deployment.md) (running the
model this service exposes).

---

## Glossary

**ModelService** (this file's kind)
The "phone number" for a model: a stable name callers use, decoupled from
the replicas actually running. Deployments can scale, move between
clusters, or be replaced — the service name stays the same.

**Model name (`<namespace>/<service>`)**
What callers put in the `"model"` field of an OpenAI-style request. It is
the service's namespace and name joined with a slash: ours is
**`ml-team/qwen-cpu`**. Note it names the *service*, not the deployment.

**ModelEndpoint**
A record of one reachable, running replica. You don't write these —
Modelplane creates one per replica automatically and labels it with the
deployment it belongs to. (The same kind of object can also be written by
hand to route to an *external* provider — an API outside the fleet.)

**Label selector**
The standard Kubernetes "find things by tag" mechanism: "give me every
object carrying this label." This is how the service finds its endpoints
without naming them one by one.

**Endpoint group (`endpoints[]` entry)**
One pool of replicas behind the service, with optional `weight` (traffic
share) and `priority` (failover order). With several groups you can split
traffic — e.g. 90% to the stable deployment, 10% to a canary — under one
model name.

---

## The file

In one sentence: *callers asking for `ml-team/qwen-cpu` are routed to every
replica of the `qwen-cpu-demo` deployment, wherever in the fleet they run.*

## Field by field

### `metadata.name: qwen-cpu` / `namespace: ml-team`

Together these form the **model name** callers use: `ml-team/qwen-cpu`.
Keeping it separate from the deployment's name (`qwen-cpu-demo`) is what
lets you later swap the deployment behind the name without breaking
callers.

### `spec.endpoints`

The list of **endpoint groups** behind this name. We have one group, so no
`weight`/`priority` needed — all traffic goes to it.

### `endpoints[0].name: qwen-cpu-demo`

A label for this group (conventionally the deployment it fronts).

### `endpoints[0].selector.matchLabels` → `modelplane.ai/deployment: qwen-cpu-demo`

The **label selector** that does the real work: it matches every
**ModelEndpoint** Modelplane created for replicas of the `qwen-cpu-demo`
deployment. Scale the deployment to 2 replicas and the second endpoint is
picked up automatically — nothing to edit here.

---

## How it all connects

1. The **ModelDeployment** runs replicas; Modelplane creates a
   **ModelEndpoint** per replica, labeled
   `modelplane.ai/deployment: qwen-cpu-demo`.
2. This **ModelService** selects those endpoints by label and binds them to
   the name `ml-team/qwen-cpu`.
3. The fleet's **InferenceGateway** (`public`) accepts an OpenAI-style
   request with `"model": "ml-team/qwen-cpu"` and routes it to one of the
   selected replicas:

   ```sh
   curl http://192.168.49.100/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model":"ml-team/qwen-cpu","messages":[{"role":"user","content":"hi"}]}'
   ```

   (From inside the VM — the address is on the VM's private network.)
