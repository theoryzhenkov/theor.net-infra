{
  description = "Infrastructure for theor.net";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-config.url = "path:./nixos";
    terraform-config.url = "path:./terraform";
  };

  outputs = { nixpkgs, nixos-config, terraform-config, ... }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
    in
    {
      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          inputsFrom = [
            nixos-config.devShells.${system}.default
            terraform-config.devShells.${system}.default
          ];
        };
      });
    };
}
