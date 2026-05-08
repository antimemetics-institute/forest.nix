.PHONY: update-deps check

update-deps:
	nix flake update
	npins update

check:
	nix flake check
