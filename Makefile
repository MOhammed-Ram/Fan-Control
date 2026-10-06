.PHONY: all build cli app run clean status auto turbo test helper install-helper uninstall-helper

all: build

build:
	@./Scripts/build.sh

cli: build

app: build

run: build
	@open build/FanControl.app

status:
	@./build/bin/fan-curve-ctl status

auto:
	@./build/bin/fan-curve-ctl auto

turbo:
	@./build/bin/fan-curve-ctl turbo

test:
	@./build/bin/fan-curve-ctl status

install-helper: build
	@sudo ./Scripts/install-helper.sh

uninstall-helper:
	@sudo ./Scripts/uninstall-helper.sh

clean:
	@rm -rf build
	@echo "Cleaned build artifacts."
