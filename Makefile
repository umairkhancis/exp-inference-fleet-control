# High-level wrapper around the layered setup under scripts/ and manifests/.
#
#   make up        — bring up the whole fleet (control plane → cluster → models → failover)
#   make status    — VM + fleet state
#   make stop      — park the fleet (VMs stopped, all state kept)
#   make start     — bring a parked fleet back to a serving state
#   make down      — delete the VMs and kubectl contexts
#
# Each layer is also addressable on its own; every target is idempotent.

SHELL := /bin/bash
SCRIPTS := scripts
CLIENT := client
ML := manifests/ml-team
KC := kubectl --context modelplane

.PHONY: up host-prereqs control-cluster modelplane inference-cluster-1 \
	models chat verify tunnel failover status stop start down

## Full bring-up: host tools → control cluster → Modelplane → fleet cluster → qwen → Claude failover → proof
up: host-prereqs control-cluster modelplane inference-cluster-1 models chat verify
	@echo
	@echo "Fleet is ready. Use it with:"
	@echo "  ./client/gateway-tunnel.sh          # bridge the gateway to localhost:8080"
	@echo "  ./client/chat.sh \"Hello\"            # one name — ml-team/chat — both tiers behind it"

## Layer 0 — host tools (Homebrew installs whatever is missing)
host-prereqs:
	@command -v brew >/dev/null || { echo "ERROR: Homebrew is required — https://brew.sh" >&2; exit 1; }
	@command -v multipass >/dev/null || brew install --cask multipass
	@command -v kubectl >/dev/null || brew install kubectl
	@command -v helm >/dev/null || brew install helm
	@command -v jq >/dev/null || brew install jq
	@echo "Host tools present: multipass, kubectl, helm, jq"

## Layer 1 — control cluster: "modelplane" multipass VM + minikube, kubectl context on the host
control-cluster:
	$(SCRIPTS)/setup-control-cluster.sh

## Layer 2 — Crossplane + the Modelplane Configuration (waits until Healthy)
modelplane:
	$(SCRIPTS)/install-crossplane.sh

## Layer 3 — fleet cluster: VM + minikube + pool labels + MetalLB, registered and Ready
inference-cluster-1:
	$(SCRIPTS)/add-inference-cluster-1

## Layer 4 — qwen on the fleet (ml-team/qwen-cpu), wait until the replica serves
models:
	$(KC) apply -f $(ML)/namespace.yaml
	$(KC) apply -f $(ML)/qwen-cpu/model-deployment.yaml
	$(KC) apply -f $(ML)/qwen-cpu/model-service.yaml
	@echo "Waiting for the qwen replica (first run pulls a ~2GB engine image + ~1GB of weights)"
	$(KC) wait --for=condition=Ready -f $(ML)/qwen-cpu/model-deployment.yaml --timeout=30m
	$(KC) get modelreplica -n ml-team

## Layer 5 — ml-team/chat: fleet first, Claude as failover (needs ANTHROPIC_API_KEY once)
chat:
	$(KC) apply -f $(ML)/namespace.yaml
	@if $(KC) -n ml-team get secret anthropic-api-key >/dev/null 2>&1; then \
	  echo "Secret ml-team/anthropic-api-key already exists — keeping it"; \
	elif [ -n "$$ANTHROPIC_API_KEY" ]; then \
	  $(KC) -n ml-team create secret generic anthropic-api-key \
	    --from-literal=apiKey="$$ANTHROPIC_API_KEY"; \
	else \
	  echo "ERROR: export ANTHROPIC_API_KEY=sk-ant-... first (it is stored only as a" >&2; \
	  echo "ERROR: Secret on the control cluster, never committed)." >&2; exit 1; \
	fi
	$(KC) apply -f $(ML)/chat/model-endpoint-claude.yaml
	$(KC) apply -f $(ML)/chat/model-service.yaml
	$(KC) get ms -n ml-team

## Layer 6 — trace one request through every hop (gateway → EPP → engine) with proof
verify:
	$(SCRIPTS)/trace-inference.sh

## Bridge the fleet gateway to localhost:8080 (foreground; Ctrl-C to stop)
tunnel:
	$(CLIENT)/gateway-tunnel.sh

## Prove both tiers of ml-team/chat: fleet serves → killed → Claude serves → recovery (run `make tunnel` first)
failover:
	$(CLIENT)/test-failover.sh

## Current VM + fleet state
status:
	multipass list
	-$(KC) get inferencecluster,inferencegateway
	-$(KC) get md,ms,modelreplica -n ml-team

## Park the fleet: VMs stopped, disks (clusters, images, weights) kept
stop:
	$(SCRIPTS)/fleet-stop.sh

## Bring a parked fleet back: VMs up, MetalLB pools re-applied, engine recycled if stale
start:
	$(SCRIPTS)/fleet-start.sh

## Tear everything down: delete the VMs and the kubectl contexts they created
down:
	-multipass delete --purge inference-cluster-1 modelplane
	-kubectl config delete-context inference-cluster-1
	-kubectl config delete-context modelplane
	-kubectl config delete-cluster inference-cluster-1
	-kubectl config delete-cluster modelplane
	-kubectl config delete-user inference-cluster-1
	-kubectl config delete-user modelplane
