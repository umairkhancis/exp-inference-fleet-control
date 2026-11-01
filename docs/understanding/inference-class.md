# Understanding `inference-class.yaml` (in simple language)

This explains `manifests/inference-cluster-1/inference-class.yaml`, one small
piece of the Modelplane setup. First a glossary of the terms involved, then
the file itself, field by field, using only those terms.

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

**Multipass VM**
A lightweight Ubuntu virtual machine running on your Mac (created with the
`multipass` tool). Our inference cluster lives inside one of these.

**vCPU / core**
One unit of processing power. Our VM has 4 vCPUs, but one is kept aside for
the operating system and Kubernetes' own background work (the *kubelet*), so
only 3 are available for models.

**Device**
Any piece of hardware a workload might want to reserve: a GPU, or — in our
case — the CPU itself, treated as reservable hardware.

**Claim**
The act of a workload saying "I need this device" and getting it reserved
exclusively for itself (like booking a seat).

**DRA (Dynamic Resource Allocation)**
Kubernetes' modern, structured system for claiming devices. Instead of the
old way ("give me 2 CPUs" as a number in the pod spec), a workload files a
formal reservation request (a *ResourceClaim*) and a *driver* fulfills it.
Needs Kubernetes 1.36 or newer here.

**DRA driver**
The software component that owns a type of device and hands it out when
claims come in. Think of it as the booking agent for that hardware. Ours is
called `dra.cpu`, and Modelplane installs it on the inference cluster
automatically.

**DeviceClass**
A Kubernetes object (on the inference cluster) that names a *category* of
devices a claim can ask for — like the "seat category" you book. Ours is also
named `dra.cpu`.

**InferenceClass** (this file's kind)
A Modelplane resource that is a **hardware profile**: a named description of
what kind of node a cluster offers (which devices, how many, how big). It
creates nothing by itself — other resources point at it by name.

**InferenceCluster**
The Modelplane resource (in `inference-cluster.yaml`) that registers a worker
cluster with the control cluster. Its node pools reference an InferenceClass
by name to say what hardware they contain.

**Node pool**
A named group of similar nodes inside a cluster. Ours is `cpu-pool`, with one
node.

**Provisioning block**
The part of an InferenceClass that would tell Modelplane "create this machine
in the cloud for me." Our file *omits* it on purpose: the hardware is BYO —
it already exists, so the class only *describes* it.

---

## The file

```yaml
apiVersion: modelplane.ai/v1alpha1
kind: InferenceClass
metadata:
  name: cpu-small-byo
spec:
  description: "Multipass VM, 4 vCPUs, no GPU (3 usable cores after OS/kubelet reserve)"
  devices:
  - name: cpu
    claim: DRA
    driver: dra.cpu
    deviceClassName: dra.cpu
    count: 1
    capacity:
      cpu: { value: "3" }
```

In one sentence: *this file is a hardware profile that tells Modelplane
"nodes of this class have one claimable CPU device with 3 cores, handed out
through DRA."*

## Field by field

### `apiVersion: modelplane.ai/v1alpha1`

Which API this file speaks. `modelplane.ai` is Modelplane's API group, and
`v1alpha1` means it's an early, still-changing version of that API.

### `kind: InferenceClass`

What this object is: an **InferenceClass** — a hardware profile (see
glossary). It gets applied to the **control cluster**.

### `metadata.name: cpu-small-byo`

The profile's name. Other resources find it by this name: in
`inference-cluster.yaml`, the `cpu-pool` **node pool** says
`className: cpu-small-byo`, meaning "my nodes look like this profile."
The name itself is just a readable convention: **cpu** (no GPU), **small**
(3 cores), **byo** (bring-your-own).

### `spec.description`

A plain-English note for humans; Modelplane ignores it. It records that the
node is a **multipass VM** with 4 **vCPUs** and no GPU, of which only 3 are
usable (one is reserved for the OS and kubelet).

### `spec.devices`

The list of **devices** a node of this profile offers for **claiming**.
There's exactly one entry: the CPU. (A GPU profile would list GPU entries
here instead.)

### `devices[0].name: cpu`

A label for this device entry, so other places can refer to "the `cpu`
device of this class."

### `devices[0].claim: DRA`

*How* workloads get this device: through **DRA** — the formal
reservation-request system — rather than the old plain-numbers way. This is
why the file's header comment says the inference cluster needs
Kubernetes ≥ 1.36.

### `devices[0].driver: dra.cpu`

*Who* hands the device out: the **DRA driver** named `dra.cpu` (the "booking
agent" for CPU cores). Modelplane installs it on the inference cluster for
you — nothing to set up by hand.

### `devices[0].deviceClassName: dra.cpu`

*What category* reservation requests ask for: the **DeviceClass** named
`dra.cpu`. It happens to share a name with the driver, but they are different
things — the driver is the agent, the DeviceClass is the category on the
booking form.

### `devices[0].count: 1`

How many such devices each node has: **one**. The whole CPU is modeled as a
single reservable device (whose size comes next), not as three separate
one-core devices.

### `devices[0].capacity.cpu: { value: "3" }`

How big that one device is: **3 cores** — the usable budget after the
OS/kubelet reserve on the 4-vCPU VM. The `"3"` is quoted because Kubernetes
quantities are written as strings. One catch from the README: these cores
only actually show up once the node has the labels
`modelplane.ai/pool=cpu-pool` and `modelplane.ai/cpu=true`.

---

## How it all connects

1. You apply this **InferenceClass** to the **control cluster**. It defines
   the profile `cpu-small-byo` — and has no **provisioning block**, because
   the hardware is **BYO** and already exists.
2. The **InferenceCluster** (`inference-cluster.yaml`) registers the worker
   cluster and says its `cpu-pool` **node pool** (1 node) matches this
   profile.
3. Modelplane installs the `dra.cpu` **DRA driver** on the inference cluster,
   which advertises one CPU **device** with 3 **cores** on the labeled node.
4. When a model is deployed to that pool, it **claims** CPU through **DRA**,
   against the `dra.cpu` **DeviceClass**, up to the 3-core capacity.
