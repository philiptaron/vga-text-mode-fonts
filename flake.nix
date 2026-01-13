{
  description = "VGA text mode fonts with preview tool and SeaVGABIOS builds";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    seabios = {
      url = "git+https://git.seabios.org/seabios.git";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, seabios }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;

      # Recursively find all font files in a directory
      findFonts = dir:
        let
          contents = builtins.readDir dir;
          processEntry = name: type:
            let path = dir + "/${name}"; in
            if type == "directory" then
              findFonts path
            else if type == "regular" && (lib.hasSuffix ".F08" name || lib.hasSuffix ".F14" name || lib.hasSuffix ".F16" name) then
              [{ inherit name path; baseName = lib.removeSuffix ".F08" (lib.removeSuffix ".F14" (lib.removeSuffix ".F16" name)); }]
            else
              [];
        in
        lib.flatten (lib.mapAttrsToList processEntry contents);

      # All font files found
      allFonts = findFonts ./FONTS;

      # Group fonts by base name (without extension) and relative path
      # This lets us find matching .F08/.F14/.F16 sets
      fontsByBase = lib.groupBy (f:
        let
          relPath = lib.removePrefix (toString ./FONTS + "/") (toString f.path);
          dirPath = builtins.dirOf relPath;
        in
        if dirPath == "." then f.baseName else "${dirPath}/${f.baseName}"
      ) allFonts;

      # Build a SeaVGABIOS with custom fonts
      mkVgaBios = { name, font16 ? null, font14 ? null, font08 ? null }:
        let
          font08Cmd = if font08 != null
            then "xxd -i ${font08} | sed 's/unsigned char [^[]*\\[\\]/u8 vgafont8[256 * 8] VAR16/'"
            else "echo 'u8 vgafont8[256 * 8] VAR16 = {0};'";
          font14Cmd = if font14 != null
            then "xxd -i ${font14} | sed 's/unsigned char [^[]*\\[\\]/u8 vgafont14[256 * 14] VAR16/'"
            else "echo 'u8 vgafont14[256 * 14] VAR16 = {0};'";
          font16Cmd = if font16 != null
            then "xxd -i ${font16} | sed 's/unsigned char [^[]*\\[\\]/u8 vgafont16[256 * 16] VAR16/'"
            else "echo 'u8 vgafont16[256 * 16] VAR16 = {0};'";
        in
        pkgs.stdenv.mkDerivation {
          pname = "vgabios-virtio-${lib.toLower (lib.replaceStrings ["/"] ["-"] name)}";
          version = "0.0.1";

          src = seabios;

          nativeBuildInputs = with pkgs; [ python3 xxd ];

          postPatch = ''
            # Generate vgafonts.c with custom fonts
            {
              echo '#include "vgautil.h"'
              echo ""
              ${font08Cmd}
              echo ""
              ${font14Cmd}
              echo ""
              ${font16Cmd}
              echo ""
              echo 'u8 vgafont14alt[1] VAR16;'
              echo 'u8 vgafont16alt[1] VAR16;'
            } > vgasrc/vgafonts.c

            # Create .config for virtio VGA
            cat > .config << 'EOF'
            CONFIG_QEMU=y
            CONFIG_VGA_BOCHS=y
            CONFIG_VGA_BOCHS_VIRTIO=y
            CONFIG_VGA_VBE=y
            CONFIG_VGA_PCI=y
            CONFIG_VGA_STDVGA_PORTS=y
            CONFIG_BUILD_VGABIOS=y
            CONFIG_VGA_FIXUP_ASM=y
            CONFIG_VGA_ALLOCATE_EXTRA_STACK=y
            CONFIG_VGA_EXTRA_STACK_SIZE=512
            CONFIG_VGA_VID=0x1af4
            CONFIG_VGA_DID=0x1050
            EOF
          '';

          buildPhase = ''
            runHook preBuild
            make olddefconfig
            make out/vgabios.bin
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/share/qemu
            cp out/vgabios.bin $out/share/qemu/vgabios-virtio.bin
            runHook postInstall
          '';

          meta = {
            description = "SeaVGABIOS for virtio-vga with ${name} font";
            license = lib.licenses.lgpl3;
          };
        };

      # Create a derivation for each font group
      mkFontBios = baseName: fonts:
        let
          getFont = ext: lib.findFirst (f: lib.hasSuffix ext f.name) null fonts;
          font08 = getFont ".F08";
          font14 = getFont ".F14";
          font16 = getFont ".F16";
          # Only build if we have at least one font
          hasFont = font08 != null || font14 != null || font16 != null;
        in
        if hasFont then
          mkVgaBios {
            name = baseName;
            font08 = if font08 != null then font08.path else null;
            font14 = if font14 != null then font14.path else null;
            font16 = if font16 != null then font16.path else null;
          }
        else
          null;

      # All VGA BIOS packages
      vgaBiosPackages = lib.filterAttrs (_: v: v != null)
        (lib.mapAttrs mkFontBios fontsByBase);

      # Convert package names to valid Nix attribute names
      sanitizeName = name: lib.replaceStrings ["/"] ["-"] (lib.toLower name);
      vgaBiosPackagesSanitized = lib.mapAttrs' (name: value:
        lib.nameValuePair (sanitizeName name) value
      ) vgaBiosPackages;

      # Build the font test boot sector
      fontTestBoot = pkgs.stdenv.mkDerivation {
        pname = "fonttest-boot";
        version = "1.0";
        src = ./fonttest.asm;
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.nasm ];
        buildPhase = ''
          nasm -f bin $src -o fonttest.bin
        '';
        installPhase = ''
          mkdir -p $out
          cp fonttest.bin $out/
        '';
      };

      # Generate a screenshot for a VGA BIOS
      mkVgaBiosImage = name: vgabios:
        pkgs.runCommand "vgabios-${sanitizeName name}-preview.png" {
          nativeBuildInputs = [ pkgs.qemu_kvm pkgs.imagemagick ];
        } ''
          # Create FIFOs for QMP communication
          mkfifo qmp.in qmp.out

          # Start QEMU with QMP on fifos (TCG mode for sandbox compatibility)
          ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
            -machine pc,accel=tcg \
            -cpu qemu64 \
            -m 32 \
            -vga none \
            -device virtio-vga,romfile=${vgabios}/share/qemu/vgabios-virtio.bin \
            -drive file=${fontTestBoot}/fonttest.bin,format=raw,if=floppy,readonly=on \
            -boot a \
            -display none \
            -no-reboot \
            -snapshot \
            -serial none \
            -parallel none \
            -chardev pipe,id=qmp,path=qmp \
            -qmp chardev:qmp \
            &
          QEMU_PID=$!

          # Wait for QEMU to boot and render (TCG is slow)
          sleep 4

          # Send QMP commands via file descriptors
          exec 3>qmp.in
          exec 4<qmp.out

          # Read greeting
          timeout 2 head -n1 <&4 || true

          # Send capabilities
          echo '{"execute":"qmp_capabilities"}' >&3
          timeout 2 head -n1 <&4 || true

          # Take screenshot
          echo "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$PWD/shot.ppm\"}}" >&3
          timeout 2 head -n1 <&4 || true

          # Give it time to write
          sleep 1

          # Quit QEMU
          echo '{"execute":"quit"}' >&3 || true

          # Close file descriptors
          exec 3>&-
          exec 4<&-

          # Wait for QEMU to exit
          wait $QEMU_PID 2>/dev/null || true

          if [[ ! -f shot.ppm ]]; then
            echo "Screenshot failed - shot.ppm not found" >&2
            ls -la >&2
            exit 1
          fi

          # Convert to PNG
          ${pkgs.imagemagick}/bin/magick shot.ppm $out
        '';

      # All VGA BIOS image packages
      vgaBiosImagePackages = lib.mapAttrs mkVgaBiosImage vgaBiosPackages;
      vgaBiosImagePackagesSanitized = lib.mapAttrs' (name: value:
        lib.nameValuePair "${sanitizeName name}-img" value
      ) vgaBiosImagePackages;

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
        inherit preview fontTestBoot;
        vm = vmScript;
        default = preview;
      } // vgaBiosPackagesSanitized // vgaBiosImagePackagesSanitized;

      # Also expose as a nested attribute for easier browsing
      vgabios.${system} = vgaBiosPackages;
      vgabiosImages.${system} = vgaBiosImagePackages;
    };
}
