{ config, lib, pkgs, ... }:

with lib;

# TODO: remove this whole module once all servers are upgraded to NixOS 22.05.
#       All usages of rebootWindow_compat can then be replaced by rebootWindow.
#       See https://github.com/NixOS/nixpkgs/pull/77622

let
  cfg = config.system.autoUpgrade;
in {
  options.system.autoUpgrade = {
    rebootWindow_compat = mkOption {
      description = ''
        This option is a compatibility version of system.autoUpgrade.rebootWindow.
      '';
      default = null;
      example = { lower = "01:00"; upper = "05:00"; };
      type = with types; nullOr (submodule {
        options = {
          lower = mkOption {
            description = "Lower limit of the reboot window";
            type = types.strMatching "[[:digit:]]{2}:[[:digit:]]{2}";
            example = "01:00";
          };

          upper = mkOption {
            description = "Upper limit of the reboot window";
            type = types.strMatching "[[:digit:]]{2}:[[:digit:]]{2}";
            example = "05:00";
          };
        };
      });
    };
    # Unused option to redirect the assignment of an option. See below.
    blackHole = mkOption {
      type = types.anything;
    };
  };

  config = let
    # This variable indicates whether we need to use this module for
    # backwards compatibility or whether we can we simply use
    # the rebootWindow option that was introduced in NixOS 22.05.
    # See https://github.com/NixOS/nixpkgs/pull/77622
    isCompat = let
      version = config.system.nixos.release;
    in toInt (elemAt (splitVersion version) 0) < 22;
  in mkMerge [
    # If we are on NixOS >= 22.05, then we just forward the value of
    # rebootWindow_compat to the upstream rebootWindow option and we let the
    # upstream module deal with the configuration.
    # For NixOS < 22.05, this upstream module does not exist yet and we need to
    # configure things ourselves.
    #
    # Since calls to mkIf get pushed through sets and assignments, i.e.
    #   `mkIf cond { foo = bar; };` becomes `{ foo = mkIf cond bar; };`,
    # we cannot simply put mkIf on this set to make the assignment to the
    # rebootWindow conditional.
    # So instead we detect the version and redirect the assignment to a blackHole
    # option if it is not needed (basically rendering this part into a no-op).
    {
      system.autoUpgrade.${if isCompat then "blackHole" else "rebootWindow"} =
        cfg.rebootWindow_compat;
    }
    # Define this service only for NixOS < 22.05.
    # For later versions, it is defined upstream already.
    # See https://github.com/NixOS/nixpkgs/pull/77622
    (mkIf (isCompat && cfg.enable) {
      systemd.services.nixos-upgrade = let
        flags = [ "--no-build-output" ] ++
          optionals (cfg.channel != null)
                    [ "-I" "nixpkgs=${cfg.channel}/nixexprs.tar.xz" ];
      in {
        script = let
          nixos-rebuild = "${config.system.build.nixos-rebuild}/bin/nixos-rebuild";
          upgradeFlag  = optional (cfg.channel == null) "--upgrade";
          date     = "${pkgs.coreutils}/bin/date";
          readlink = "${pkgs.coreutils}/bin/readlink";
          shutdown = "${pkgs.systemd}/bin/shutdown";
        in mkForce (if cfg.allowReboot then ''
          # Compat version
          ${nixos-rebuild} boot ${toString (flags ++ upgradeFlag)}

          booted="$(${readlink} /run/booted-system/{initrd,kernel,kernel-modules})"
          built="$(${readlink} /nix/var/nix/profiles/system/{initrd,kernel,kernel-modules})"
          ${optionalString (cfg.rebootWindow_compat != null) ''current_time="$(${date} +%H:%M)"''}

          if [ "$booted" = "$built" ]; then
            ${nixos-rebuild} switch ${toString flags}
          ${optionalString (cfg.rebootWindow_compat != null) ''
            elif [[ "''${current_time}" < "${cfg.rebootWindow_compat.lower}" ]] || \
                 [[ "''${current_time}" > "${cfg.rebootWindow_compat.upper}" ]]; then
              echo "Outside of configured reboot window, skipping."
          ''}
          else
            ${shutdown} -r +1
          fi
        '' else ''
          ${nixos-rebuild} switch ${toString (flags ++ upgradeFlag)}
        '');
      };
    })
  ];
}

