# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION ?= 1.24.1
# GATEWAY_API_VERSION refers to the version of Gateway API CRDs.
# For more details, see https://gateway-api.sigs.k8s.io/guides/getting-started/#installing-gateway-api 
GATEWAY_API_VERSION ?= $(shell go list -m -f '{{.Version}}' sigs.k8s.io/gateway-api)

GATEWAY_RELEASE_URL ?= https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml

CONFORMANCE_UNIQUE_PORTS ?= true

# Set Kubernetes Resources Directory Path
ifeq ($(origin KUBE_PROVIDER_DIR),undefined)
KUBE_PROVIDER_DIR := $(ROOT_DIR)/internal/provider/kubernetes/config
endif

# Set Infra Resources Directory Path
ifeq ($(origin KUBE_INFRA_DIR),undefined)
KUBE_INFRA_DIR := $(ROOT_DIR)/internal/infrastructure/kubernetes/config
endif

##@ Kubernetes Development
YEAR := $(shell date +%Y)
CONTROLLERGEN_OBJECT_FLAGS :=  object:headerFile="$(ROOT_DIR)/tools/boilerplate/boilerplate.generatego.txt",year=$(YEAR)

.PHONY: manifests
manifests: $(tools/controller-gen) ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(tools/controller-gen) rbac:roleName=envoy-gateway-role crd webhook paths="./..." output:crd:artifacts:config=internal/provider/kubernetes/config/crd/bases output:rbac:artifacts:config=internal/provider/kubernetes/config/rbac

.PHONY: generate
generate: $(tools/controller-gen) ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
# Note that the paths can't just be "./..." with the header file, or the tool will panic on run. Sorry.
	$(tools/controller-gen) $(CONTROLLERGEN_OBJECT_FLAGS) paths="{$(ROOT_DIR)/api/config/...,$(ROOT_DIR)/internal/ir/...}" 

.PHONY: kube-test
kube-test: manifests generate $(tools/setup-envtest) ## Run Kubernetes provider tests.
	KUBEBUILDER_ASSETS="$(shell $(tools/setup-envtest) use $(ENVTEST_K8S_VERSION) -p path)" go test --tags=integration ./... -coverprofile cover.out

##@ Kubernetes Deployment

ifndef ignore-not-found
  ignore-not-found = true
endif

.PHONY: kube-deploy
kube-deploy: manifests $(tools/kustomize) generate-manifests ## Install Envoy Gateway into the Kubernetes cluster specified in ~/.kube/config.
	kubectl apply -f $(OUTPUT_DIR)/install.yaml

.PHONY: kube-undeploy
kube-undeploy: manifests $(tools/kustomize) ## Uninstall the Envoy Gateway into the Kubernetes cluster specified in ~/.kube/config.
	kubectl delete --ignore-not-found=$(ignore-not-found) -f $(OUTPUT_DIR)/install.yaml

.PHONY: kube-demo
kube-demo: ## Deploy a demo backend service, gatewayclass, gateway and httproute resource and test the configuration.
	kubectl apply -f examples/kubernetes/quickstart.yaml
	$(eval ENVOY_SERVICE := $(shell kubectl get svc -n envoy-gateway-system --selector=gateway.envoyproxy.io/owning-gateway-namespace=default,gateway.envoyproxy.io/owning-gateway-name=eg -o jsonpath='{.items[0].metadata.name}'))
	@echo "\nPort forward to the Envoy service using the command below"
	@echo 'kubectl -n envoy-gateway-system port-forward service/$(ENVOY_SERVICE) 8888:8080 &'
	@echo "\nCurl the app through Envoy proxy using the command below"
	@echo "curl --verbose --header \"Host: www.example.com\" http://localhost:8888/get\n"

.PHONY: kube-demo-undeploy
kube-demo-undeploy: ## Uninstall the Kubernetes resources installed from the `make kube-demo` command.
	kubectl delete -f examples/kubernetes/quickstart.yaml --ignore-not-found=$(ignore-not-found)

# Uncomment when https://github.com/envoyproxy/gateway/issues/256 is fixed.
#.PHONY: run-kube-local
#run-kube-local: build kube-install ## Run Envoy Gateway locally.
#	tools/hack/run-kube-local.sh

.PHONY: conformance 
conformance: create-cluster kube-install-image kube-deploy run-conformance delete-cluster ## Create a kind cluster, deploy EG into it, run Gateway API conformance, and clean up.

