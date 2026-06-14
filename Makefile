.PHONY: update-deps check

update-deps:
	nix flake update
	tack update

check:
	nix flake check
