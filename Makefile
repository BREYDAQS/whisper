APP := macos/build/call-whisper.app
BIN := $(APP)/Contents/MacOS/call-whisper

.PHONY: dev prod install build-dev build-prod test

# Dev: debug build, binarka z wnętrza .app (TCC działa), logi w terminalu.
dev: build-dev
	CW_DEBUG=1 $(BIN)

build-dev:
	bash macos/tools/bundle.sh debug

# Prod: release build, odpalenie jak normalna apka.
prod: build-prod
	open $(APP)

# Install: release + start przy logowaniu + odpalenie. Apka zostaje w macos/build
# (stamtąd przebudowuje ją auto-update), login item wskazuje na nią.
install: build-prod
	$(BIN) --login-item on
	open $(APP)

build-prod:
	bash macos/tools/bundle.sh release

test:
	npm test
	cd macos && swift test
