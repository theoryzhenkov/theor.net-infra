{
  description = "Infrastructure for theor.net";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixos-config.url = "path:./nixos";
    terraform-config.url = "path:./terraform";
  };

  outputs = { self, nixpkgs, nixos-config, terraform-config }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
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
