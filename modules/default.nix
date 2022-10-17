{
  # The cachix.nix module is automatically generated.
  # See scripts/configure_cachix.sh

  imports = [
    ./auto_shutdown.nix
    ./boot.nix
    ./cachix.nix
    ./crypto.nix
    ./docker.nix
    ./lib.nix
    ./live_system.nix
    ./load_json.nix
    ./maintenance.nix
    ./network.nix
    ./nfs.nix
    ./nomad.nix
    ./packages.nix
    ./panic_button.nix
    ./prometheus.nix
    ./reverse-tunnel.nix
    ./sshd.nix
    ./syno_vm.nix
    ./system.nix
    ./traefik.nix
    ./users.nix
    ./vim-config.nix
    ./virtualbox.nix
    ./vmware.nix
  ];
}

