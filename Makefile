PYTHON ?= python3
REPOSITORY ?= YOUR_GITHUB/disk-lens

.PHONY: help test build dmg verify homebrew source release-local
help:
	@echo "make test | build | dmg | verify | homebrew | source | release-local"
	@echo "Local build only. No command publishes a GitHub Release."
test:
	$(PYTHON) Scripts/test.py
build:
	$(PYTHON) Scripts/build.py
dmg:
	$(PYTHON) Scripts/package_dmg.py
verify:
	$(PYTHON) Scripts/verify_release.py
homebrew:
	$(PYTHON) Scripts/render_cask.py --repository "$(REPOSITORY)"
source:
	$(PYTHON) Scripts/source_archive.py
release-local:
	$(PYTHON) Scripts/test.py
	$(PYTHON) Scripts/package_dmg.py
	$(PYTHON) Scripts/verify_release.py
	$(PYTHON) Scripts/render_cask.py --repository "$(REPOSITORY)"
	$(PYTHON) Scripts/source_archive.py
