{ config, lib, pkgs, ... }:

with lib;

let
  inherit (config.lib) ext_lib;

  cfg = config.settings.system;
  tnl_cfg = config.settings.reverse_tunnel;
  crypto_cfg = config.settings.crypto;
  docker_cfg = config.settings.docker;

  tmux_term = "tmux-256color";
in

{
  options.settings.system = {
    isProdBuild = mkOption {
      type = types.bool;
      default = true;
    };

    partitions = {
      forcePartitions = mkEnableOption "forcing the defined partitions";

      partitions = mkOption {
        type = with types; attrsOf (submodule {
          options = {
            enable = mkEnableOption "the partition";
            device = mkOption {
              type = types.str;
            };
            fsType = mkOption {
              type = types.str;
            };
            options = mkOption {
              type = with types; listOf str;
              default = [ "defaults" ];
            };
            autoResize = mkOption {
              type = types.bool;
              default = false;
            };
          };
        });
      };
    };

    nix_channel = mkOption {
      type = types.str;
    };

    isISO = mkOption {
      type = types.bool;
      default = false;
    };

    private_key_source = mkOption {
      type = types.path;
      default = ../local/id_tunnel;
      description = ''
        The location of the private key file used to establish the reverse tunnels.
      '';
    };

    private_key_source_default = mkOption {
      type = types.str;
      default = "/etc/nixos/local/id_tunnel";
      readOnly = true;
      description = ''
        Hard-coded value of the default location of the private key file,
        used in case the location specified at build time is not available
        at activation time, e.g. when the build was done from within the
        installer with / mounted on /mnt.
        This value is only used in the activation script.
      '';
    };

    private_key_directory = mkOption {
      type = types.str;
      default = "/run/tunnel";
      readOnly = true;
    };

    # It is crucial that this option has type str and not path,
    # to avoid the private key being copied into the nix store.
    private_key = mkOption {
      type = types.str;
      default = "${cfg.private_key_directory}/id_tunnel";
      readOnly = true;
      description = ''
        Location to load the private key file for the reverse tunnels from.
      '';
    };

    # It is crucial that this option has type str and not path,
    # to avoid the private key being copied into the nix store.
    github_private_key = mkOption {
      type = types.str;
      default = cfg.private_key;
      description = ''
        Location to load the private key file for GitHub from.
      '';
    };

    copy_private_key_to_store = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether the private key for the tunnels should be copied to
        the nix store and loaded from there. This should only be used
        when the location where the key is stored, will not be available
        during activation time, e.g. when building an ISO image.
        CAUTION: this means that the private key will be world-readable!
      '';
    };

    org = {
      config_dir_name = mkOption {
        type = types.str;
        default = "org-config";
        readOnly = true;
        description = ''
          WARNING: when changing this value, you need to change the corresponding
                   values in install.sh and modules/default.nix as well!
        '';
      };

      env_var_prefix = mkOption {
        type = types.str;
      };

      github_org = mkOption {
        type = types.str;
      };

      repo_to_url = mkOption {
        type = with types; functionTo str;
        default = repo: ''git@github.com:${cfg.org.github_org}/${repo}.git'';
      };

      iso = {
        menu_label = mkOption {
          type = types.str;
          default = "NixOS Rescue System";
        };

        file_label = mkOption {
          type = types.str;
          default = "nixos-rescue";
        };
      };
    };

    users_json_path = mkOption {
      type = types.path;
    };

    keys_json_path = mkOption {
      type = types.path;
    };

    tunnels_json_dir_path = mkOption {
      type = with types; nullOr path;
    };

    secrets = {
      src_directory = mkOption {
        type = types.path;
        description = ''
          The directory containing the generated and encrypted secrets.
        '';
      };

      src_file = mkOption {
        type = types.path;
        default = cfg.secrets.src_directory + "/generated-secrets.yml";
        description = ''
          The file containing the generated and encrypted secrets.
        '';
      };

      dest_directory = mkOption {
        type = types.str;
        description = ''
          The directory containing the decrypted secrets available to this server.
        '';
      };

      old_dest_directories = mkOption {
        type = with types; listOf str;
        default = [ ];
      };

      allow_groups = mkOption {
        type = with types; listOf str;
        description = ''
          Groups which have access to the secrets through ACLs.
        '';
        default = [ ];
      };
    };

    opt = {
      allow_groups = mkOption {
        type = with types; listOf str;
      };
    };

    diskSwap = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };

      size = mkOption {
        type = types.ints.between 0 10;
        default = 1;
        description = "Size of the swap partition in GiB.";
      };
    };
  };

  config = {

    assertions = [
      {
        assertion = hasAttr config.networking.hostName tnl_cfg.tunnels;
        message =
          "This host's host name is not present in the tunnel config " +
          "(${toString cfg.tunnels_json_dir_path}).";
      }
      {
        assertion = cfg.isProdBuild -> builtins.pathExists cfg.private_key_source;
        # Referencing the path directly, causes the file to be copied to the nix store.
        # By converting the path to a string with toString, we can avoid the file being copied.
        message =
          "The private key file at ${toString cfg.private_key_source} " +
          "does not exist.";
      }
    ];

    # Print a warning when the correct labels are not present to avoid
    # an unbootable system.
    warnings =
      let
        mkWarningMsg = name: device:
          "The ${name} partition is not correctly labelled! " +
          "This installation will probably not boot!\n" +
          "Missing device: ${device}";
        labelCondition = device: ! builtins.pathExists device;
        mkWarnings = ext_lib.compose [
          (mapAttrsToList (name: conf: mkWarningMsg name conf.device))
          (filterAttrs (_: conf: labelCondition conf.device))
          ext_lib.filterEnabled
        ];
      in
      mkWarnings cfg.partitions.partitions;

    fileSystems =
      let
        mkPartition = conf: { inherit (conf) device fsType options autoResize; };
        mkPartitions = ext_lib.compose [
          (mapAttrs (_: mkPartition))
          ext_lib.filterEnabled
        ];
        partitions = mkPartitions cfg.partitions.partitions;
      in
      if cfg.partitions.forcePartitions
      then mkForce partitions
      else partitions;

    nixpkgs.overlays =
      let
        python_scripts_overlay = self: super: {
          ocb_python_scripts =
            self.callPackage ../scripts/python_nixostools { };
        };
      in
      [ python_scripts_overlay ];

    # Use the schedutil frequency scaling governor.
    powerManagement.cpuFreqGovernor = "schedutil";

    zramSwap = {
      enable = true;
      algorithm = "zstd";
      memoryPercent = 40;
    };

    swapDevices = mkIf cfg.diskSwap.enable [
      {
        device = "/swap.img";
        size = 1024 * cfg.diskSwap.size;
        priority = 0;
        randomEncryption.enable = true;
      }
    ];

    security = {
      sudo = {
        enable = true;
        wheelNeedsPassword = false;
      };
      pam.services.su.forwardXAuth = mkForce false;
    };

    environment = {
      # See https://nixos.org/nix/manual/#ssec-values for documentation on escaping ${
      shellInit = ''
        if [ "''${TERM}" != "${tmux_term}" ] || [ -z "''${TMUX}" ]; then
          alias nixos-rebuild='printf "Please run nixos-rebuild only from within a tmux session." 2> /dev/null'
        fi
      '';
      shellAliases = {
        nix-env = ''printf "The nix-env command has been disabled. Please use nix-run or nix-shell instead." 2> /dev/null'';
        vi = "vim";
        # Have bash resolve aliases with sudo (https://askubuntu.com/questions/22037/aliases-not-available-when-using-sudo)
        sudo = "sudo ";
        whereami = "curl ipinfo.io";
      };
      variables = {
        HOSTNAME = config.networking.hostName;
        HOSTNAME_HASH =
          let
            hash = builtins.hashString "sha256" config.networking.hostName;
          in
          substring 0 12 hash;
        "${cfg.org.env_var_prefix}_SECRETS_DIRECTORY" = cfg.secrets.dest_directory;
      };
    };

    users =
      let
        tunnel = "tunnel";
      in
      {
        extraUsers = {
          ${tunnel} = {
            group = tunnel;
            isNormalUser = false;
            isSystemUser = true;
            # The key to connect to the relays will be copied to /run/tunnel
            home = cfg.private_key_directory;
            createHome = true;
            shell = pkgs.shadow;
          };
        };
        groups = {
          ${tunnel} = { };
        };
      };

    # Admins have access to the secrets
    settings.system.secrets.allow_groups = [ "wheel" ];
    # Admins have access to /opt
    settings.system.opt.allow_groups = [ "wheel" ];

    system.activationScripts =
      let
        # Referencing the path directly, causes the file to be copied to the nix store.
        # By converting the path to a string with toString, we can avoid the file being copied.
        private_key_path =
          if cfg.copy_private_key_to_store
          then cfg.private_key_source
          else toString cfg.private_key_source;
      in
      {
        custom_nix_channel = {
          text = ''
            # We override the root nix channel with the one defined by settings.system.nix_channel
            echo "${cfg.nix_channel} nixos" > "/root/.nix-channels"
          '';
          # We overwrite the value set by the default NixOS activation snippet, that snippet should have run first
          # so that the additional initialisation has been performed.
          # See /run/current-system/activate for the currently defined snippets.
          deps = [ "nix" ];
        };
        tunnel_key_permissions = mkIf (!cfg.isISO) {
          # Use toString, we do not want to change permissions
          # of files in the nix store, only of the source files, if present.
          text =
            let
              base_files = [ private_key_path cfg.private_key_source_default ];
              files = concatStringsSep " " (unique (concatMap (f: [ f "${f}.pub" ]) base_files));
            in
            ''
              for file in ${files}; do
                if [ -f ''${file} ]; then
                  ${pkgs.coreutils}/bin/chown root:root ''${file}
                  ${pkgs.coreutils}/bin/chmod 0400 ''${file}
                fi
              done
            '';
          deps = [ "users" ];
        };
        copy_tunnel_key = {
          text =
            let
              install = source: ''
                ${pkgs.coreutils}/bin/install \
                  -o tunnel \
                  -g nogroup \
                  -m 0400 \
                  "${source}" \
                  "${cfg.private_key}"
              '';
            in
            ''
              if [ -f "${private_key_path}" ]; then
                ${install private_key_path}
              elif [ -f "${cfg.private_key_source_default}" ]; then
                ${install cfg.private_key_source_default}
              else
                exit 1;
              fi
            '';
          deps = [ "specialfs" "users" ];
        };
        decrypt_secrets = {
          text =
            let
              # We make an ACL with default permissions and add an extra rule
              # for each group defined as having access
              acl = concatStringsSep "," (
                [ "u::rwX,g::r-X,o::---" ] ++
                map (group: "group:${group}:rX")
                  cfg.secrets.allow_groups
              );
              mkRemoveOldDir = dir: ''
                # Delete the old secrets dir which is not used anymore
                # We maintain it as a link for now for backwards compatibility,
                # so we test first whether it is still a directory
                if [ ! -L "${dir}" ]; then
                  ${pkgs.coreutils}/bin/rm --one-file-system \
                                           --recursive \
                                           --force \
                                           "${dir}"
                fi
              '';
            in
            ''
              echo "decrypting the server secrets..."
              ${concatMapStringsSep "\n" mkRemoveOldDir cfg.secrets.old_dest_directories}
              if [ -e "${cfg.secrets.dest_directory}" ]; then
                ${pkgs.coreutils}/bin/rm --one-file-system \
                                         --recursive \
                                         --force \
                                         "${cfg.secrets.dest_directory}"
              fi
              ${pkgs.coreutils}/bin/mkdir --parent "${cfg.secrets.dest_directory}"

              ${pkgs.ocb_python_scripts}/bin/decrypt_server_secrets \
                --server_name "${config.networking.hostName}" \
                --secrets_path "${cfg.secrets.src_file}" \
                --output_path "${cfg.secrets.dest_directory}" \
                --private_key_file "${cfg.private_key}"

              # The directory is owned by root
              ${pkgs.coreutils}/bin/chown --recursive root:root "${cfg.secrets.dest_directory}"
              ${pkgs.coreutils}/bin/chmod --recursive u=rwX,g=,o= "${cfg.secrets.dest_directory}"
              # Use an ACL to give access to members of the wheel and docker groups
              ${pkgs.acl}/bin/setfacl \
                --recursive \
                --set "${acl}" \
                "${cfg.secrets.dest_directory}"
              echo "decrypted the server secrets"
            '';
          deps = [ "copy_tunnel_key" ];
        };
      };

    systemd = {
      # Given that our systems are headless, emergency mode is useless.
      # We prefer the system to attempt to continue booting so
      # that we can hopefully still access it remotely.
      enableEmergencyMode = false;

      # For more detail, see:
      #   https://0pointer.de/blog/projects/watchdog.html
      watchdog = {
        # systemd will send a signal to the hardware watchdog at half
        # the interval defined here, so every 10s.
        # If the hardware watchdog does not get a signal for 20s,
        # it will forcefully reboot the system.
        runtimeTime = "20s";
        # Forcefully reboot if the final stage of the reboot
        # hangs without progress for more than 30s.
        # For more info, see:
        #   https://utcc.utoronto.ca/~cks/space/blog/linux/SystemdShutdownWatchdog
        rebootTime = "30s";
      };

      sleep.extraConfig = ''
        AllowSuspend=no
        AllowHibernation=no
      '';

      services = {
        set_opt_permissions = {
          # See https://web.archive.org/web/20121022035645/http://vanemery.com/Linux/ACL/POSIX_ACL_on_Linux.html
          enable = true;
          description = "Set the ACLs on /opt.";
          after = optionals crypto_cfg.encrypted_opt.enable [ "opt.mount" ] ++
            optionals docker_cfg.enable [ "docker.service" ];
          wants = optionals docker_cfg.enable [ "docker.service" ];
          wantedBy =
            if crypto_cfg.encrypted_opt.enable
            then [ "opt.mount" ]
            else [ "multi-user.target" ];
          serviceConfig = {
            User = "root";
            Type = "oneshot";
          };
          script =
            let
              containerd = "containerd";
              # The X permission has no effect for default ACLs, it gets converted
              # into a regular x.
              # For all users except the file owner, the effective permissions are
              # still subject to masking, and the default mask does not
              # contain x for files.
              # Therefore, in practice, only the file owner gains execute permissions
              # on all files, and we do not need to worry too much.
              # We could probably detect this situation and revoke the x permission
              # from the ACLs on files, but this currently does not seem worth it,
              # given the additional complexity that this would introduce in this
              # script.
              acl = concatStringsSep "," (
                [
                  "u::rwX"
                  "user:root:rwX"
                  "d:u::rwx"
                  "d:g::r-x"
                  "d:o::---"
                  "d:user:root:rwx"
                ] ++
                concatMap (group: [ "group:${group}:rwX" "d:group:${group}:rwx" ])
                  cfg.opt.allow_groups
              );
              # For /opt we use setfacl --set, so we need to define the full ACL
              opt_acl = concatStringsSep "," [ "g::r-X" "o::---" acl ];
            in
            ''
              # Ensure that /opt actually exists
              if [ ! -d "/opt" ]; then
                echo "/opt does not exist, exiting."
                exit 0
              fi

              # Root owns /opt, and we apply the ACL defined above
              ${pkgs.coreutils}/bin/chown root:root      "/opt/"
              ${pkgs.coreutils}/bin/chmod u=rwX,g=rwX,o= "/opt/"
              ${pkgs.acl}/bin/setfacl \
                --set "${opt_acl}" \
                "/opt/"

              # Special cases
              if [ -d "/opt/${containerd}" ]; then
                ${pkgs.acl}/bin/setfacl --remove-all --remove-default "/opt/${containerd}"
                ${pkgs.coreutils}/bin/chown root:root     "/opt/${containerd}"
                ${pkgs.coreutils}/bin/chmod u=rwX,g=X,o=X "/opt/${containerd}"
              fi

              if [ -d "/opt/.docker" ]; then
                ${pkgs.acl}/bin/setfacl --remove-all --remove-default "/opt/.docker"
                ${pkgs.coreutils}/bin/chown root:root       "/opt/.docker"
                ${pkgs.coreutils}/bin/chmod u=rwX,g=rX,o=rX "/opt/.docker"
              fi

              if [ -d "/opt/.home" ]; then
                ${pkgs.acl}/bin/setfacl --remove-all --remove-default "/opt/.home"
                ${pkgs.coreutils}/bin/chown root:root       "/opt/.home"
                ${pkgs.coreutils}/bin/chmod u=rwX,g=rX,o=rX "/opt/.home"
              fi

              # We iterate over all directories that are not hidden,
              # except containerd and lost+found.
              # Prefix directories with a dot to exclude them.
              # For each dir we set ownership to root:root and
              # recursively apply the ACL defined above.
              for dir in $(ls /opt/); do
                if [ -d "/opt/''${dir}" ] && \
                   [ ! "${containerd}" = "''${dir}" ] && \
                   [ ! "lost+found"    = "''${dir}" ]; then
                  ${pkgs.coreutils}/bin/chown root:root      "/opt/''${dir}"
                  ${pkgs.coreutils}/bin/chmod u=rwX,g=rwX,o= "/opt/''${dir}"
                  ${pkgs.acl}/bin/setfacl \
                    --recursive \
                    --no-mask \
                    --modify "${acl}" \
                    "/opt/''${dir}"
                fi
              done
            '';
        };
      };

      user.services.cleanup_nixenv = {
        enable = true;
        description = "Clean up nix-env";
        unitConfig = {
          ConditionUser = "!@system";
          ConditionGroup = config.settings.users.shell-user-group;
        };
        serviceConfig.Type = "oneshot";
        script = ''
          ${pkgs.nix}/bin/nix-env -e '.*'
        '';
        wantedBy = [ "default.target" ];
      };
    };

    # No fonts needed on a headless system
    fonts.fontconfig.enable = mkForce false;

    programs = {
      bash.enableCompletion = true;

      ssh = {
        startAgent = false;
        # We do not have GUIs
        setXAuthLocation = false;
        hostKeyAlgorithms = [ "ssh-ed25519" "ssh-rsa" ];
        knownHosts.github = {
          hostNames = [ "github.com" "ssh.github.com" ];
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
        };
        extraConfig = ''
          # Some internet providers block port 22,
          # so we connect to GitHub using port 443
          Host github.com
            HostName ssh.github.com
            User git
            Port 443
            UserKnownHostsFile /dev/null
        '';
      };

      tmux = {
        enable = true;
        newSession = true;
        clock24 = true;
        historyLimit = 10000;
        escapeTime = 250;
        terminal = tmux_term;
        extraConfig = ''
          set -g mouse on
          set-option -g focus-events on
          set-option -g default-terminal "${tmux_term}"
          set-option -sa terminal-overrides ',xterm:RGB'
        '';
      };
    };

    services = {
      fstrim.enable = true;
      # Avoid pulling in unneeded dependencies
      udisks2.enable = false;

      timesyncd = {
        enable = true;
        servers = mkDefault [
          "0.nixos.pool.ntp.org"
          "1.nixos.pool.ntp.org"
          "2.nixos.pool.ntp.org"
          "3.nixos.pool.ntp.org"
          "time.windows.com"
          "time.google.com"
        ];
      };

      htpdate = {
        enable = true;
        servers = [ "www.kernel.org" "www.google.com" "www.cloudflare.com" ];
      };

      journald = {
        rateLimitBurst = 1000;
        rateLimitInterval = "5s";
        extraConfig = ''
          Storage=persistent
        '';
      };

      # See man logind.conf
      logind = {
        extraConfig = ''
          HandlePowerKey=poweroff
          PowerKeyIgnoreInhibited=yes
        '';
      };

      avahi = {
        enable = true;
        nssmdns = true;
        extraServiceFiles = {
          ssh = "${pkgs.avahi}/etc/avahi/services/ssh.service";
        };
        publish = {
          enable = true;
          domain = true;
          addresses = true;
          workstation = true;
        };
      };
    };

    hardware = {
      enableRedistributableFirmware = true;
      cpu.intel.updateMicrocode = true;
      cpu.amd.updateMicrocode = true;
    };

    documentation = {
      man.enable = true;
      doc.enable = false;
      dev.enable = false;
      info.enable = false;
    };
  };
}

