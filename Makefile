.PHONY: update-deps check

# Bump both pin stores together. After updating microvm/sops-nix, re-pin
# spectrum to whatever rev microvm.nix is now using — keeps the npins
# pathway aligned with the flake pathway and lets us inherit microvm's CI
# signal on spectrum rather than tracking main ourselves.
update-deps:
	nix flake update
	npins update microvm.nix sops-nix
	@spectrum_rev=$$(nix eval --raw --impure --expr \
	  '(builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.spectrum.locked.rev'); \
	echo "Re-pinning spectrum to microvm's rev: $$spectrum_rev"; \
	npins remove spectrum; \
	npins add --name spectrum git "https://spectrum-os.org/git/spectrum" --branch main --at $$spectrum_rev

check:
	nix flake check
