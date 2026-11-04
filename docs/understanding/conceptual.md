# From Concern to Concept to YAML

The [glossary](glossary.md) defines each term; this page explains *why
each term exists*. Every concept in this PoC is the answer to a concrete
concern, and every concept shows up in the manifests in one of three
shapes:

- **a whole file** — the concern is big enough to be an object of its own;
- **a field** — the concern is a knob on an existing object;
- **a connection** — the concern is a relationship, expressed as one
  object referencing another (by name, by Secret, or by label selector).

Sections follow the same dependency order as the glossary: each one builds
only on concepts introduced above it.

---

## 1. Many clusters, one brain

**Concern.** Serving happens on several clusters, and that number changes.
Nobody wants to `kubectl` into each one; and if the brain ran *on* a
serving cluster, a thrashing model (we had one — load >200) could take the
brain down with it.

**Concept.** A **control cluster**: an isolated cluster that runs no
models, only intent. **Modelplane** is the controller installed there; it
watches what you apply and pushes workloads out to the serving clusters.

**In YAML.** One whole file, [`manifests/modelplane-configuration.yaml`](../../manifests/modelplane-configuration.yaml):
a Crossplane `Configuration` naming the Modelplane package. That's the
entire installation. The control cluster itself isn't a manifest — it's
*where* every manifest in this repo is applied (the `modelplane` kubectl
context).

```yaml
kind: Configuration            # Crossplane's "install this package"
spec:
  package: xpkg.upbound.io/modelplane/modelplane:v0.6.0
```

---

## 2. The brain must know a serving cluster exists

**Concern.** Modelplane can't manage a cluster it can't see. It needs to
know the cluster exists, and it needs credentials to reach it and install
the serving stack.

**Concept.** The **inference cluster** as a *registered object*: a record
on the control cluster standing for a real cluster elsewhere. Two ways to
get one — have Modelplane provision it (EKS, GKE, …) or bring your own
(BYO), which is what this PoC does with minikube-in-multipass VMs.

**In YAML.** A whole file per cluster,
[`inference-cluster.yaml`](../../manifests/platform-team/inference-cluster-1/inference-cluster.yaml).
The BYO choice is a *field*, and the credentials are a *connection* to a
Secret:

```yaml
kind: InferenceCluster
metadata:
  name: inference-cluster-1
spec:
  cluster:
    source: Existing           # field: BYO, don't provision
    existing:
      secretRef:               # connection: kubeconfig Secret on the
        name: inference-cluster-1-kubeconfig   # control cluster
        key: kubeconfig
```

The Secret is the one piece created outside YAML (`kubectl create
secret ... --from-file`), and its kubeconfig must point at an address the
control cluster's *pods* can reach — the VM's IP, not `127.0.0.1`.

---

## 3. Not all hardware is equal

**Concern.** One cluster may carry A100s and H100s; another only CPUs.
The scheduler must compare hardware *across* clusters without logging into
any node — it needs a catalog.

**Concept.** Two concepts emerge together. A **node pool** groups the
nodes of one cluster that share a hardware shape. An **inference class**
is the catalog entry: a named, declared description of what one pool's
devices offer.

**In YAML.** The pool is *not* a manifest. It is a **label on real nodes**
(`modelplane.ai/pool=cpu-pool`, applied when building the VM) plus an
entry in the cluster's `nodePools` list. The class is a whole file,
[`inference-class.yaml`](../../manifests/platform-team/inference-cluster-1/inference-class.yaml),
and `className` is the connection tying pool to class by name:

```yaml
# inference-cluster.yaml
spec:
  nodePools:
  - name: cpu-pool             # must match the node label's value
    className: cpu-small-byo   # connection: -> InferenceClass by name
    nodeCount: 1
```

```yaml
# inference-class.yaml
kind: InferenceClass
metadata:
  name: cpu-small-byo          # the name the pool points at
spec:
  devices:
  - name: cpu
    capacity:
      cpu: { value: "3" }      # field: a *declared* promise, not a measurement
```

If the node label is missing, the connection dangles silently: worker pods
stay Pending and the pool publishes no capacity — the trap this PoC walked
into.

---

## 4. A pod must actually get the device

**Concern.** Declaring capacity in a catalog is cheap talk; at some point
a real pod on a real node must be handed a real device, exclusively.

**Concept.** Kubernetes **Dynamic Resource Allocation (DRA)**: a *driver*
on each node discovers devices and publishes what it really found; a
workload states a *claim* ("one device matching this CEL filter"); the
allocator binds them at scheduling time.

**In YAML.** DRA is fields, spread across two objects. The class names the
driver; the workload (next sections) carries the claim:

```yaml
# inference-class.yaml — which driver backs this class
  - name: cpu
    claim: DRA
    driver: dra.cpu            # field: Modelplane installs this driver
    deviceClassName: dra.cpu
```

```yaml
# model-deployment.yaml — the claim
  devices:
  - name: cpu
    count: 1
    selectors:
    - cel: |                   # field: filter over published capacity
        device.capacity["dra.cpu"].cpu.compareTo(quantity("2")) >= 0
```

