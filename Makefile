# LukeNasOS build entry points.
#
# The one that matters:
#   make demo   — build, publish v1/v2/v2-broken to a local registry, boot a VM,
#                 drive install → update → break → auto-rollback → factory reset.
#                 Same script CI runs.

IMAGE      ?= lukenasos
TAG        ?= dev
REGISTRY   ?= localhost:5000
ENGINE     ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

.PHONY: build demo lint check clean registry

build:
	$(ENGINE) build -t $(IMAGE):$(TAG) .

# Local registry for lifecycle testing. CI never pulls from GHCR in tests:
# unpublished commits must be testable, and signature-rejection is only
# reproducible against a registry we control.
registry:
	scripts/demo-lifecycle.sh registry-up

demo: build
	scripts/demo-lifecycle.sh all

lint:
	shellcheck luke/* scripts/*.sh config/greenboot/check/required/*.sh config/greenboot/red.d/*.sh

check: lint
	scripts/demo-lifecycle.sh verify-static

clean:
	scripts/demo-lifecycle.sh clean || true
	rm -rf build/
