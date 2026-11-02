# Glossary

One page defining every term used across this PoC and its docs. The
per-manifest explainers ([inference-class.md](inference-class.md),
[inference-cluster.md](inference-cluster.md),
[inference-gateway.md](inference-gateway.md),
[model-deployment.md](model-deployment.md),
[model-service.md](model-service.md)) go field by field; this page is the
shared vocabulary they all build on.

---

## Terms

### ML Team

The consumers of the fleet: they need models deployed and served for their
applications. They never touch clusters, nodes, or GPUs directly — they
declare *what* to run (a `ModelDeployment`) and *under which name* to call
it (a `ModelService`), and the platform decides where it lands. In this
repo their manifests live under `manifests/ml-team/`.

### Platform Team

The providers of the fleet: they provision the GPU (here: CPU) capacity
that model deployments land on. They register clusters, declare what
hardware each one offers (`InferenceClass`), and open the front door
(`InferenceGateway`). In this repo their manifests live under
`manifests/platform-team/`.

### Inference Cluster

A Kubernetes cluster with accelerator capacity (GPUs in production; CPU
devices in this PoC) whose job is to run **inference engines** — the
server processes that hold a model in memory and answer requests, such as
vLLM, SGLang, or TensorRT-LLM. Each one carries a serving stack (gateway,
endpoint picker, DRA driver, monitoring) that Modelplane installs when the
cluster is registered. Ours: `inference-cluster-1` and
`inference-cluster-2`, each a minikube inside a multipass VM.

### Control Cluster

An isolated Kubernetes cluster that runs **no models at all** — it exists
only to control the fleet of inference clusters. All intent (classes,
clusters, gateways, deployments, services) is applied here; controllers
then push the resulting workloads out to the inference clusters. Ours is
the `modelplane` context. Keeping it isolated means a busy or broken
inference cluster can never take the control plane down with it.

---

## Modelplane.ai role

### For inference clusters

Modelplane can **provision** an inference cluster for you on a managed
Kubernetes service (EKS, GKE, …) — or **adopt one you bring** ("BYO",
`source: Existing`), which is what this PoC does: we build the minikube
clusters ourselves and hand Modelplane a kubeconfig Secret so it can
install the serving stack and manage them.

### For the control cluster

Modelplane is **installed on** the control cluster (as a Crossplane
package) and from there manages the whole fleet: it watches the CRDs you
apply, schedules replicas onto inference clusters, installs/repairs each
cluster's serving stack, and reports fleet-wide status back as conditions
on those same objects.

---

## Node Pool

A named group of nodes inside one inference cluster that share the same
hardware shape. Nodes join a pool via the label `modelplane.ai/pool=<name>`
(ours: `cpu-pool`), and an `InferenceClass` describes the capacity of one
pool. This is how a single cluster can offer different hardware tiers —
e.g. an A100 pool and an H100 pool — each advertised as its own class.
Without the pool label, worker pods stay Pending and the pool publishes no
capacity (a lesson this PoC learned the hard way).

## Dynamic Resource Allocation (DRA)

The Kubernetes mechanism (stable in recent K8s, ≥1.32) for handing
specialized devices — GPUs, NICs, here CPUs via the `dra.cpu` driver — to
pods. Three moving parts:

- a **driver** on each node discovers real devices and publishes their
  capacity (on our VMs the `dra.cpu` driver reserves 2 cores for the
  system and publishes the rest);
- a workload makes a **claim**: "one device matching this filter", where
  the filter is a **CEL** expression over the device's published capacity;
- the allocator binds claim to device when the pod schedules.

The subtlety that cost us the most time: the CEL filter is evaluated
**twice, against two different numbers** — first by Modelplane's scheduler
against the capacity the `InferenceClass` *declared* (to pick a cluster),
then by the node against what the driver *really* found (to allocate). It
must pass both, so the class declaration is a promise the driver has to
keep.

---

## Model Deployment

The ML team's workload declaration: "run this model, this many times, on
hardware that looks like this." It names the engine image and arguments,
the device claim (with its CEL filter), and a replica count — and nothing
about *where*: Modelplane's scheduler picks the cluster for each replica.
Ours is `qwen-cpu-demo`, running Qwen2.5-0.5B under vLLM on CPU.

## Model Service

The stable, callable name in front of a deployment — the model's "phone
number". Callers put `<namespace>/<service>` (ours: `ml-team/qwen-cpu`) in
the `"model"` field of an OpenAI-style request; the service routes to
every matching replica via a label selector. Deployments can scale, move
between clusters, or be swapped out behind the name without breaking
callers.

## Model Replica

One complete, independent copy of the running model. You don't write
these: Modelplane creates a `ModelReplica` object per copy (`replicas: 2`
→ two of them), schedules each onto an inference cluster independently,
and tracks its placement and serving status there. Checking "where is my
model actually running?" means listing ModelReplicas and reading their
`clusterName`.

## Model Deployment Member

One pod's role *inside* a single engine. Most models fit in one pod, so
the engine has a single member with role **Standalone** (ours does). A
model too big for one machine is split across several pods — one
**Leader** plus **Workers** — and each pod is one member. So the hierarchy
is: a deployment has replicas → a replica runs engines → an engine is made
of members → a member is a pod.
