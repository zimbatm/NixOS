# Take a path to a host file to be included in this config.
# The result of calling this with a path, is a NixOS module.
# Example usage:
#   import ./eval_host.nix { host_path = ./org-config/hosts.myhost.nix; }
{ host_path
, prod_build ? true
}:

{ config, lib, ... }:

with lib;

{
  imports = [
    # Import the host path that was passed as an argument.
    host_path
    ./modules
  ] ++ optional prod_build ./hardware-configuration.nix;

  config.settings.system.isProdBuild = prod_build;
}

