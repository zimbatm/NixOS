{ lib, config, pkgs, ... }:

with lib;

let
  inherit (config.lib) ext_lib;

  cfg = config.settings.maintenance;
  sys_cfg = config.settings.system;

  # Submodule to define repos.
  repoOpts = { name, config, ... }: {
    options = {
      name = mkOption {
        type = types.str;
      };
      branch = mkOption {
        type = types.str;
      };
      url = mkOption {
        type = types.str;
      };
    };
    config = {
      name = mkDefault name;
    };
  };
in
{

  # https://github.com/NixOS/nixpkgs/pull/77622
  imports = [ ./nixos-upgrade.nix ];

  options.settings.maintenance = {
    enable = mkOption {
      type = types.bool;
      default = true;
    };

    sync_config.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to pull the config from the upstream branch before running the upgrade service.
      '';
    };

    config_repos = {
      main = mkOption {
        type = types.submodule repoOpts;
      };
      org = mkOption {
        type = types.submodule repoOpts;
      };
    };

    nixos_upgrade = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable the nixos-upgrade timer";
      };

      startAt = mkOption {
        type = with types; listOf str;
        # By default, we run the upgrade service once at night and twice during
        # the day, to catch the situation where the server is turned off during
        # the night or during the weekend (which can be anywhere from Thursday to Sunday).
        # When the service is being run during the day, we will be outside the
        # reboot window and the config will not be switched.
        default = [ "Fri 12:00" "Sun 12:00" "Mon 02:00" ];
        description = ''
          When to run the nixos-upgrade service.
        '';
      };
    };

    nixos_config_update = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Periodically update the NixOS config from GitHub.
          This option only has an effect when settings.maintenance.nixos_upgrade.enable
          is set to false.
        '';
      };
    };

    docker_prune_timer.enable = mkEnableOption "service to periodically run docker system prune";
  };

  config = mkIf cfg.enable {
    system.autoUpgrade = {
      enable = cfg.nixos_upgrade.enable;
      allowReboot = true;
      rebootWindow_compat = { lower = "01:00"; upper = "05:00"; };
      # We override this below, since this option does not accept
      # a list of multiple timings.
      dates = "";
    };

    systemd.services = {
      nixos-upgrade = mkIf cfg.nixos_upgrade.enable {
        serviceConfig = {
          TimeoutStartSec = "2 days";
        };
        startAt = mkForce cfg.nixos_upgrade.startAt;
      };

      nixos_sync_config = mkIf cfg.sync_config.enable {
        description = "Automatically sync the config with the upstream repository";
        before = [ "nixos-upgrade.service" ];
        wantedBy = [ "nixos-upgrade.service" ];
        serviceConfig = {
          Type = "oneshot";
        };
        environment = {
          GIT_SSH_COMMAND = concatStringsSep " " [
            "${pkgs.openssh}/bin/ssh"
            "-F /etc/ssh/ssh_config"
            "-i ${sys_cfg.github_private_key}"
            "-o IdentitiesOnly=yes"
            "-o StrictHostKeyChecking=yes"
          ];
        };
        script =
          let
            base_path = "/etc/nixos";
            config_path = "${base_path}/${sys_cfg.org.config_dir_name}";
            old_config_path = "${base_path}/ocb-config";

            hostname = config.networking.hostName;
            settings_path = "/etc/nixos/settings.nix";
            destination_path = "/etc/nixos/${sys_cfg.org.config_dir_name}/hosts/${hostname}.nix";
          in
          ''
            # Main repo

            ${ext_lib.reset_git { inherit (cfg.config_repos.main) url branch;
                                  git_options = [ "-C" base_path ]; }}

            # Organisation-specific repo

            if [ ! -d "${config_path}" ] && [ -d "${old_config_path}" ]; then
              mv "${old_config_path}" "${config_path}"
            fi

            if [ ! -d "${config_path}" ] || [ ! -d "${config_path}/.git" ]; then
              rm --recursive --force "${config_path}"
              ${pkgs.git}/bin/git clone ${cfg.config_repos.org.url} "${config_path}"
            fi

            if [ -d "${old_config_path}" ]; then
              rm --recursive --force "${old_config_path}"
            fi

            ${ext_lib.reset_git { inherit (cfg.config_repos.org) url branch;
                                  git_options = [ "-C" config_path ]; }}

            # Settings link

            function create_link() {
              destination="''${1}"
              if [ ! -f "${settings_path}" ] || \
                 [ "$(realpath ${settings_path})" != "''${destination}" ]; then
                ln --force --symbolic "''${destination}" "${settings_path}"
              fi
            }

            if [ -f "${settings_path}" ] && [ ! -L "${settings_path}" ]; then
              rm --force "${settings_path}"
            fi
            create_link "${destination_path}"
          '';
      };

      nixos_rebuild_config = {
        description = "Rebuild the NixOS config without doing an upgrade";
        wants = optional cfg.sync_config.enable "nixos_sync_config.service";
        after = optional cfg.sync_config.enable "nixos_sync_config.service";
        serviceConfig = {
          Type = "oneshot";
        };
        startAt =
          let
            updateCfg = cfg.nixos_config_update.enable && !cfg.nixos_upgrade.enable;
          in
          optionals updateCfg cfg.nixos_upgrade.startAt;

        restartIfChanged = false;
        unitConfig.X-StopOnRemoval = false;

        environment = config.nix.envVars //
          {
            inherit (config.environment.sessionVariables) NIX_PATH;
            HOME = "/root";
          } // config.networking.proxy.envVars;

        path = with pkgs; [ coreutils gnutar xz.bin gzip gitMinimal config.nix.package.out ];

        script =
          let
            upgrade_cfg = config.system.autoUpgrade;
            nixos-rebuild = "${config.system.build.nixos-rebuild}/bin/nixos-rebuild";
            date = "${pkgs.coreutils}/bin/date";
            readlink = "${pkgs.coreutils}/bin/readlink";
            shutdown = "${pkgs.systemd}/bin/shutdown";
          in
          ''
            ${nixos-rebuild} boot --no-build-output

            booted="$(${readlink} /run/booted-system/{initrd,kernel,kernel-modules})"
            built="$(${readlink} /nix/var/nix/profiles/system/{initrd,kernel,kernel-modules})"
            ${optionalString (upgrade_cfg.rebootWindow_compat != null) ''current_time="$(${date} +%H:%M)"''}

            if [ "$booted" = "$built" ]; then
              ${nixos-rebuild} switch
            ${optionalString (upgrade_cfg.rebootWindow_compat != null) ''
              elif [[ "''${current_time}" < "${upgrade_cfg.rebootWindow_compat.lower}" ]] || \
                   [[ "''${current_time}" > "${upgrade_cfg.rebootWindow_compat.upper}" ]]; then
                echo "Outside of configured reboot window, skipping."
            ''}
            else
              ${shutdown} -r +1
            fi
          '';
      };

      cleanup_auto_roots = {
        description = "Automatically clean up nix auto roots";
        before = [ "nix-gc.service" ];
        wantedBy = [ "nix-gc.service" ];
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          find /nix/var/nix/gcroots/auto/ -type l -mtime +30 | while read fname; do
            target=$(readlink ''${fname})
            if [ -L ''${target} ]; then
              unlink ''${target}
            fi
          done
        '';
      };

      docker_prune_timer = mkIf cfg.docker_prune_timer.enable {
        inherit (cfg.docker_prune_timer) enable;
        description = "Automatically run docker system prune";
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          ${pkgs.docker}/bin/docker system prune --force
        '';
        startAt = "Wed 04:00";
      };
    };

    nix = {
      autoOptimiseStore = true;
      gc = {
        automatic = true;
        dates = "Tue 03:00";
        options = "--delete-older-than 30d";
      };
    };
  };
}

