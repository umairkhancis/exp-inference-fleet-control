# Understanding `inference-gateway.yaml` (in simple language)

This explains `manifests/platform-team/inference-cluster-1/inference-gateway.yaml`, the
manifest that gives the fleet a **front door** for inference requests. First
a glossary of the terms involved, then the file itself, field by field, using
only those terms.

Companion docs: [inference-class.md](inference-class.md) (the hardware
profile) and [inference-cluster.md](inference-cluster.md) (registering the
worker cluster).

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

**Inference request**
A client asking a deployed model a question — e.g. an HTTP call to an
OpenAI-style endpoint like `POST /v1/completions`.

**InferenceGateway** (this file's kind)
The Modelplane resource that creates the fleet's **front door**: one entry
point that receives inference requests and routes each one to the right
model running behind it. Clients talk to the gateway, not to individual
model pods.

**Endpoint**
A concrete address clients can call — scheme + IP + port, like
`http://192.168.49.100:80`. The gateway publishes its endpoints in its
**status** once they exist.

**Status**
The "current state" section Kubernetes attaches to an object. You wrote the
`spec` (what you want); the system fills in the `status` (what actually
happened). The README reads the gateway's endpoints with
`kubectl get ig public -o jsonpath='{.status}'`.

**LoadBalancer service**
The standard Kubernetes way to give something a stable, externally reachable
IP address. Kubernetes itself doesn't invent these IPs — *something* on the
cluster must hand them out. In the cloud, the cloud provider does it; on our
local minikube, **MetalLB** does.

**MetalLB**
A small add-on that plays the cloud provider's role on local clusters: it
owns a pool of IP addresses and assigns them to LoadBalancer services. Ours
hands out `192.168.49.100–120` (see `metallb-config.yaml`) — addresses inside
the VM's docker network, so they're reachable from *inside the VM*, and from
your Mac only via a port-forward or a route into the VM.

**TLS**
The encryption layer that makes `http` into `https`. Without it, traffic
travels as readable plain text.

**Auth (authentication)**
Checking *who* is calling — API keys, tokens, etc. Without it, anyone who
can reach the endpoint can use the models.

**PoC (proof of concept)**
A deliberately minimal setup built to show the idea works, cutting corners
(like skipping TLS and auth) that a real deployment must not cut.

---

## The file

```yaml
apiVersion: modelplane.ai/v1alpha1
kind: InferenceGateway
metadata:
  name: public
spec:
  clusterName: inference-cluster-1
```

In one sentence: *this file tells Modelplane "stand up the fleet's front door
on inference-cluster-1 and publish its addresses in the status."*

It is the shortest of the three manifests because almost everything is
defaulted: the only decision it records is *which cluster hosts the gateway*.

## Field by field

### The header comment (lines 1–3)

Not a field, but the most important part of the file: it warns that this is a
**PoC** gateway — **no TLS, no auth** — so the **endpoints** it publishes are
plain `http://` and completely open. Anyone who can reach them can call the
models. That's fine while they're only reachable inside the VM on your Mac;
it means **do not** expose them any further in this form.

### `apiVersion: modelplane.ai/v1alpha1`

Which API this file speaks. `modelplane.ai` is Modelplane's API group, and
`v1alpha1` means it's an early, still-changing version of that API — the
same group and version as the other two manifests.

### `kind: InferenceGateway`

What this object is: an **InferenceGateway** — the front door (see glossary).
Like the other two, it's applied to the **control cluster**; the gateway's
actual workload then runs on the worker cluster it names.

### `metadata.name: public`

The gateway's name. `public` describes its role — the externally facing entry
point — and it's the handle the README uses to wait on it and read its
addresses (`kubectl wait --for=condition=Ready ig/public`, then
`kubectl get ig public -o jsonpath='{.status}'`). Note `ig` is the short
alias for InferenceGateway, like `ic` for InferenceCluster.

### `spec.clusterName: inference-cluster-1`

The only spec field: *where the gateway runs*. It names the
**InferenceCluster** registered in `inference-cluster.yaml`, so the gateway's
pods and its **LoadBalancer service** are created on that worker cluster —
right next to the models it routes to.

This field is also why the README lists **MetalLB** as a BYO prerequisite:
the gateway needs an external IP for its LoadBalancer service, and on a local
minikube cluster nothing hands out such IPs unless MetalLB is installed. No
MetalLB → the service waits forever for an address → the gateway never
becomes Ready.

---

## How it all connects

1. The **InferenceClass** describes the hardware; the **InferenceCluster**
   registers the worker cluster that has it. (See the companion docs.)
2. MetalLB is enabled on the worker cluster and given its address pool
   (`metallb-config.yaml`) — the BYO prerequisite for this file.
3. You apply this **InferenceGateway** to the **control cluster**. Modelplane
   deploys the gateway onto `inference-cluster-1`, and its **LoadBalancer
   service** gets an IP from MetalLB's pool (`192.168.49.100–120`).
4. Once Ready, the gateway publishes its **endpoints** in its **status** —
   plain-HTTP addresses, reachable from inside the VM (from the Mac only via
   port-forward or a route).
5. Clients send **inference requests** to those endpoints, and the gateway
   routes each request to the right model deployed on the pool.
