NAME    := winbind-watchdog
VERSION := 1.1.0
TARBALL := $(NAME)-$(VERSION).tar.gz

.PHONY: rpm tarball clean

rpm: tarball
	rpmbuild -ba rpm/$(NAME).spec \
		--define "_sourcedir $(CURDIR)" \
		--define "_srcrpmdir $(CURDIR)/rpmbuild/SRPMS" \
		--define "_rpmdir $(CURDIR)/rpmbuild/RPMS"

tarball: clean
	mkdir -p $(NAME)-$(VERSION)
	cp winbind-watchdog.sh winbind-watchdog.service \
	   winbind-watchdog.timer winbind-watchdog.logrotate \
	   winbind-watchdog.conf.example \
	   $(NAME)-$(VERSION)/
	tar czf $(TARBALL) $(NAME)-$(VERSION)
	rm -rf $(NAME)-$(VERSION)

clean:
	rm -rf $(TARBALL) $(NAME)-$(VERSION) rpmbuild/
