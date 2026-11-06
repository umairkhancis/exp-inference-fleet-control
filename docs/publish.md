# Publishing Log

## Post #5 — fleet control

I have been experimenting with Modelplane. This experiment is controlling a fleet of inference clusters from one Kubernetes control plane where Claude (frontier inference) served as a transparent failover layer. 

And you can try at your home.

Run your own fleet-controlled LLM inference from your own laptop, managed the way platform teams should.

It requires three things:

1. A control cluster (minikube in an isolated Multipass VM) running Crossplane + Modelplane. This is the only cluster you ever talk to.
2. A BYO inference cluster registered with one YAML object. Modelplane installs the entire serving stack onto it by itself: gateway, smart router, vLLM engine, even the CPU device driver.
3. One model name — ml-team/chat — backed by priority tiers: the fleet's own Qwen2.5 0.5B first, Claude via Anthropic's API as failover.

Point any application (OpenAI SDK or cURL script) at it by changing one line in your code. Callers see one URL and one model name. Nothing else.

Proofs from my MacBook, measured from outside the clusters:

1. Apply one ModelDeployment on the control cluster: the scheduler picks the fleet cluster, pulls the engine, and an OpenAI-compatible API starts answering.

2. Kill the only engine pod: the SAME request, same model name, is answered by claude-haiku — "I'm Claude, an AI assistant made by Anthropic." The caller never notices.

3. Bring the fleet back: traffic returns to the local Qwen. Same URL the whole time.

4. Every request is traceable hop by hop: Envoy gateway access log → endpoint picker decision → vLLM engine log → Prometheus counters, tied together by one request id.

Why it matters: every inference cluster today is its own island i.e. its own endpoint, its own deploy scripts, failures that reach your users. 

A fleet control plane turns clusters into fleet and model placement into a one-line declaration.

Failure of inference cluster stops being your users problem and the frontier takes over as a failover.

Try it with one command, link is in the comments section.

The repo has a step by step path if you want to see each step before you run it, the client scripts that prove the failover on your own machine, and all the details.

#Modelplane #Crossplane #Kubernetes #vLLM #LLM #SelfHosted #MLOps #PlatformEngineering

## Post #5 — video share

Watch one control plane bring up an inference fleet — and Claude silently catch its failure — in 69 seconds.

This is Modelplane running on my laptop: a Crossplane-based control cluster managing a BYO Kubernetes cluster, serving one OpenAI-compatible model name with the fleet's own Qwen first and Claude's API as the failover tier.

The video is the actual install journey, with the real terminal output at every stage — nothing mocked:

1. One command brings up the control cluster, Crossplane + Modelplane (37 packages, all Healthy), the fleet cluster, and the model. Hands-off.
2. Registering a cluster is one YAML object. Modelplane installs the gateway, router, and engine onto it by itself.
3. The payoff: kill the fleet's only engine pod and the same request — same URL, same model name — comes back answered by Claude. Bring the fleet back, traffic returns home. The caller never knows.

Requirements: Apple Silicon Mac, 24GB RAM, Homebrew. Everything else installs itself. Tear it all down with one command too.

Repo link in the comments — the install command sits at the top of the README.

#Modelplane #Crossplane #Kubernetes #vLLM #LLM #SelfHosted #MLOps #PlatformEngineering
