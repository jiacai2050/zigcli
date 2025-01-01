.PHONY: init-docs serve test fmt build

build:
	zig build -Doptimize=ReleaseFast \
	-Dbuild_date=$(shell date +"%Y-%m-%dT%H:%M:%S%z") \
	-Dgit_commit=$(shell git rev-parse --short HEAD) \
	--summary all

fmt:
	zig fmt --check .

clean:
	rm -rf zig-out .zig-cache

test:
	zig build test --summary all

ci: fmt test

init-docs:
	cd docs && hugo mod get -u

serve:
	cd docs && hugo serve -D


zf:
	zig build run-zigfetch --  \
	http://localhost:8000/c0c48df7567ea02458e9fc1f35c4088271b8d4a6.tar.gz
