
build:
	zig build -Doptimize=ReleaseFast \
	-Dis_ci \
	-Dbuild_date=$(shell date +"%Y-%m-%dT%H:%M:%S%z") \
	-Dgit_commit=$(shell git rev-parse --short HEAD) \
	--summary all

fmt:
	zig fmt --check .

test:
	zig build test --summary all

ci: fmt test

init-docs:
	cd docs && hugo mod get -u

serve:
	cd docs && hugo serve -D

.PHONY: init-docs serve test fmt build
