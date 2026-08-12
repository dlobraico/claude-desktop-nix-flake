{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  asar,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  alsa-lib,
  at-spi2-core,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk3,
  libayatana-appindicator,
  libcap_ng,
  libdrm,
  libgbm,
  libGL,
  libnotify,
  libpulseaudio,
  libsecret,
  libseccomp,
  libuuid,
  libva,
  libxkbcommon,
  libx11,
  libxscrnsaver,
  libxcomposite,
  libxcursor,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxrandr,
  libxrender,
  libxtst,
  libxcb,
  mesa,
  nspr,
  nss,
  OVMF,
  pango,
  perl,
  qemu,
  systemd,
  trash-cli,
  vulkan-loader,
  wayland,
  xdg-utils,
}:

let
  sources = {
    x86_64-linux = {
      debArch = "amd64";
      hash = "sha256-POs5Emi96af+wyUg00m3BAQxZiBM3VccYtHpUHAfSPw=";
    };
    aarch64-linux = {
      debArch = "arm64";
      hash = "sha256-eluL1fzaCmsaazcR4BQnBGYuRJOKlGgwaP2Qw5jHOU0=";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "claude-desktop is not packaged for ${stdenv.hostPlatform.system}");

  firmwareCodePath =
    if stdenv.hostPlatform.isAarch64 then
      "${qemu}/share/qemu/edk2-aarch64-code.fd"
    else
      "${OVMF.fd}/FV/OVMF_CODE.fd";

  runtimeLibs = [
    alsa-lib
    at-spi2-core
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libayatana-appindicator
    libcap_ng
    libdrm
    libgbm
    libGL
    libnotify
    libpulseaudio
    libsecret
    libseccomp
    libuuid
    libva
    libxkbcommon
    mesa
    nspr
    nss
    pango
    stdenv.cc.cc.lib
    systemd
    vulkan-loader
    wayland
    libx11
    libxscrnsaver
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxrender
    libxtst
    libxcb
  ];

  runtimeBins = [
    glib
    qemu
    trash-cli
    xdg-utils
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "claude-desktop";
  version = "1.28929.0";

  src = fetchurl {
    url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${finalAttrs.version}_${source.debArch}.deb";
    inherit (source) hash;
  };

  nativeBuildInputs = [
    dpkg
    asar
    autoPatchelfHook
    makeWrapper
    perl
    wrapGAppsHook3
  ];

  buildInputs = runtimeLibs;

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontWrapGApps = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile "$src" | tar --extract --file - --no-same-permissions
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib" "$out/share"
    cp -a usr/lib/claude-desktop "$out/lib/"
    cp -a usr/share/applications usr/share/icons usr/share/doc "$out/share/"

    # The entry's basename tracks package.json's desktopName, which changed in
    # 1.26832.0 (claude-desktop.desktop -> com.anthropic.Claude.desktop), so
    # find it rather than hardcoding a name upstream is free to change again.
    desktopEntries=("$out"/share/applications/*.desktop)
    if [ "''${#desktopEntries[@]}" -ne 1 ]; then
      echo "expected exactly one desktop entry, found ''${#desktopEntries[@]}" >&2
      exit 1
    fi
    substituteInPlace "''${desktopEntries[0]}" \
      --replace-fail "Exec=claude-desktop" "Exec=$out/bin/claude-desktop"

    asarRoot="$(mktemp -d)"
    asar extract "$out/lib/claude-desktop/resources/app.asar" "$asarRoot"

    # The main-process bundle is code split into content-hashed chunks whose
    # names rotate every release, so patch across the whole build directory and
    # assert afterwards that each substitution landed exactly once. Quote style
    # also varies with the minifier (1.26832.0 emits backticks where earlier
    # releases emitted double quotes), hence ["\x60] instead of a literal quote,
    # and the identifiers are captured rather than spelled out.
    FIRMWARE_CODE_PATH="${firmwareCodePath}" \
    VIRTIOFSD_PATH="$out/lib/claude-desktop/resources/virtiofsd" \
    perl -0pi -e '
      $firmware += s{([A-Za-z0-9_\$]+)=process\.arch===["\x60]arm64["\x60]\?\[["\x60]/usr/share/AAVMF/AAVMF_CODE\.fd["\x60]\]:\[["\x60]/usr/share/OVMF/OVMF_CODE_4M\.fd["\x60],["\x60]/usr/share/OVMF/OVMF_CODE\.fd["\x60]\]}{$1=["$ENV{FIRMWARE_CODE_PATH}"]}g;
      $virtiofsd += s{([A-Za-z0-9_\$]+)=\[["\x60]/usr/libexec/virtiofsd["\x60],["\x60]/usr/bin/virtiofsd["\x60]\]}{$1=["$ENV{VIRTIOFSD_PATH}"]}g;
      $vars += s{return ([A-Za-z0-9_\$]+)\.replace\(["\x60]OVMF_CODE["\x60],["\x60]OVMF_VARS["\x60]\)\.replace\(["\x60]AAVMF_CODE["\x60],["\x60]AAVMF_VARS["\x60]\)}{return $1.replace("OVMF_CODE","OVMF_VARS").replace("AAVMF_CODE","AAVMF_VARS").replace("edk2-aarch64-code.fd","edk2-arm-vars.fd")}g;
      END {
        die "failed to patch firmware path (matched $firmware times, expected 1)\n" unless $firmware == 1;
        die "failed to patch virtiofsd path (matched $virtiofsd times, expected 1)\n" unless $virtiofsd == 1;
        die "failed to patch firmware vars path (matched $vars times, expected 1)\n" unless $vars == 1;
      }
    ' "$asarRoot"/.vite/build/*.js

    rm "$out/lib/claude-desktop/resources/app.asar"
    asar pack --unpack "*.node" "$asarRoot" "$out/lib/claude-desktop/resources/app.asar"

    runHook postInstall
  '';

  preFixup = ''
    gappsWrapperArgs+=(
      --prefix PATH : ${lib.makeBinPath runtimeBins}
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath runtimeLibs}
      --set-default ELECTRON_OZONE_PLATFORM_HINT auto
    )
  '';

  postFixup = ''
    makeWrapper "$out/lib/claude-desktop/claude-desktop" "$out/bin/claude-desktop" \
      "''${gappsWrapperArgs[@]}"
  '';

  passthru = {
    updateScript = ../../scripts/update.sh;
    inherit sources;
  };

  meta = {
    description = "Official Claude Desktop Linux beta";
    homepage = "https://claude.ai";
    changelog = "https://code.claude.com/docs/en/desktop-linux";
    license = lib.licenses.unfree;
    mainProgram = "claude-desktop";
    platforms = builtins.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    maintainers = [ ];
  };
})
