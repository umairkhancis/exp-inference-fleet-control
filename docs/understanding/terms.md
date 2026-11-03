---
markmap:
    initialExpandLevel: 2
    spacingVertical: 24
page:
    title: Terms of Modelplane.ai (Glossary)
    kicker: Umair Ahmed Khan
---

# Terms of Modelplane.ai (Glossary)

## People

### ML Team
- Deploy models without being concerned about where are they deployed.
- Declare model and its config to serve it.
- Not concerned about the required underlying hardware infrastructure to serve it.

### Infrastructure Team
- Provisions the underlying hardware infrastructure on which models will be executed.
- Declare what devices are available and where are they available and how to discover them.
- Not concerned about what models would be served on underlying hardware infrastructure.

## Infrastructure

### InferenceCluster
- A k8s cluster with GPU capacity which runs inference engines like vLLM, SGlang, TensorRT-LLM.
- Modelplane can provision the inference cluster on managed k8s cluster (EKS, GKE, etc.) or you can bring your own cluster (BYOC).

### Control Cluster
- An isolated k8s cluster just for controlling fleet of inference clusters.
- Modelplane is installed on control cluster to manage the fleet of inference cluster.

### InferenceClass
- It is the specification (shape) of the hardware to be available in the node pools of inference cluster.

### NodePool
- Nodes of the inference cluster having the inference class devices available.

### Dynamic Resource Allocation (DRA)
- The k8s mechanism that hands devices (GPUs/CPUs) exclusively to pods.
- A driver on each node discovers devices and publishes their real capacity; 
- The workload makes a claim using CEL filter over that capacity and then allocator binds claim to device when the pod schedules.

## Workload

### ModelDeployment
- Serving of the model.

### ModelReplica
- Model deployment replica; Instances of the whole serving.

### ModelService
- Exposing the model deployment behind a single shared name.
- A service selects what to route to by label.
- Uisng ModelService, you can route to the underlying deployment on the granular level using endpoints.
    - You reference the multiple types of model deployments under one name (making multiple models appearing like a single model).
        - You can split the traffic between multiple types of model based on percentage.
    - You can create model endpoint object for the external provider like (open.ai and anthropic).

- Timeouts: sets how long a gateway waits on the service’s endpoints.
    - timeouts.requests: bounds a whole request, retries included.
        - A response that isn’t streamed doesn’t send anything until it’s complete. If any of a service’s callers don’t stream, set idle at least as long as request, or to 0s to disable it.
    - timeouts.idle: how long an endpoint may go without sending anything. 
        - A streamed response starts after prefill, so idle bounds time to first token and every gap between chunks after it. 

### ModelEndpoint
- Reachable backend for each model replica.
- Each replica of a deployment and sets these routing labels on ModelEndpoint object:
    - modelplane.ai/deployment: the deployment's replica model endpoint belongs to.
    - modelplane.ai/cluster: the cluster the replica runs on.
- Modelplane creates an endpoint once its replica is serving, with at least one copy of each engine ready and reachable, and withdraws it if the replica stops serving.
- A replica that loses one of several copies keeps its endpoint, and the endpoint picker sends requests to the copies that are up. 
- You don’t create endpoints yourself for your own deployments as it will be managed by modelplane. You just point a service at them.
- But for external providers, you can create model endpoints yourself.

### Engines
- Inference engine like vllm, sglang.

### Engine.Member
- Topology of inference engine pods (standalone or gang).

### Engine.Copy 
- Instances inference engine pods like vllm, sglang.

### InferenceGateway
- An InferenceGateway names the services it serves, through a serviceSelector that matches a service’s labels.
- A gateway with no selector serves every service.
- A caller names the model as <namespace>/<service>. 
- A caller sends a request with the service as its model
- Inference gateway maps the model name in the request as `<namespace>/<service>` to whatever each endpoint’s engine or provider specific name. This service naming format is 
- A gateway without TLS publishes a base URL per API it speaks.
- GET $ADDRESS/models lists every model that gateway will route, which is how a caller discovers the name.
- APIs Format: Inference Gateway can speak either APIs based on what client is speaking while engines (vllm) only speaks OpenAI format so gateway is reponsible for mapping between the two format based on what client is speaking.
    - Anthropic
    - Open AI



### ModelRoute
- For each gateway that serves the service, Modelplane composes a ModelRoute that renders the routing onto that gateway’s cluster.
- 

## Routing

### Router
- Everything between the edge of inference cluster and the engine serving the model. 

### End Point Picker (EPP)
- The component which picks the pod for each request. EPP is a type of router such as llm-d is one implementation of EPP which routes based on KV cache and load awareness.

### Decider 
- The one decides whether the request goes through prefill.

### Sidecar
- A container in each decode pod that sends the prefill half of a request to the prefill pod the picker chose

### KV connector
- The engine setting that moves the KV cache between pods, such as vLLM’s NixlConnector.