The costly subtlety: this one CEL expression is evaluated **twice, against
two different numbers** — against the class's *declared* capacity to pick
a cluster, then against what the driver *really* published to allocate on
the node. Our class declares 3 cores; the driver publishes 2 (it reserves
2 of the VM's 4 for the system). A `>= 3` claim picks the cluster and then
never allocates. Hence `>= 2`: the claim must pass both readings.

---

## 5. Requests need a door

**Concern.** Engines will run as pods somewhere in the fleet. Callers
cannot chase pods; they need one HTTP entry point.

**Concept.** The **inference gateway**: the fleet's front door, hosted on
a chosen cluster, publishing the endpoints callers use.

**In YAML.** A whole file,
[`inference-gateway.yaml`](../../manifests/platform-team/inference-cluster-1/inference-gateway.yaml),
whose only decision is a connection — which cluster hosts the door:

```yaml
kind: InferenceGateway
metadata:
  name: public
spec:
  clusterName: inference-cluster-1   # connection: -> InferenceCluster by name
```

The usable URLs appear in this object's `status`, written back by
Modelplane once the gateway is up.

---

## 6. Two groups, two kinds of intent

**Concern.** The people providing capacity and the people consuming it are
different teams with different vocabularies. Their changes shouldn't
collide, and consumers should never have to know about nodes or drivers.

**Concept.** The **platform team** owns everything above this line
(clusters, classes, gateways); the **ML team** owns only "what model,
under what name" — the objects below.

**In YAML.** A directory split and a namespace. Platform intent lives in
[`manifests/platform-team/`](../../manifests/platform-team/), ML intent in
[`manifests/ml-team/`](../../manifests/ml-team/), fenced by a whole file —
[`namespace.yaml`](../../manifests/ml-team/namespace.yaml) — and a field
on every ML object:

```yaml
kind: ModelDeployment
metadata:
  name: qwen-cpu-demo
  namespace: ml-team           # field: this is ML-team intent
```

Note the namespace exists on the *control* cluster: it scopes intent, not
pods. The engine pods land wherever Modelplane schedules them.

---

## 7. "Run this model, N times" — and nothing about where

**Concern.** The ML team wants replicas of a model running on suitable
hardware. The moment they name a cluster or node, the fleet abstraction is
broken and every hardware change becomes their problem.

**Concept.** The **model deployment**: a declaration of *what* (engine
image and arguments), *how many* (**replicas**), and *on what kind of
hardware* (the DRA claim from §4) — with *where* deliberately absent.

**In YAML.** A whole file,
[`model-deployment.yaml`](../../manifests/ml-team/qwen-cpu/model-deployment.yaml).
Its shape mirrors the concept: there is no cluster field to write.

```yaml
kind: ModelDeployment
metadata:
  name: qwen-cpu-demo
  namespace: ml-team
spec:
  replicas: 1                  # field: how many copies
  template:
    spec:
      engines:
      - name: qwen
        members:
        - role: Standalone     # field: fits in one pod (no Leader/Workers)
          nodeSelector:
            devices: [...]     # the CEL claim — the only hardware statement
          template:
            spec:
              containers:
              - name: engine   # the inference engine itself: vLLM
                image: vllm/vllm-openai-cpu:v0.33.0
                args: [--model=Qwen/Qwen2.5-0.5B-Instruct, ...]
```

This is also where the **inference engine** concept surfaces in YAML: not
as its own object but as the `containers` block of a member — an ordinary
pod spec, so all the usual knobs (env, probes, resource requests) apply.

---

## 8. Callers need a name that outlives the pods

**Concern.** Deployments scale, move between clusters, get replaced by a
new version. If callers address a deployment directly, every one of those
events breaks them.

**Concept.** The **model service**: a stable, callable name — the model's
"phone number" — decoupled from whichever deployment currently answers it.

**In YAML.** A whole file,
[`model-service.yaml`](../../manifests/ml-team/qwen-cpu/model-service.yaml).
Two things to notice. The caller-visible name isn't a field at all — it is
*derived* from metadata: `<namespace>/<name>` → `ml-team/qwen-cpu`, the
string callers put in the `"model"` field of an OpenAI-style request. And
the link to the deployment is a connection — by **label selector**, not by
name, which is exactly what lets the target be swapped:

```yaml
kind: ModelService
metadata:
  name: qwen-cpu               # callers say: "model": "ml-team/qwen-cpu"
  namespace: ml-team
spec:
  endpoints:
  - name: qwen-cpu-demo
    selector:
      matchLabels:             # connection: -> whatever replicas carry
        modelplane.ai/deployment: qwen-cpu-demo   # this label
```

---

## 9. "Where is my model actually running?"

**Concern.** The deployment says `replicas: 1` and nothing about place —
by design. But when something is slow or down, somebody has to find the
actual copies and their state.

**Concept.** The **model replica**: one complete running copy, as an
object Modelplane *creates for you* — one per copy, each independently
placed. Inside a replica, each pod of an engine is a **member**
(Standalone, or Leader + Workers for models too big for one machine). The
hierarchy: deployment → replicas → engines → members → pods.

**In YAML.** The only concept here you never write. There is no
`model-replica.yaml` in this repo; replicas exist purely as API objects to
*read*, and the placement answer is a status field:

```console
$ kubectl --context modelplane get modelreplicas -n ml-team
NAME               CLUSTER               ...
qwen-cpu-demo-0    inference-cluster-1   # <- the "where"
```

---

## Summary: concept → YAML shape

| Concept            | Shape in YAML                                                        |
| ------------------ | -------------------------------------------------------------------- |
| Control cluster    | not an object — the kubectl context everything is applied to          |
| Modelplane         | whole file (`modelplane-configuration.yaml`)                          |
| Inference cluster  | whole file; BYO is a field; credentials a Secret reference            |
| Node pool          | a node **label** + a `nodePools` entry (field)                        |
| Inference class    | whole file; connected from the pool via `className`                   |
| DRA                | fields: `driver` in the class, `selectors.cel` claim in the workload  |
| Inference gateway  | whole file; `clusterName` connects it to its host cluster             |
| Teams              | directory split + `namespace` field                                   |
| Model deployment   | whole file; `replicas` field; *no* placement field, by design         |
| Inference engine   | a `containers` block inside a deployment member (field)               |
| Model service      | whole file; name derived from metadata; label-selector connection     |
| Model replica      | never written — created by Modelplane, read for placement/status      |
