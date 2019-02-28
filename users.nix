
########################################################################
#                                                                      #
# DO NOT EDIT THIS FILE, ALL EDITS SHOULD BE DONE IN THE GIT REPO,     #
# PUSHED TO GITHUB AND PULLED HERE.                                    #
#                                                                      #
# LOCAL EDITS WILL BE OVERWRITTEN.                                     #
#                                                                      #
########################################################################

{ config, lib, pkgs, ... }:

with lib;

let

  userOpts = { name, config, ... }: {

    options = {

      name = mkOption {
        type = types.str;
      };

      enable = mkOption {
        type = types.bool;
        default = false;
      };

      extraGroups = mkOption {
        type = types.listOf types.str;
        default = [];
      };

      hasShell = mkOption {
        type = types.bool;
        default = false;
      };

      canTunnel = mkOption {
        type = types.bool;
        default = false;
      };

    };

    config = {
      name = mkDefault name;
    };
  };

in {

  options = {

    settings.users = mkOption {
      default = [];
      type = with types; loaOf (submodule userOpts);
    };

  };

  config = {

    users.users = mapAttrs (name: value: {
      name = name;
      isNormalUser = value.hasShell;
      extraGroups = value.extraGroups;
      shell = mkIf (!value.hasShell) pkgs.nologin;
      openssh.authorizedKeys.keyFiles = [ (./keys + ("/" + name)) ];
    }) (filterAttrs (name: value: value.enable) config.settings.users);

    settings.reverse_tunnel.relay.tunneller.allowedUsers =
      mapAttrsToList (name: value: name)
        (filterAttrs (name: value: value.canTunnel) config.settings.users);

  };

}

