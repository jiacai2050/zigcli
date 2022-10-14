
build:
	zig build -Drelease-fast

fmt:
	zig fmt --check .

test: fmt
	zig build test
	zig build test -Dtarget=i386-linux
