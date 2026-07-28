# ============================================================================
#  filebrowser - local build & maintenance Makefile
# ============================================================================

# ---- Config ----------------------------------------------------------------
BINARY		:= filebrowser
INSTALL_DIR   := /usr/local/bin
FRONTEND_DIR  := frontend
HTTP_DIST_DIR := http/dist
DIST_DIR	  := dist

VERSION	?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT	 ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
VERSION_PKG := github.com/filebrowser/filebrowser/v2/version
LDFLAGS	 := -X $(VERSION_PKG).Version=$(VERSION) \
			   -X $(VERSION_PKG).Commit=$(COMMIT) \
			   -X $(VERSION_PKG).BuildDate=$(BUILD_DATE)

GO	   := go
GOFLAGS  := -trimpath
NPM	  := npm
MAGE	 := $(shell command -v mage 2> /dev/null)

# ---- Help ------------------------------------------------------------------
.DEFAULT_GOAL := help
.PHONY: help
help: ## Show available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---- Prerequisites ---------------------------------------------------------
.PHONY: check
check: ## Verify required tools are installed
	@echo "==> Checking prerequisites"
	@command -v go	>/dev/null 2>&1 || { echo "  ✗ go (https://go.dev/dl/)"; exit 1; }
	@command -v node  >/dev/null 2>&1 || { echo "  ✗ node (brew install node)"; exit 1; }
	@command -v npm   >/dev/null 2>&1 || { echo "  ✗ npm";  exit 1; }
	@command -v git   >/dev/null 2>&1 || { echo "  ✗ git";  exit 1; }
	@command -v mage  >/dev/null 2>&1 || echo "  ⚠ mage  not found (will use raw go/npm)"
	@echo "  ✓ ok"

.PHONY: install-tools
install-tools: ## Install mage + golangci-lint
	@echo "==> Installing Go build tools"
	$(GO) install github.com/magefile/mage@latest
	$(GO) install github.com/golangci/golangci-lint/cmd/golangci-lint@latest

# ---- Frontend --------------------------------------------------------------
.PHONY: frontend-deps
frontend-deps: ## Install frontend npm dependencies
	@echo "==> Installing frontend dependencies"
	cd $(FRONTEND_DIR) && $(NPM) install

.PHONY: frontend
frontend: frontend-deps ## Build frontend (npm run build)
	@echo "==> Building frontend"
	cd $(FRONTEND_DIR) && $(NPM) run build
	@echo "==> Staging frontend for go:embed"
	rm -rf $(HTTP_DIST_DIR)
	cp -R $(FRONTEND_DIR)/dist $(HTTP_DIST_DIR)

.PHONY: frontend-dev
frontend-dev: ## Run Vite dev server (hot reload)
	cd $(FRONTEND_DIR) && $(NPM) run dev

.PHONY: frontend-clean
frontend-clean: ## Remove frontend build artifacts
	rm -rf $(FRONTEND_DIR)/dist $(FRONTEND_DIR)/node_modules
	rm -rf $(HTTP_DIST_DIR)

