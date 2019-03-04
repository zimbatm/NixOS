
########################################################################
#                                                                      #
# DO NOT EDIT THIS FILE, ALL EDITS SHOULD BE DONE IN THE GIT REPO,     #
# PUSHED TO GITHUB AND PULLED HERE.                                    #
#                                                                      #
# LOCAL EDITS WILL BE OVERWRITTEN.                                     #
#                                                                      #
########################################################################

{ config, ... }:

{

  settings.users.users.prometheus = {
    enable       = true;
    hasShell     = false;
    canTunnel    = true;
    extraGroups  = [ config.settings.users.ssh-group ];
    isSystemUser = true;
  };

  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = [
      "logind"
      "systemd"
    ];
    # We do not need to open the firewall publicly
    openFirewall = false;
  };

}

