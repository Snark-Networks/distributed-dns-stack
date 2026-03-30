# Makefile — DNS infrastructure management
#
# Full deployment:
#   make deploy                 Full deployment (Docker + CoreDNS + dnsdist + zones + monitoring)
#
# Tier-specific deployments:
#   make deploy-coredns         CoreDNS backend servers only
#   make deploy-dnsdist         dnsdist frontend servers only
#   make deploy-dns             Both CoreDNS and dnsdist (CoreDNS first)
#   make deploy-zones           Zone files only (fast path — no Docker changes)
#   make deploy-monitoring      Monitoring stack + Promtail config update on all DNS servers
#   make deploy-monitoring-fresh  First-time monitoring deployment (installs Docker first)
#
# Operations:
#   make check                  Validate zone files locally before deploying
#   make reload                 Force CoreDNS reload on all coredns_servers (SIGHUP)
#   make test                   Query both zones to verify DNS is answering
#   make logs-dnsdist           Tail dnsdist container logs on DNSDIST_SERVER
#   make logs-coredns           Tail CoreDNS container logs on COREDNS_SERVER
#   make mon-logs               Tail monitoring container logs
#   make mon-status             Show monitoring container status

ANSIBLE        = cd ansible && ansible-playbook
DNSDIST_SERVER = root@192.0.2.1    # Replace with your primary dnsdist server IP
COREDNS_SERVER = root@192.0.2.10   # Replace with your primary CoreDNS server IP
MON_SERVER     = root@192.0.2.20   # Replace with your monitoring server IP

.PHONY: deploy deploy-dns deploy-dnsdist deploy-coredns deploy-zones \
        deploy-monitoring deploy-monitoring-fresh \
        check reload test logs-dnsdist logs-coredns mon-logs mon-status

deploy: check
	$(ANSIBLE) site.yml

deploy-dns: check
	$(ANSIBLE) deploy-dns.yml

deploy-dnsdist:
	$(ANSIBLE) deploy-dnsdist.yml

deploy-coredns: check
	$(ANSIBLE) deploy-coredns.yml

deploy-zones: check
	$(ANSIBLE) deploy-zones.yml

deploy-monitoring:
	$(ANSIBLE) deploy-monitoring.yml

deploy-monitoring-fresh:
	$(ANSIBLE) deploy-monitoring-fresh.yml

check:
	@./scripts/check-zones.sh || (echo "\nFix zone errors before deploying." && exit 1)

reload:
	cd ansible && ansible coredns_servers -m command -a "docker kill --signal=SIGHUP coredns"

test:
	@echo "=== PTR for 192.0.2.1 (via dnsdist) ==="
	@ssh $(DNSDIST_SERVER) "dig +short PTR 1.2.0.192.in-addr.arpa @127.0.0.1"
	@echo ""
	@echo "=== SOA (IPv4 zone, via dnsdist) ==="
	@ssh $(DNSDIST_SERVER) "dig +short SOA 2.0.192.in-addr.arpa @127.0.0.1"
	@echo ""
	@echo "=== PTR for 2001:db8:f9:2::13:1 (via dnsdist) ==="
	@ssh $(DNSDIST_SERVER) "dig +short PTR 1.0.0.0.3.1.0.0.0.0.0.0.0.0.0.0.2.0.0.0.9.f.0.0.8.b.d.0.1.0.0.2.ip6.arpa @127.0.0.1"
	@echo ""
	@echo "=== SOA (CoreDNS direct, port 5300) ==="
	@ssh $(COREDNS_SERVER) "dig +short SOA 2.0.192.in-addr.arpa @127.0.0.1 -p 5300"
	@echo ""
	@echo "=== dnsdist metrics ==="
	@ssh $(DNSDIST_SERVER) "curl -s http://127.0.0.1:8083/metrics | grep -E '^dnsdist_(queries|responses|latency_avg1000|server_state)' | head -10"
	@echo ""
	@echo "=== CoreDNS metrics ==="
	@ssh $(COREDNS_SERVER) "curl -s http://127.0.0.1:9153/metrics | grep -E '^coredns_dns_requests_total' | head -10"

logs-dnsdist:
	ssh $(DNSDIST_SERVER) "docker compose -f /opt/dnsdist/docker-compose.yml logs -f --tail=50"

logs-coredns:
	ssh $(COREDNS_SERVER) "docker compose -f /opt/coredns/docker-compose.yml logs -f --tail=50"

mon-logs:
	ssh $(MON_SERVER) "docker compose -f /opt/monitoring/docker-compose.yml logs -f --tail=30"

mon-status:
	ssh $(MON_SERVER) "docker compose -f /opt/monitoring/docker-compose.yml ps"
