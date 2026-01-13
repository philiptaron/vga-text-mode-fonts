{
  description = "VGA text mode fonts with preview tool";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Build the NixOS VM
      vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./vm.nix
          ({ modulesPath, ... }: {
            imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];
            virtualisation = {
              memorySize = 512;
              qemu.options = [
                "-vga std"
              ];
            };
            system.stateVersion = "24.11";
          })
        ];
      };

      vmScript = vm.config.system.build.vm;

      preview = pkgs.writeShellApplication {
        name = "font-preview";
        runtimeInputs = [ pkgs.socat pkgs.imagemagick pkgs.coreutils ];
        text = ''
          if [[ $# -lt 1 ]]; then
            echo "Usage: font-preview <path-to-psf-font>" >&2
            exit 1
          fi

          font="$1"
          if [[ ! -f "$font" ]]; then
            echo "Error: Font not found: $font" >&2
            exit 1
          fi

          # Create temp dir with font
          tmpdir=$(mktemp -d)
          cp "$font" "$tmpdir/font.psf"

          cleanup() {
            if [[ -n "''${pid:-}" ]]; then
              kill "$pid" 2>/dev/null || true
            fi
            rm -rf "$tmpdir"
          }
          trap cleanup EXIT

          # Start VM in background
          # shellcheck disable=SC2211
          ${vmScript}/bin/run-nixos-vm \
            -virtfs local,path="$tmpdir",mount_tag=fontshare,security_model=none \
            -qmp unix:"$tmpdir/qmp.sock",server,nowait \
            -serial file:"$tmpdir/serial.log" \
            -display none \
            &
          pid=$!

          echo "Waiting for VM to boot and load font..."

          # Wait for READY signal
          timeout 60 bash -c "while ! grep -q READY \"$tmpdir/serial.log\" 2>/dev/null; do sleep 0.5; done"

          # Give it a moment to render
          sleep 1

          # Take screenshot via QMP
          {
            echo '{"execute":"qmp_capabilities"}'
            sleep 0.5
            echo "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$tmpdir/shot.ppm\"}}"
            sleep 1
          } | socat - unix-connect:"$tmpdir/qmp.sock" > /dev/null

          # Wait for screenshot
          sleep 1

          if [[ ! -f "$tmpdir/shot.ppm" ]]; then
            echo "Error: Screenshot failed" >&2
            exit 1
          fi

          # Convert to PNG
          magick "$tmpdir/shot.ppm" font-preview.png
          echo "Saved: font-preview.png"
        '';
      };

    in {
      packages.${system} = {
        inherit preview;
        vm = vmScript;
        default = preview;
      };
    };
}
