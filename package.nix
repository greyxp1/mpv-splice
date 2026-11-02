{
  lib,
  python3Packages,
  ffmpeg-headless,
}:
python3Packages.buildPythonApplication {
  pname = "mpv-splice";
  version = "0.1.0";
  pyproject = true;
  src = lib.cleanSource ./.;

  build-system = [python3Packages.setuptools];
  dependencies = [python3Packages.av];
  makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [ffmpeg-headless])];

  postInstall = ''
    install -Dm444 -t "$out/share/mpv/scripts/mpv-splice" mpv-splice/*.lua
    install -Dm444 -t "$out/share/licenses/mpv-splice" LICENSE LICENSE.LGPL-2.1
    substituteInPlace "$out/share/mpv/scripts/mpv-splice/main.lua" \
      --replace-fail 'backend = "mpv-splice-backend"' \
        "backend = \"$out/bin/mpv-splice-backend\""
  '';

  passthru.scriptName = "mpv-splice";

  pythonImportsCheck = ["smartcut.__main__"];

  meta = {
    description = "Video editing for mpv";
    license = with lib.licenses; [mit lgpl21Only];
    mainProgram = "mpv-splice-backend";
  };
}