# ---- Backend ---------------------------------------------------------------
.PHONY: backend
backend: ## Build Go backend binary
	@echo "==> Building backend ($(VERSION) @ $(COMMIT))"
	$(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(BINARY) .

.PHONY: backend-dev
backend-dev: ## Build backend with race detector (dev only)
	$(GO) build -race -ldflags "$(LDFLAGS)" -o $(BINARY) .

# ---- Full build ------------------------------------------------------------
.PHONY: build
build: frontend backend ## Build everything (frontend + backend)

.PHONY: build-mage
build-mage: ## Build via the project's magefile (requires mage)
	@command -v mage >/dev/null 2>&1 || { echo "mage not installed: run 'make install-tools'"; exit 1; }
	mage build

# ---- Install to /usr/local/bin --------------------------------------------
.PHONY: install
install: build ## Build and install binary to $(INSTALL_DIR)
	@echo "==> Installing $(BINARY) → $(INSTALL_DIR)/"
	sudo mkdir -p $(INSTALL_DIR)
	sudo install -m 0755 $(BINARY) $(INSTALL_DIR)/$(BINARY)
	@echo "==> Installed. Verify with: $(BINARY) --version"

.PHONY: install-strip
install-strip: ## Install without sudo (requires write access to $(INSTALL_DIR))
	@echo "==> Installing $(BINARY) → $(INSTALL_DIR)/"
	install -m 0755 $(BINARY) $(INSTALL_DIR)/$(BINARY)

.PHONY: uninstall
uninstall: ## Remove binary from $(INSTALL_DIR)
	@echo "==> Removing $(INSTALL_DIR)/$(BINARY)"
	sudo rm -f $(INSTALL_DIR)/$(BINARY)

# ---- Run -------------------------------------------------------------------
.PHONY: run
run: build ## Build then run locally on 127.0.0.1:8080 (no auth, root=cwd)
	./$(BINARY) --noauth --address 127.0.0.1 --port 8080 --root "$$(pwd)"

.PHONY: run-prod
run-prod: build ## Run with auth DB in ~/.filebrowser
	mkdir -p $$HOME/.filebrowser
	./$(BINARY) --database $$HOME/.filebrowser/filebrowser.db \
				--address 0.0.0.0 --port 8080 --root "$$HOME"

# ---- Tests / lint / format -------------------------------------------------
.PHONY: test
test: ## Run Go tests
	$(GO) test -timeout 120s ./...

.PHONY: test-frontend
test-frontend: ## Run frontend tests
	cd $(FRONTEND_DIR) && $(NPM) run test

.PHONY: lint
lint: ## Run go vet + golangci-lint (if present) + frontend lint
	$(GO) vet ./...
	@command -v golangci-lint >/dev/null 2>&1 && golangci-lint run ./... || echo "  ⚠ golangci-lint not installed"
	@[ -f $(FRONTEND_DIR)/package.json ] && cd $(FRONTEND_DIR) && $(NPM) run lint 2>/dev/null || true

.PHONY: fmt
fmt: ## Format Go + frontend code
	$(GO) fmt ./...
	@gofmt -s -w .
	cd $(FRONTEND_DIR) && $(NPM) run format 2>/dev/null || true

# ---- Modules / deps --------------------------------------------------------
.PHONY: tidy
tidy: ## go mod tidy
	$(GO) mod tidy

.PHONY: deps
deps: ## Upgrade Go + npm dependencies
	$(GO) get -u ./...
	$(GO) mod tidy
	cd $(FRONTEND_DIR) && $(NPM) update

# ---- Cross-compile ---------------------------------------------------------
.PHONY: cross-compile
cross-compile: frontend ## Cross-compile for common targets into ./$(DIST_DIR)
	@mkdir -p $(DIST_DIR)
	@for target in \
		"darwin amd64" "darwin arm64" \
		"linux  amd64" "linux  arm64" \
		"windows amd64"; do \
	  set -- $$target ; \
	  os=$$1 ; arch=$$2 ; \
	  out=$(DIST_DIR)/$(BINARY)-$(VERSION)-$$os-$$arch ; \
	  [ $$os = windows ] && out=$$out.exe ; \
	  echo "==> Building $$os/$$arch → $$out" ; \
	  GOOS=$$os GOARCH=$$arch $(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $$out . ; \
	done
	@ls -lh $(DIST_DIR)

# ---- Clean -----------------------------------------------------------------
.PHONY: clean
clean: ## Remove build artifacts (binary, embed dir, dist)
	rm -f $(BINARY)
	rm -rf $(HTTP_DIST_DIR) $(DIST_DIR)
	$(GO) clean -cache 2>/dev/null || true

.PHONY: clean-all
clean-all: clean frontend-clean ## Deep clean (also removes node_modules)

# ---- Git / version ---------------------------------------------------------
.PHONY: version
version: ## Print version/commit/build-date
	@echo "Version:	$(VERSION)"
	@echo "Commit:	 $(COMMIT)"
	@echo "Build Date: $(BUILD_DATE)"

.PHONY: update
update: ## Pull latest from upstream master
	git fetch --tags --prune
	git pull --rebase origin master

# ---- Aggregates ------------------------------------------------------------
.PHONY: ci
ci: check lint test build ## CI-style: check, lint, test, build

.PHONY: all
all: clean-all build ## Full clean rebuild + SKIP test (lk)
# all: clean-all build test ## Full clean rebuild + test

.PHONY: release
release: cross-compile ## Cross-compile a release set into ./$(DIST_DIR)
	@echo "==> Release artifacts:"
	@ls -lh $(DIST_DIR)