.PHONY: create-cluster
create-cluster: $(tools/kind) ## Create a kind cluster suitable for running Gateway API conformance.
	tools/hack/create-cluster.sh

.PHONY: kube-install-image
kube-install-image: image.build $(tools/kind) ## Install the EG image to a kind cluster using the provided $IMAGE and $TAG.
	tools/hack/kind-load-image.sh $(IMAGE) $(TAG)

.PHONY: run-conformance
run-conformance: ## Run Gateway API conformance.
	kubectl wait --timeout=5m -n gateway-system deployment/gateway-api-admission-server --for=condition=Available
	kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
	kubectl apply -f internal/provider/kubernetes/config/samples/gatewayclass.yaml
	go test -v -tags conformance ./test/conformance --gateway-class=envoy-gateway --debug=true --use-unique-ports=$(CONFORMANCE_UNIQUE_PORTS)

.PHONY: delete-cluster
delete-cluster: $(tools/kind) ## Delete kind cluster.
	$(tools/kind) delete cluster --name envoy-gateway

.PHONY: generate-manifests
generate-manifests: $(tools/kustomize) ## Generate Kubernetes release manifests.
	@echo "\033[36m===========> Generating kubernetes manifests\033[0m"
	mkdir -p $(OUTPUT_DIR)/
	curl -sLo $(OUTPUT_DIR)/gatewayapi-crds.yaml ${GATEWAY_RELEASE_URL}
	@echo "\033[36m===========> Added: $(OUTPUT_DIR)/gatewayapi-crds.yaml\033[0m"
	mkdir -pv $(OUTPUT_DIR)/manifests/provider
	cp -r $(KUBE_PROVIDER_DIR) $(OUTPUT_DIR)/manifests/provider
	mkdir -pv $(OUTPUT_DIR)/manifests/infra
	cp -r $(KUBE_INFRA_DIR) $(OUTPUT_DIR)/manifests/infra
	cd $(OUTPUT_DIR)/manifests/provider/config/envoy-gateway && $(ROOT_DIR)/$(tools/kustomize) edit set image envoyproxy/gateway-dev=$(IMAGE):$(TAG)
	$(tools/kustomize) build $(OUTPUT_DIR)/manifests/provider/config/default > $(OUTPUT_DIR)/envoy-gateway.yaml
	$(tools/kustomize) build $(OUTPUT_DIR)/manifests/infra/config/rbac > $(OUTPUT_DIR)/infra-manager-rbac.yaml
	touch $(OUTPUT_DIR)/kustomization.yaml
	cd $(OUTPUT_DIR) && $(ROOT_DIR)/$(tools/kustomize) edit add resource ./envoy-gateway.yaml
	cd $(OUTPUT_DIR) && $(ROOT_DIR)/$(tools/kustomize) edit add resource ./infra-manager-rbac.yaml
	cd $(OUTPUT_DIR) && $(ROOT_DIR)/$(tools/kustomize) edit add resource ./gatewayapi-crds.yaml
	$(tools/kustomize) build $(OUTPUT_DIR) > $(OUTPUT_DIR)/install.yaml
	@echo "\033[36m===========> Added: $(OUTPUT_DIR)/install.yaml\033[0m"
	cp examples/kubernetes/quickstart.yaml $(OUTPUT_DIR)/quickstart.yaml
	@echo "\033[36m===========> Added: $(OUTPUT_DIR)/quickstart.yaml\033[0m"

.PHONY: generate-artifacts
generate-artifacts: generate-manifests ## Generate release artifacts.
	cp -r $(ROOT_DIR)/release-notes/$(TAG).yaml $(OUTPUT_DIR)/release-notes.yaml
	@echo "\033[36m===========> Added: $(OUTPUT_DIR)/release-notes.yaml\033[0m"

.PHONY: update-quickstart
update-quickstart: ## Update quickstart doc image tags to a specific version.
	cp -r docs/user/quickstart.md $(OUTPUT_DIR)/quickstart.md
	cat $(OUTPUT_DIR)/quickstart.md | sed "s;latest;$(TAG);g" > $(OUTPUT_DIR)/quickstart-$(TAG).md
	mv $(OUTPUT_DIR)/quickstart-$(TAG).md docs/user/quickstart.md
	@echo "\033[36m===========> Updated: docs/user/quickstart.md\033[0m"
