VERSION ?= $(shell cat VERSION)
NAME := caddy-cert-sync
AGENT := $(NAME)-agent
DIST ?= dist
PKG := $(DIST)/pkg/$(NAME)_$(VERSION)
PKGA := $(DIST)/pkg/$(AGENT)_$(VERSION)
STAGEA := $(DIST)/stage/$(AGENT)-$(VERSION)

.PHONY: test lint dist dist-agent deb deb-agent sums release image clean version
version:
	@echo $(VERSION)
lint:
	for f in bin/*.sh install.sh container/entrypoint.sh packaging/postinst packaging/prerm packaging/postinst-agent; do bash -n $$f || exit 1; done
	shellcheck -S error bin/*.sh install.sh container/entrypoint.sh
test:
	bash tests/run-tests.sh
	bash tests/test-container.sh
	bash tests/test-two-vm.sh
	bash tests/test-agent.sh
	bash tests/test-ssh-real.sh
	bash tests/test-packaging.sh

# --- Sản phẩm cho VM chạy hệ thống thay cert (cùng VM, hoặc VM SBC khi khác VM): mã nguồn đầy đủ, gói deb đầy đủ ---
dist:
	mkdir -p $(DIST)
	tar czf $(DIST)/$(NAME)-$(VERSION).tar.gz --exclude=./dist --exclude=./.git --transform 's,^\./,$(NAME)-$(VERSION)/,' .
deb:
	rm -rf $(PKG)
	install -d $(PKG)/DEBIAN $(PKG)/usr/local/bin $(PKG)/etc/systemd/system $(PKG)/usr/local/share/$(NAME)/examples $(PKG)/usr/local/share/$(NAME)/profiles
	for f in bin/*.sh; do case $$(basename $$f) in lib-*) m=644;; *) m=755;; esac; install -m $$m $$f $(PKG)/usr/local/bin/; done
	install -m 644 systemd/*.service systemd/*.timer $(PKG)/etc/systemd/system/
	echo $(VERSION) > $(PKG)/usr/local/share/$(NAME)/VERSION
	install -m 644 config/*.example $(PKG)/usr/local/share/$(NAME)/examples/
	for p in same-vm diff-vm; do install -d $(PKG)/usr/local/share/$(NAME)/profiles/$$p; install -m 644 profiles/$$p/config.conf $(PKG)/usr/local/share/$(NAME)/profiles/$$p/; done
	sed 's/@VERSION@/$(VERSION)/' packaging/control.in > $(PKG)/DEBIAN/control
	install -m 755 packaging/postinst packaging/prerm $(PKG)/DEBIAN/
	dpkg-deb -Zxz --build --root-owner-group $(PKG) $(DIST)/$(NAME)_$(VERSION)_all.deb

# --- Sản phẩm cho VM PBX khi khác VM: chỉ có agent ---
dist-agent:
	rm -rf $(STAGEA)
	install -d $(STAGEA)/bin $(STAGEA)/config
	install -m 755 install.sh $(STAGEA)/install.sh
	install -m 755 bin/pbx-agent.sh $(STAGEA)/bin/pbx-agent.sh
	install -m 644 config/pbx-cert-agent.conf.example $(STAGEA)/config/pbx-cert-agent.conf.example
	install -m 644 VERSION $(STAGEA)/VERSION
	tar czf $(DIST)/$(AGENT)-$(VERSION).tar.gz -C $(DIST)/stage $(AGENT)-$(VERSION)
deb-agent:
	rm -rf $(PKGA)
	install -d $(PKGA)/DEBIAN $(PKGA)/usr/local/bin $(PKGA)/usr/local/share/$(NAME)/examples
	install -m 755 bin/pbx-agent.sh $(PKGA)/usr/local/bin/pbx-agent.sh
	echo $(VERSION) > $(PKGA)/usr/local/share/$(NAME)/VERSION
	install -m 644 config/pbx-cert-agent.conf.example $(PKGA)/usr/local/share/$(NAME)/examples/
	sed 's/@VERSION@/$(VERSION)/' packaging/control-agent.in > $(PKGA)/DEBIAN/control
	install -m 755 packaging/postinst-agent $(PKGA)/DEBIAN/postinst
	dpkg-deb -Zxz --build --root-owner-group $(PKGA) $(DIST)/$(AGENT)_$(VERSION)_all.deb

# --- Tất cả sản phẩm và tệp checksum ---
sums:
	cd $(DIST) && sha256sum *.tar.gz *.deb > SHA256SUMS
release: clean
	$(MAKE) dist dist-agent deb deb-agent
	$(MAKE) sums
image:
	docker build -f container/Dockerfile -t $(NAME):$(VERSION) .
clean:
	rm -rf $(DIST)
