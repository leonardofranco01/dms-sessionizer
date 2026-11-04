{
  description = "DMS Sessionizer — DankMaterialShell launcher plugin";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "dms-plugin-dmsSessionizer";
            version = "1.6.1";
            src = self;
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -r assets dmsSessionizer.qml dmsSessionizerSettings.qml \
                LICENSE plugin.json README.md $out/
              runHook postInstall
            '';
            meta = {
              description = "Create tmux/Zellij sessions for your projects";
              homepage = "https://github.com/LGBaracco/dms-sessionizer";
              platforms = pkgs.lib.platforms.all;
            };
          };
        }
      );
    };
}
