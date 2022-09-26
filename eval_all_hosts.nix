# This file can be used with nix-eval-jobs to evaluate all hosts.

{ nixpkgs ? import <nixpkgs> { }
, eval_nixos ? import <nixpkgs/nixos>
, prod_build ? true
}:

with nixpkgs.lib;

let
  to_host_path = hostname:
    ./org-config/hosts/${hostname} + ".nix";

  eval_host = hostname:
    eval_nixos {
      configuration =
        import ./eval_host.nix {
          inherit prod_build;
          host_config = to_host_path hostname;
        };
    };

  build_host = hostname:
    # This call is the equivalent of
    #   nix-build <nixpkgs/nixos> -A config.system.build.toplevel -I nixos-config=<...>
    # with the <...> set to the result of the call to eval_host.nix below.
    (eval_host hostname).config.system.build.toplevel;

  build_iso = hostname:
    (eval_host hostname).config.system.build.isoImage;

  hosts =
    map (removeSuffix ".nix")
      (attrNames
        (filterAttrs (name: type: type == "regular" && hasSuffix ".nix" name)
          (builtins.readDir ./org-config/hosts)));
in
# Generate an attrset containing one attribute per host
genAttrs hosts build_host //
{
  # Add an aditional attribute, rescue_iso_img,
  # that will build the actual ISO image.
  rescue_iso_img = build_iso "rescue_iso";
}

