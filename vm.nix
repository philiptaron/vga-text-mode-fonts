{ pkgs, lib, ... }: {
  # Minimal VM settings
  virtualisation.graphics = false;

  # Disable getty on tty1 so our sample text stays visible
  systemd.services."getty@tty1".enable = false;

  # Auto-login on serial console only
  services.getty.autologinUser = "root";
  users.users.root.initialHashedPassword = "";

  # Include kbd for setfont
  environment.systemPackages = [ pkgs.kbd ];

  # Service that loads font and displays sample text
  systemd.services.font-preview = {
    description = "Load font and display sample text";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-vconsole-setup.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.util-linux pkgs.kmod pkgs.kbd ];
    script = ''
      # Load 9p modules and mount the font share
      modprobe 9pnet_virtio || true
      mkdir -p /mnt/font
      mount -t 9p -o trans=virtio,version=9p2000.L fontshare /mnt/font

      # Load the font on all consoles
      setfont /mnt/font/font.psf || true

      # Switch to tty1, clear screen, and display sample text
      chvt 1
      sleep 0.5
      echo -e '\033c' > /dev/tty1
      cat <<'SAMPLE' > /dev/tty1
  +-------------------------------------------+
  |  VGA Text Mode Font Preview               |
  +-------------------------------------------+

  The quick brown fox jumps over the lazy dog.
  ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789
  abcdefghijklmnopqrstuvwxyz !@#$%^&*()

  "Hello, World!" - A classic greeting.
  <html> &amp; other special chars: ~`[]{}|\

  drwxr-xr-x  5 root root 4096 Jan 12 10:00 .
  -rw-r--r--  1 root root 1234 Jan 12 09:30 README
  -rwxr-xr-x  1 root root 5678 Jan 12 09:15 program
SAMPLE

      # Signal ready for screenshot
      echo "READY" > /dev/ttyS0
    '';
  };

  # 9p kernel modules for font sharing
  boot.initrd.availableKernelModules = [ "9p" "9pnet" "9pnet_virtio" ];
}
