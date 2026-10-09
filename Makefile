.PHONY: init-docs serve test fmt build

build:
	zig build -Doptimize=ReleaseFast \
	-Dbuild_date=$(shell date +"%Y-%m-%dT%H:%M:%S%z") \
	-Dgit_commit=$(shell git rev-parse --short HEAD) \
	-Dversion=$(shell git tag --points-at HEAD) \
	--summary all

fmt:
	zig fmt --check .

fix:
	zig fmt .

clean:
	rm -rf zig-out .zig-cache

test:
	zig build test --summary all --test-timeout 10s

ci: fmt test

init-docs:
	cd docs && hugo mod get -u

serve:
	cd docs && hugo serve -D
