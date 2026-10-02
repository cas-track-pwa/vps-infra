.PHONY: provision sync tracker caddy itflow healthcheck backup endpoint

provision:
	sudo -E ./scripts/provision.sh

sync:
	sudo -E ./scripts/provision.sh sync

tracker:
	sudo -E ./scripts/provision.sh tracker

caddy:
	sudo -E ./scripts/provision.sh caddy

itflow:
	sudo -E ./scripts/provision.sh itflow

endpoint:
	sudo -E ./itflow/install-endpoint.sh

healthcheck:
	./scripts/healthcheck.sh

backup:
	sudo -E ./scripts/backup.sh
