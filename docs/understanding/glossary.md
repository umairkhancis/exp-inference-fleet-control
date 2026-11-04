# Glossary

One page defining every term used across this PoC and its docs, in
dependency order: each entry builds only on entries above it, so it reads
top to bottom. The per-manifest explainers
([inference-class.md](inference-class.md),
[inference-cluster.md](inference-cluster.md),
[inference-gateway.md](inference-gateway.md),
[model-deployment.md](model-deployment.md),
[model-service.md](model-service.md)) go field by field; this page is the
shared vocabulary they all build on.

---

## Serving infrastructure

### Inference Engine

The server process that holds a model in memory and answers requests —
vLLM, SGLang, or TensorRT-LLM. Everything else in this glossary exists to
get engines running on the right hardware and traffic flowing to them.

### Inference Cluster

A Kubernetes cluster with accelerator capacity (GPUs in production; CPU
devices in this PoC) whose job is to run inference engines. Ours:
`inference-cluster-1`, a minikube inside a multipass VM. (The fleet ran a
second one until 2026-11-04; registering more is
`scripts/add-inference-cluster.sh`.)

### Node Pool

A named group of nodes inside one inference cluster that share the same
hardware shape. Nodes join a pool via the label `modelplane.ai/pool=<name>`
(ours: `cpu-pool`). Pools are how a single cluster offers different
hardware tiers — e.g. an A100 pool and an H100 pool. Without the pool
label, worker pods stay Pending and the pool publishes no capacity (a
lesson this PoC learned the hard way).

### Dynamic Resource Allocation (DRA)

The Kubernetes mechanism (stable in recent K8s, ≥1.32) for handing
specialized devices — GPUs, NICs, here CPUs via the `dra.cpu` driver — to
pods. Three moving parts:

- a **driver** on each node discovers real devices and publishes their
  capacity (on our VMs the `dra.cpu` driver reserves 2 cores for the
  system and publishes the rest);
- a workload makes a **claim**: "one device matching this filter", where
  the filter is a **CEL** expression over the device's published capacity;
- the allocator binds claim to device when the pod schedules.

### Inference Class

The declared capacity of one node pool: a named promise that "this pool
offers devices that look like this". Workload claims are matched against
classes to decide which cluster a workload can land on.

The subtlety that cost us the most time: a claim's CEL filter is evaluated
**twice, against two different numbers** — first against the capacity the
class *declared* (to pick a cluster), then on the node against what the
DRA driver *really* found (to allocate). It must pass both, so the class
declaration is a promise the driver has to keep.

### Inference Gateway

The front door of an inference cluster: the HTTP entry point that receives
OpenAI-style requests and routes them to the engines running inside.

---

## Control plane

### Control Cluster

An isolated Kubernetes cluster that runs **no models at all** — it exists
only to control the fleet of inference clusters. Every manifest in this
PoC is applied here; controllers then push the resulting workloads out to
the inference clusters. Ours is the `modelplane` context. Keeping it
isolated means a busy or broken inference cluster can never take the
control plane down with it.

### Modelplane

The fleet controller, installed on the control cluster as a Crossplane
package. It watches the manifests you apply, picks an inference cluster
for each workload, and reports fleet-wide status back as conditions on
those same objects.

It gets inference clusters in one of two ways: it can **provision** one on
a managed Kubernetes service (EKS, GKE, …), or **adopt one you bring**
("BYO", `source: Existing`) — what this PoC does: we build the minikube
clusters ourselves and hand Modelplane a kubeconfig Secret. Either way,
on every registered cluster it installs and repairs the **serving stack**:
inference gateway, endpoint picker, DRA driver, monitoring.

---

## Teams

### Platform Team

The providers of the fleet: they provision the GPU (here: CPU) capacity
that workloads land on. They register inference clusters, declare what
hardware each one offers (`InferenceClass`), and open the front door
(`InferenceGateway`). In this repo their manifests live under
`manifests/platform-team/`.

### ML Team

The consumers of the fleet: they need models deployed and served for their
applications. They never touch clusters, nodes, or GPUs directly — they
declare *what* to run and *under which name* to call it (the two manifests
defined next), and the platform decides where it lands. In this repo their
manifests live under `manifests/ml-team/`.

---

## Workload objects

### Model Deployment

The ML team's workload declaration: "run this model, this many times, on
hardware that looks like this." It names the engine image and arguments,
the device claim (with its CEL filter), and how many copies to run (the
**replica** count) — and nothing about *where*: Modelplane picks the
cluster for each replica. Ours is `qwen-cpu-demo`, running Qwen2.5-0.5B
under vLLM on CPU.

### Model Service

The stable, callable name in front of a deployment — the model's "phone
number". Callers put `<namespace>/<service>` (ours: `ml-team/qwen-cpu`) in
the `"model"` field of an OpenAI-style request; the service routes to
every matching replica via a label selector. Deployments can scale, move
between clusters, or be swapped out behind the name without breaking
callers.

### Model Replica

One complete, independent copy of the running model. You don't write
these: Modelplane creates a `ModelReplica` object per copy (`replicas: 2`
→ two of them), schedules each onto an inference cluster independently,
and tracks its placement and serving status there. Checking "where is my
model actually running?" means listing ModelReplicas and reading their
`clusterName`.

### Model Deployment Member

One pod's role *inside* a single engine. Most models fit in one pod, so
the engine has a single member with role **Standalone** (ours does). A
model too big for one machine is split across several pods — one
**Leader** plus **Workers** — and each pod is one member. So the hierarchy
is: a deployment has replicas → a replica runs engines → an engine is made
of members → a member is a pod.
