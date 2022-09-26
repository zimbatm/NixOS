# Take as an argument a host-specific config to be included.
# The result of calling this expression with such a config, is a complete NixOS module.
# Example usage:
#   import ./eval_host.nix { host_config = ./org-config/hosts.myhost.nix; }
{ host_config
, prod_build ? true
}:

{ lib, ... }:

with lib;

{
  imports = [
    # Import the host config that was passed as an argument.
    host_config
    ./modules
  ]
  ++ optional (builtins.pathExists ./org-config) ./org-config;

  config.settings.system.isProdBuild = prod_build;
}

