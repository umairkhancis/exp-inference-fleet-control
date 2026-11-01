# Understanding `inference-cluster.yaml` (in simple language)

This explains `manifests/platform-team/inference-cluster-1/inference-cluster.yaml`, the
manifest that registers our bring-your-own worker cluster with Modelplane.
First a glossary of the terms involved, then the file itself, field by field,
using only those terms.

Companion doc: [inference-class.md](inference-class.md) explains the hardware
profile this file points at.

---

## Glossary

**Control cluster**
The "manager" Kubernetes cluster where Modelplane runs. You apply manifests
like this one *here*. It doesn't run the AI models itself — it manages the
clusters that do.

**Inference cluster**
A "worker" Kubernetes cluster that actually runs the AI models. In this
project it is `inference-cluster-1`: a minikube cluster inside a multipass VM
on your Mac.

**BYO (bring-your-own)**
A cluster *you* created yourself, instead of letting Modelplane create one in
the cloud. Modelplane doesn't build it; it just connects to it and uses it.

**InferenceCluster** (this file's kind)
The Modelplane resource that **registers** a worker cluster with the control
cluster: "here is a cluster, here is how to connect to it, and here is what
hardware it has." Registering is like adding a contact — Modelplane learns
the cluster exists and how to reach it.

**Kubeconfig**
The "address book + key" file for a Kubernetes cluster: it contains the
cluster's address and the credentials to log in. Anyone holding it can talk
to the cluster, which is why it must never be committed to git.

**Secret**
A Kubernetes object for storing sensitive data (passwords, keys,
kubeconfigs). We put the worker cluster's kubeconfig into a Secret on the
control cluster — created by hand with `kubectl` (see the README), not from a
file in this repo. The InferenceCluster CRD requires it to live in the
`modelplane-system` namespace.

**secretRef**
A pointer *to* a Secret: "look up the Secret with this name, and read this
key inside it." It lets a manifest use a credential without containing it.

**Label**
A small `key=value` tag you stick on a Kubernetes object so other things can
find or group it. Labels carry no behavior by themselves — something has to
look for them.

**Node pool**
A named group of similar nodes inside a cluster. Ours is `cpu-pool`, with one
node.

**InferenceClass**
A Modelplane **hardware profile**: a named description of what kind of node a
pool contains (which devices, how many cores). Defined in
`inference-class.yaml` as `cpu-small-byo`; this file references it by name.

**Region**
A location tag for a cluster (like `us-east-1` in the cloud). Ours is the
made-up value `local`, because the cluster lives on your Mac, not in any
cloud region.

**Provisioned vs. Existing**
The two ways Modelplane can get a cluster: *provisioned* means "Modelplane,
go create one in the cloud"; *Existing* means "I already have one (BYO) —
here are the keys." This file uses Existing.

---

## The file

```yaml
apiVersion: modelplane.ai/v1alpha1
kind: InferenceCluster
metadata:
  name: inference-cluster-1
  labels:
    modelplane.ai/region: local
spec:
  cluster:
    source: Existing
    existing:
      secretRef:
        name: inference-cluster-1-kubeconfig
        key: kubeconfig
  nodePools:
  - name: cpu-pool
    className: cpu-small-byo
    nodeCount: 1
```

In one sentence: *this file tells Modelplane "there is an existing cluster
called inference-cluster-1 — connect to it using the kubeconfig stored in
this Secret, and treat its one node as a CPU pool matching the
`cpu-small-byo` hardware profile."*

## Field by field

### `apiVersion: modelplane.ai/v1alpha1`

Which API this file speaks. `modelplane.ai` is Modelplane's API group, and
`v1alpha1` means it's an early, still-changing version of that API.

### `kind: InferenceCluster`

What this object is: an **InferenceCluster** — the registration of a worker
cluster (see glossary). Like the InferenceClass, it gets applied to the
**control cluster**.

### `metadata.name: inference-cluster-1`

The name Modelplane knows this cluster by. It matches the multipass VM name
and the kubectl context name, which keeps the whole setup easy to follow —
but that matching is a convention, not a requirement.

### `metadata.labels` → `modelplane.ai/region: local`

A **label** tagging the cluster with its **region**. Cloud clusters would
carry a real region here (so Modelplane can route work to the right
geography); ours says `local` because the cluster runs on your Mac. It's just
a tag — nothing breaks without it, but things that filter clusters by region
use it.

### `spec.cluster`

The "how do I get this cluster?" section. It answers two questions: where
does the cluster come from, and how do I connect to it?

### `spec.cluster.source: Existing`

Where the cluster comes from: it's **Existing** — the **BYO** case. This
tells Modelplane *not* to create anything, just to connect to a cluster that
is already running. (The alternative would be a provisioned cluster, where
Modelplane creates the machines itself — see **Provisioned vs. Existing**.)
This is the counterpart of the missing provisioning block in
`inference-class.yaml`: neither file asks Modelplane to build hardware.

### `spec.cluster.existing.secretRef`

Because the cluster already exists, Modelplane needs its keys. This
**secretRef** points at the **Secret** that holds the **kubeconfig**:

- **`name: inference-cluster-1-kubeconfig`** — the Secret to look up. The
  README creates it by hand in the `crossplane-system` namespace, piping the
  kubeconfig straight from `kubectl config view`. It is deliberately *not*
  committed to the repo, because it contains credentials.
- **`key: kubeconfig`** — which entry inside the Secret holds the file (a
  Secret is a small key→value map; this says "read the value under
  `kubeconfig`").

One important catch from the README: the address inside that kubeconfig must
be one the control cluster's pods can actually reach — the multipass VM's IP,
not `127.0.0.1` (which would point each pod at *itself*).

### `spec.nodePools`

The list of **node pools** this cluster offers to Modelplane. Each pool says
"I have N nodes of this hardware profile." Ours has a single pool.

### `nodePools[0].name: cpu-pool`

The pool's name. This matters beyond this file: the README has you label the
minikube node with `modelplane.ai/pool=cpu-pool` — that **label** is how the
node declares "I belong to this pool." Without it, Modelplane's worker pods
stay Pending and the pool publishes no CPU cores.

### `nodePools[0].className: cpu-small-byo`

Which **InferenceClass** (hardware profile) the pool's nodes match: the
`cpu-small-byo` profile from `inference-class.yaml` — one claimable CPU
device with 3 cores, no GPU. This is the link between the two files: the
class *describes* the hardware, and this field says "my nodes are that."

### `nodePools[0].nodeCount: 1`

How many nodes the pool has: **one** (the single minikube node in the VM).
For a BYO cluster this is a statement of fact — the node already exists —
not an instruction to create nodes.

---

## How it all connects

1. You create the **kubeconfig Secret** on the **control cluster** by hand
   (it holds credentials, so it never goes in git).
2. You apply the **InferenceClass** (`cpu-small-byo`) — the hardware profile.
3. You apply this **InferenceCluster**. Modelplane reads the kubeconfig via
   the **secretRef**, connects to the **BYO** worker cluster, and installs
   its components there (including the `dra.cpu` driver).
4. The node's `modelplane.ai/pool=cpu-pool` **label** ties it to the
   `cpu-pool` **node pool**, whose `className` ties it to the hardware
   profile — and the pool starts publishing its 3 CPU cores.
5. Once the InferenceCluster reports Ready (the README waits for this with
   `kubectl wait`), the gateway can be applied and models can be deployed
   onto the pool.
