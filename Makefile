OLD_VERSION ?=
NEW_VERSION ?=

FILES := \
	docker/docker-compose.yaml \
	docker/install.sh \
	docker/install-nowsl.sh \
	docker/install-dockerhub.sh \
	docker/upgrade.sh \
	scripts/pull-images.sh \
	README.md \
	README_EN.md

.PHONY: bump check

check:
	@test -n "$(OLD_VERSION)" || (echo "Usage: make bump OLD_VERSION=x.y.z NEW_VERSION=x.y.z" && exit 1)
	@test -n "$(NEW_VERSION)" || (echo "Usage: make bump OLD_VERSION=x.y.z NEW_VERSION=x.y.z" && exit 1)

bump: check
	@echo "Bumping v$(OLD_VERSION) → v$(NEW_VERSION) ..."
	@for f in $(FILES); do \
		sed -i.bak \
			-e 's/swanlab-server:v$(OLD_VERSION)/swanlab-server:v$(NEW_VERSION)/g' \
			-e 's/swanlab-house:v$(OLD_VERSION)/swanlab-house:v$(NEW_VERSION)/g' \
			-e 's/swanlab-cloud:v$(OLD_VERSION)/swanlab-cloud:v$(NEW_VERSION)/g' \
			-e 's/swanlab-next:v$(OLD_VERSION)/swanlab-next:v$(NEW_VERSION)/g' \
			-e 's/VERSION=$(OLD_VERSION)/VERSION=$(NEW_VERSION)/g' \
			-e 's/Self-Hosted Docker v$(OLD_VERSION)/Self-Hosted Docker v$(NEW_VERSION)/g' \
			-e 's/update_self_hosted_version "$(OLD_VERSION)"/update_self_hosted_version "$(NEW_VERSION)"/g' \
			-e 's/update_version "$(OLD_VERSION)"/update_version "$(NEW_VERSION)"/g' \
			-e 's/可升级至 `v$(OLD_VERSION)`/可升级至 `v$(NEW_VERSION)`/g' \
			-e 's/upgrade to version `v$(OLD_VERSION)`/upgrade to version `v$(NEW_VERSION)`/g' \
			"$$f" && rm -f "$$f.bak"; \
	done
	@echo "Done. Review changes with: git diff"
