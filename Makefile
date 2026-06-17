.PHONY: help build build-updater up down logs ps test scan clean

DC := docker compose

help:
	@echo "Cibles disponibles :"
	@echo "  make build           - Build de l'image suricata-hardened"
	@echo "  make build-updater   - Build de l'image suricata-updater"
	@echo "  make up              - Démarre le container (mode test, pas NFQUEUE)"
	@echo "  make down            - Arrête le container"
	@echo "  make logs            - Tail des logs"
	@echo "  make ps              - État des conteneurs"
	@echo "  make test            - Vérifie que le container démarre + healthcheck"
	@echo "  make scan            - Scan trivy de l'image"
	@echo "  make clean           - Supprime volumes + images"

build:
	DOCKER_BUILDKIT=1 $(DC) build suricata

build-updater:
	DOCKER_BUILDKIT=1 docker build -t suricata-updater:latest updater/

up:
	$(DC) up -d

down:
	$(DC) down

logs:
	$(DC) logs -f --tail=200

ps:
	$(DC) ps

test:
	@echo "=== Build test ==="
	$(DC) build suricata
	@echo "=== Start test ==="
	$(DC) up -d
	@sleep 5
	@echo "=== Healthcheck test ==="
	docker exec suricata-hardened /usr/local/bin/init --healthcheck && echo "PASS: healthcheck OK" || echo "FAIL: healthcheck failed"
	@echo "=== No-shell test ==="
	docker exec suricata-hardened /bin/sh 2>&1 | grep -q "not found" && echo "PASS: no shell" || echo "FAIL: shell found"
	@echo "=== Cleanup ==="
	$(DC) down

scan:
	trivy image --severity HIGH,CRITICAL --ignore-unfixed suricata-hardened:latest

clean:
	$(DC) down -v
	docker image rm suricata-hardened:latest suricata-updater:latest 2>/dev/null || true
