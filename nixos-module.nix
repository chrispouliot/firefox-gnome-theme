# Add this file to the root of chrispouliot/firefox-gnome-theme.
# No Home Manager dependency. The theme comes from this module's repository.
#
# In your NixOS flake inputs:
#   firefox-gnome-theme = {
#     url = "github:chrispouliot/firefox-gnome-theme/fix/tab-title-fade";
#     flake = false;
#   };
#
# Add this alongside configuration.nix in nixosSystem.modules:
#   (inputs.firefox-gnome-theme + "/nixos-module.nix")
#
# In configuration.nix:
#   services.firefox-gnome-theme = {
#     enable = true;
#     user = "chris";
#     profileDirectory = "/home/chris/.config/mozilla/firefox/p4ia361d.default";
#   };
#
# Commit and push this file before using the GitHub input. Close Firefox, then
# rebuild with your normal nixos-rebuild switch command. Restart Firefox after
# subsequent theme updates. Standard tab width defaults to true.
#
# Fresh installation: open Firefox once, find Profile Directory in about:support,
# close Firefox, update profileDirectory above, and rebuild. Missing profiles are
# skipped; this module does not create or select Firefox profiles.
#
# Update: nix flake update firefox-gnome-theme, then rebuild. The input lock pins
# the theme. Editing a separate local checkout does not change the installed theme.
# Backups: ~/.local/state/firefox-gnome-theme/backups/ (only on actual changes).
# Disabling the module stops management but does not remove installed files or
# reset Firefox preferences. Restore a backup to undo installation. Do not reapply
# through Add Water while this module manages the same profile.
#
# Fix reference: https://github.com/rafaelmardojai/firefox-gnome-theme/pull/1104
{ config, lib, pkgs, ... }:
let
  cfg = config.services.firefox-gnome-theme;
  themeSource = builtins.path { path = cfg.source; name = "firefox-gnome-theme"; };
  installer = pkgs.writeText "install-firefox-gnome-theme.py" ''
    import datetime
    import os
    from pathlib import Path
    import re
    import shutil
    import sys
    import tempfile

    profile = Path(sys.argv[1])
    source = Path(sys.argv[2])
    normal_width = sys.argv[3]
    if not profile.is_dir():
        print(f"Firefox GNOME theme: profile absent, skipping: {profile}")
        sys.exit(0)
    for name in ("userChrome.css", "userContent.css"):
        if not (source / name).is_file():
            raise SystemExit(f"Missing theme file: {source / name}")

    chrome = profile / "chrome"
    target = chrome / "firefox-gnome-theme"
    changes = {}
    for name in ("userChrome.css", "userContent.css"):
        path = chrome / name
        old = path.read_text() if path.exists() else ""
        # Keep unrelated CSS; put our import before any @namespace or rules.
        pattern = r'(?m)^[ \t]*@import\s+(?:url\(\s*)?[\x22\x27]firefox-gnome-theme/' + re.escape(name) + r'[\x22\x27]\s*\)?\s*;[ \t]*\n?'
        new = '@import "firefox-gnome-theme/' + name + '";\n' + re.sub(pattern, "", old)
        if new != old:
            changes[path] = new

    prefs = profile / "user.js"
    old = prefs.read_text() if prefs.exists() else ""
    start = "// BEGIN NIXOS FIREFOX GNOME THEME"
    end = "// END NIXOS FIREFOX GNOME THEME"
    if old.count(start) != old.count(end) or old.count(start) > 1:
        raise SystemExit("Malformed managed block in user.js; leaving files untouched")
    base = re.sub(re.escape(start) + r".*?" + re.escape(end) + r"\n?", "", old, flags=re.S)
    block = (
        start + '\n'
        'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);\n'
        'user_pref("svg.context-properties.content.enabled", true);\n'
        'user_pref("gnomeTheme.normalWidthTabs", ' + normal_width + ');\n'
        + end + '\n'
    )
    new = base + ("\n" if base and not base.endswith("\n") else "") + block
    if new != old:
        changes[prefs] = new

    relink = not (target.is_symlink() and os.readlink(target) == str(source))
    if not changes and not relink:
        sys.exit(0)

    # Run as the profile owner, never as root. Back up before modifying anything.
    backups = Path.home() / ".local/state/firefox-gnome-theme/backups"
    backups.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-")
    backup = Path(tempfile.mkdtemp(prefix=stamp, dir=backups))
    (backup / "profile-path.txt").write_text(str(profile) + "\n")
    for path in changes:
        if path.exists() or path.is_symlink():
            # Snapshot contents even if an old user.js was a symlink.
            shutil.copy2(path, backup / path.name)
    chrome.mkdir(parents=True, exist_ok=True)
    if relink:
        if target.exists() or target.is_symlink():
            if target.is_dir():
                shutil.copytree(target, backup / "firefox-gnome-theme")
            elif target.is_symlink():
                (backup / "old-theme-link.txt").write_text(os.readlink(target))
            else:
                shutil.copy2(target, backup / "firefox-gnome-theme")
        if target.is_symlink() or target.is_file():
            target.unlink()
        elif target.exists():
            shutil.rmtree(target)
        target.symlink_to(source, target_is_directory=True)
    for path, content in changes.items():
        fd, temporary = tempfile.mkstemp(prefix=".gnome-theme-", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as output:
                output.write(content)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    print(f"Firefox GNOME theme installed. Backup: {backup}")
  '';
in
{
  options.services.firefox-gnome-theme = {
    enable = lib.mkEnableOption "the forked Firefox GNOME theme for one profile";
    user = lib.mkOption {
      type = lib.types.str;
      description = "Existing NixOS user who owns the Firefox profile.";
    };
    profileDirectory = lib.mkOption {
      type = lib.types.str;
      description = "Absolute Profile Directory from Firefox about:support.";
    };
    source = lib.mkOption {
      type = lib.types.path;
      default = ./.;
      description = "Theme repository containing userChrome.css and userContent.css.";
    };
    normalWidthTabs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Add Water's Standard tab width equivalent.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.user config.users.users;
        message = "firefox-gnome-theme.user must name an existing NixOS user.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.profileDirectory;
        message = "firefox-gnome-theme.profileDirectory must be an absolute path.";
      }
    ];
    system.activationScripts.firefox-gnome-theme = {
      deps = [ "users" ];
      text = ''
        ${pkgs.util-linux}/bin/runuser -u ${lib.escapeShellArg cfg.user} -- \
          ${pkgs.python3}/bin/python3 ${installer} \
          ${lib.escapeShellArg cfg.profileDirectory} \
          ${lib.escapeShellArg (toString themeSource)} \
          ${if cfg.normalWidthTabs then "true" else "false"}
      '';
    };
  };
}
