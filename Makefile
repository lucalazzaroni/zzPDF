# zzPDF: build, test, install.
#
#   make           builds outputs/zzPDF.app
#   make test      runs every smoke test (headless: no window is ever shown)
#   make install   builds, then puts the app in /Applications

APP         := outputs/zzPDF.app
INSTALL_DIR := /Applications
INSTALLED   := $(INSTALL_DIR)/zzPDF.app
STAGED      := $(INSTALL_DIR)/.zzPDF.app.new
RETIRED     := $(INSTALL_DIR)/.zzPDF.app.old
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: build test install

build:
	./build-app.sh

test:
	./scripts/run-tests.sh

# The new copy is staged beside the old one and swapped in by renaming. A zzPDF that is
# running keeps its own copy until it is quit, instead of having its binary replaced under
# it — so this is safe to run with the app open, and the new version is what opens next.
install: build
	@test -d "$(APP)" || { echo "No app at $(APP)"; exit 1; }
	rm -rf "$(STAGED)" "$(RETIRED)"
	ditto "$(APP)" "$(STAGED)"
	if [ -d "$(INSTALLED)" ]; then mv "$(INSTALLED)" "$(RETIRED)"; fi
	mv "$(STAGED)" "$(INSTALLED)"
	rm -rf "$(RETIRED)"
	"$(LSREGISTER)" -f "$(INSTALLED)"
	@echo "Installed $(INSTALLED). If zzPDF is open, quit and reopen it to use the new version."
